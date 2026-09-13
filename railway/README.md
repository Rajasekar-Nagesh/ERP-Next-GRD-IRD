# Deploying Frappe/ERPNext on Railway

Railway runs one container per service and volumes cannot be shared between
services. Frappe needs a single `sites` directory shared by the web server,
workers and scheduler, so this setup packs the whole bench into **one** Railway
service (nginx + gunicorn + socket.io + 2 workers + scheduler under
supervisord) and uses managed Railway services for MariaDB and Redis.

```
┌──────────────────────────────┐
│ app  (this repo)             │
│  nginx  :$PORT               │   ← public domain
│  gunicorn :8000              │
│  socket.io :9000             │
│  worker-short / worker-long  │
│  scheduler                   │
│  volume → .../sites          │
└───────┬──────────────┬───────┘
        │              │
   ┌────▼────┐    ┌────▼────┐
   │ MariaDB │    │  Redis  │
   └─────────┘    └─────────┘
```

## Files

| File | Purpose |
| --- | --- |
| [`railway.json`](../railway.json) | Tells Railway to build `railway/Containerfile` and sets the healthcheck |
| [`Containerfile`](Containerfile) | Adds supervisord + gosu to the official `frappe/erpnext` image |
| [`entrypoint.sh`](entrypoint.sh) | Configures the bench, creates the site on first boot, migrates after |
| [`supervisord.conf`](supervisord.conf) | Runs all bench processes in the one container |
| [`nginx-entrypoint.sh`](nginx-entrypoint.sh) | Same as the stock one, but binds Railway's `$PORT` |
| [`.env.example`](.env.example) | Every variable the service reads |

## Setup

### 1. Create the project and databases

In a new Railway project add:

- **MariaDB** — use the MariaDB template (not MySQL: Frappe targets MariaDB).
  Postgres works too, see "Using Postgres" below.
- **Redis** — the standard Redis template.

### 2. Create the app service

Deploy this repository as a service. Railway reads `railway.json` and builds
`railway/Containerfile` from the repo root.

Under **Settings → Networking**, generate a domain. `RAILWAY_PUBLIC_DOMAIN`
becomes the Frappe site name unless you set `SITE_NAME`.

### 3. Add a volume

Attach a volume to the app service mounted at:

```
/home/frappe/frappe-bench/sites
```

This holds site config, private/public files and backups. Without it every
redeploy loses the site.

### 4. Set variables

Minimum, using Railway's variable references (replace `MariaDB`/`Redis` with
your service names):

```
ADMIN_PASSWORD=<pick a strong password>
DB_HOST=${{MariaDB.RAILWAY_PRIVATE_DOMAIN}}
DB_PORT=3306
DB_ROOT_USER=root
DB_ROOT_PASSWORD=${{MariaDB.MARIADB_ROOT_PASSWORD}}
REDIS_CACHE=${{Redis.REDIS_PRIVATE_URL}}
REDIS_QUEUE=${{Redis.REDIS_PRIVATE_URL}}
```

`DB_*` and `REDIS_*` can be omitted if the database and Redis variables are
already shared into the service — the entrypoint falls back to `MYSQLHOST`,
`MYSQLPORT`, `MYSQLUSER`, `MYSQLPASSWORD` and `REDIS_PRIVATE_URL`/`REDIS_URL`.
See [`.env.example`](.env.example) for the full list.

### 5. Deploy

First boot creates the site and installs ERPNext, which takes several minutes —
the healthcheck timeout in `railway.json` is 600s to allow for it. Watch the
deploy logs for `[railway-entrypoint]` lines. When it finishes, log in at your
domain as `Administrator` with `ADMIN_PASSWORD`.

Every later deploy runs `bench migrate` automatically (`AUTO_MIGRATE=0` to
disable).

## Resources

ERPNext needs real memory. Give the app service at least **2 GB RAM**; 4 GB is
comfortable once a few users are on it. Trim `GUNICORN_WORKERS` if you are
constrained.

## Using a custom domain

Add the domain in Railway, then set `SITE_NAME` to it *before the first
deploy*. If the site already exists under the Railway domain, rename it with
`bench --site <old> rename-site <new>` and update `SITE_NAME` to match.

## Using Postgres

Set `DB_TYPE=postgres` and point `DB_HOST`/`DB_PORT`/`DB_ROOT_USER`/
`DB_ROOT_PASSWORD` at the Postgres service (or let `PGHOST`/`PGPORT`/`PGUSER`/
`PGPASSWORD` supply them). Note that some Frappe apps assume MariaDB.

## Custom apps

Build your own image with [`images/custom/Containerfile`](../images/custom/Containerfile),
push it to a registry, then point this Containerfile at it by setting **build
arguments** on the Railway service:

```
FRAPPE_IMAGE=ghcr.io/you/erpnext-custom
FRAPPE_TAG=v1.0.0
```

and list the apps in `INSTALL_APPS` (comma separated, e.g. `erpnext,hrms`).

## Backups

The volume is not a backup. Take Frappe's own backups and push them off-box:

```bash
bench --site <site> backup --with-files
```

## Caveats

- One replica only. `numReplicas` must stay at 1 — the scheduler and the site
  directory are not safe to run twice against the same volume.
- Railway's MySQL template is MySQL 8, which Frappe does not officially
  support. Use MariaDB.
- All processes share the container's CPU/RAM; a heavy background job will slow
  web requests. For larger installs, run the workers as a separate service
  against the same database and Redis.
