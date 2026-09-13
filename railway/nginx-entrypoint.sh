#!/bin/bash
# Same as the stock nginx-entrypoint.sh, except the listen port is templated so
# nginx binds the port Railway assigns.
set -e

export BACKEND=${BACKEND:-127.0.0.1:8000}
export SOCKETIO=${SOCKETIO:-127.0.0.1:9000}
export UPSTREAM_REAL_IP_ADDRESS=${UPSTREAM_REAL_IP_ADDRESS:-0.0.0.0/0}
export UPSTREAM_REAL_IP_HEADER=${UPSTREAM_REAL_IP_HEADER:-X-Forwarded-For}
export UPSTREAM_REAL_IP_RECURSIVE=${UPSTREAM_REAL_IP_RECURSIVE:-off}
export PROXY_READ_TIMEOUT=${PROXY_READ_TIMEOUT:-120}
export CLIENT_MAX_BODY_SIZE=${CLIENT_MAX_BODY_SIZE:-50m}
export PORT=${PORT:-8080}

if [[ -z "${FRAPPE_SITE_NAME_HEADER:-}" ]]; then
  # shellcheck disable=SC2016
  export FRAPPE_SITE_NAME_HEADER='$host'
fi

# Only the listed variables are substituted, so nginx's own $variables survive.
# shellcheck disable=SC2016
envsubst '${BACKEND}
  ${SOCKETIO}
  ${UPSTREAM_REAL_IP_ADDRESS}
  ${UPSTREAM_REAL_IP_HEADER}
  ${UPSTREAM_REAL_IP_RECURSIVE}
  ${FRAPPE_SITE_NAME_HEADER}
  ${PROXY_READ_TIMEOUT}
  ${CLIENT_MAX_BODY_SIZE}
  ${PORT}' \
  </templates/nginx/frappe.conf.template >/etc/nginx/conf.d/frappe.conf

exec nginx -g 'daemon off;'
