#!/bin/bash
# Railway entrypoint: prepare the bench, create or migrate the site, then hand
# over to supervisord (which runs nginx, gunicorn, socket.io, workers, scheduler).
set -euo pipefail

BENCH_DIR=/home/frappe/frappe-bench
SITES_DIR="$BENCH_DIR/sites"
ASSETS_PATH="$SITES_DIR/assets"
BAKED_ASSETS="$BENCH_DIR/assets"

log() { echo "[railway-entrypoint] $*"; }
fail() {
  echo "[railway-entrypoint] ERROR: $*" >&2
  exit 1
}

# ---------------------------------------------------------------------------
# Database settings. Explicit DB_* wins; otherwise fall back to the variables
# Railway's MySQL/MariaDB and Postgres services expose.
# ---------------------------------------------------------------------------
DB_TYPE=${DB_TYPE:-mariadb}

if [ "$DB_TYPE" = "postgres" ]; then
  DB_HOST=${DB_HOST:-${PGHOST:-}}
  DB_PORT=${DB_PORT:-${PGPORT:-5432}}
  DB_ROOT_USER=${DB_ROOT_USER:-${PGUSER:-postgres}}
  DB_ROOT_PASSWORD=${DB_ROOT_PASSWORD:-${PGPASSWORD:-}}
else
  DB_HOST=${DB_HOST:-${MYSQLHOST:-}}
  DB_PORT=${DB_PORT:-${MYSQLPORT:-3306}}
  DB_ROOT_USER=${DB_ROOT_USER:-${MYSQLUSER:-root}}
  DB_ROOT_PASSWORD=${DB_ROOT_PASSWORD:-${MYSQLPASSWORD:-${MYSQL_ROOT_PASSWORD:-}}}
fi

[ -n "$DB_HOST" ] || fail "DB_HOST is not set and no Railway database variable was found. Add a MariaDB/MySQL (or Postgres) service and reference its variables."
[ -n "$DB_ROOT_PASSWORD" ] || fail "DB_ROOT_PASSWORD is not set and no Railway database password variable was found."

# ---------------------------------------------------------------------------
# Redis. Railway's Redis service exposes REDIS_URL / REDIS_PRIVATE_URL.
# Frappe accepts a full redis:// URL including credentials.
# ---------------------------------------------------------------------------
REDIS_FALLBACK=${REDIS_PRIVATE_URL:-${REDIS_URL:-}}
REDIS_CACHE=${REDIS_CACHE:-$REDIS_FALLBACK}
REDIS_QUEUE=${REDIS_QUEUE:-$REDIS_FALLBACK}

[ -n "$REDIS_CACHE" ] || fail "REDIS_CACHE is not set and no Railway REDIS_URL was found. Add a Redis service and reference its variables."
[ -n "$REDIS_QUEUE" ] || fail "REDIS_QUEUE is not set and no Railway REDIS_URL was found."

# Normalise to a full URL, Frappe stores these verbatim.
case "$REDIS_CACHE" in redis://*|rediss://*) ;; *) REDIS_CACHE="redis://$REDIS_CACHE" ;; esac
case "$REDIS_QUEUE" in redis://*|rediss://*) ;; *) REDIS_QUEUE="redis://$REDIS_QUEUE" ;; esac

# ---------------------------------------------------------------------------
# Site identity. Railway hands us the public domain of this service.
# ---------------------------------------------------------------------------
SITE_NAME=${SITE_NAME:-${RAILWAY_PUBLIC_DOMAIN:-}}
[ -n "$SITE_NAME" ] || fail "SITE_NAME is not set and RAILWAY_PUBLIC_DOMAIN is empty. Generate a domain for this service or set SITE_NAME."

ADMIN_PASSWORD=${ADMIN_PASSWORD:-}
INSTALL_APPS=${INSTALL_APPS:-erpnext}
AUTO_MIGRATE=${AUTO_MIGRATE:-1}
SOCKETIO_PORT=${SOCKETIO_PORT:-9000}

# nginx resolves the site by this header, pin it to the site we created so the
# app also answers on custom domains and on Railway's healthcheck host.
export FRAPPE_SITE_NAME_HEADER=${FRAPPE_SITE_NAME_HEADER:-$SITE_NAME}
export BACKEND=${BACKEND:-127.0.0.1:8000}
export SOCKETIO=${SOCKETIO:-127.0.0.1:$SOCKETIO_PORT}
export PORT=${PORT:-8080}

# ---------------------------------------------------------------------------
# Railway mounts the volume as root, the bench runs as frappe (uid 1000).
# ---------------------------------------------------------------------------
if [ "$(id -u)" = "0" ]; then
  mkdir -p "$SITES_DIR" "$BENCH_DIR/logs"
  chown frappe:frappe "$SITES_DIR" "$BENCH_DIR/logs"
  # Only recurse when something in the volume is not ours, this is slow on big sites.
  if [ -n "$(find "$SITES_DIR" -maxdepth 1 ! -user frappe -print -quit)" ]; then
    log "Fixing ownership of $SITES_DIR"
    chown -R frappe:frappe "$SITES_DIR"
  fi
fi

run_as_frappe() {
  if [ "$(id -u)" = "0" ]; then
    gosu frappe env HOME=/home/frappe "$@"
  else
    "$@"
  fi
}

cd "$BENCH_DIR"

# Link the image's baked assets into the mounted sites volume (the stock image
# entrypoint does this, and we replace it).
log "Linking baked assets into the sites volume"
run_as_frappe rm -rf "$ASSETS_PATH"
run_as_frappe ln -s "$BAKED_ASSETS" "$ASSETS_PATH"

# Not fatal: Railway's private network is IPv6 and the probe is less reliable
# than the bench commands that follow, which fail loudly on their own.
log "Waiting for database $DB_HOST:$DB_PORT"
wait-for-it -t 180 "$DB_HOST:$DB_PORT" || log "WARNING: could not probe $DB_HOST:$DB_PORT, continuing anyway"

# ---------------------------------------------------------------------------
# Bench configuration
# ---------------------------------------------------------------------------
log "Writing common_site_config.json"
[ -f "$SITES_DIR/common_site_config.json" ] || run_as_frappe bash -c 'echo "{}" > sites/common_site_config.json'
run_as_frappe bash -c 'ls -1 apps > sites/apps.txt'
run_as_frappe bench set-config -g db_host "$DB_HOST"
run_as_frappe bench set-config -gp db_port "$DB_PORT"
run_as_frappe bench set-config -g redis_cache "$REDIS_CACHE"
run_as_frappe bench set-config -g redis_queue "$REDIS_QUEUE"
run_as_frappe bench set-config -g redis_socketio "$REDIS_QUEUE"
run_as_frappe bench set-config -gp socketio_port "$SOCKETIO_PORT"
if [ -x /usr/bin/chromium-headless-shell ]; then
  run_as_frappe bench set-config -g chromium_path /usr/bin/chromium-headless-shell
fi

# ---------------------------------------------------------------------------
# Create the site on first boot, migrate it on every boot after that.
# ---------------------------------------------------------------------------
if [ -d "$SITES_DIR/$SITE_NAME" ]; then
  log "Site $SITE_NAME already exists"
  if [ "$AUTO_MIGRATE" = "1" ]; then
    log "Running bench migrate"
    run_as_frappe bench --site "$SITE_NAME" migrate
  fi
else
  [ -n "$ADMIN_PASSWORD" ] || fail "ADMIN_PASSWORD must be set to create the site $SITE_NAME."
  log "Creating site $SITE_NAME"

  new_site_args=(
    new-site "$SITE_NAME"
    --db-type "$DB_TYPE"
    --db-root-username "$DB_ROOT_USER"
    --db-root-password "$DB_ROOT_PASSWORD"
    --admin-password "$ADMIN_PASSWORD"
    --set-default
  )
  # The managed database is remote, so the site's db user must be allowed in
  # from any host rather than through a local socket.
  [ "$DB_TYPE" = "postgres" ] || new_site_args+=(--mariadb-user-host-login-scope=%)

  for app in ${INSTALL_APPS//,/ }; do
    new_site_args+=(--install-app "$app")
  done

  run_as_frappe bench "${new_site_args[@]}"
fi

run_as_frappe bench --site "$SITE_NAME" set-config host_name "https://$SITE_NAME"
run_as_frappe bench --site "$SITE_NAME" enable-scheduler || true

log "Starting supervisord"
if [ "$(id -u)" = "0" ]; then
  exec gosu frappe "$@"
fi
exec "$@"
