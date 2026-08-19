#!/usr/bin/env bash
# Copyright (c) 2026 ImmacularIT
# License: MIT
# Native Debian 13 LXC adaptation of Honcho. Upstream Honcho remains AGPL-3.0.
set -Eeuo pipefail

export LANG=C.UTF-8
export LC_ALL=C.UTF-8
export DEBIAN_FRONTEND=noninteractive

PROJECT_OWNER="ImmacularIT"
PROJECT_REPO="Proxmox-LXC-Honcho"
PROJECT_REF="${HONCHO_PROJECT_REF:-development}"
PROJECT_RAW="https://raw.githubusercontent.com/${PROJECT_OWNER}/${PROJECT_REPO}/${PROJECT_REF}"
LIB_DIR="/usr/local/lib/honcho-lxc"
BUILD_ROOT="/var/tmp/honcho-native-build"
CONFIG_INPUT="${HONCHO_CONFIG_INPUT:-/root/honcho-installer.env}"

info() { printf '\n  ⏳ %s: ' "${1%:}"; }
ok() { printf '\n  ✔️  %s\n' "$1"; }
warn() { printf '\n  ⚠️  %s\n' "$1" >&2; }
fatal() { printf '\n  ✖️  %s\n' "$1" >&2; exit 1; }

project_download() {
  local destination="$1" path="$2"
  install -d -m 0755 "$(dirname "$destination")"
  curl -fsSL --retry 3 --retry-delay 2 "${PROJECT_RAW}/${path}" -o "$destination"
  [[ -s "$destination" ]] || fatal "Downloaded an empty project file: ${path}"
}

service_diagnostics() {
  local unit="$1"
  printf '\n--- %s status ---\n' "$unit" >&2
  systemctl status "$unit" --no-pager -l >&2 || true
  printf '\n--- %s journal ---\n' "$unit" >&2
  journalctl -u "$unit" -b --no-pager -n 120 >&2 || true
}

require_single_line_value() {
  local name="$1" value="$2"
  [[ "$value" != *$'\n'* && "$value" != *$'\r'* ]] || fatal "${name} must be a single line"
  [[ "$value" != *"'"* ]] || fatal "${name} cannot contain a single quote in this installer"
}

write_env_value() {
  local name="$1" value="$2"
  require_single_line_value "$name" "$value"
  printf "%s='%s'\n" "$name" "$value" >>/etc/honcho/environment
}

[[ "$(id -u)" -eq 0 ]] || fatal "The container installer must run as root"
[[ "$(. /etc/os-release; printf '%s' "$ID")" == "debian" ]] || fatal "Debian is required"
[[ "$(. /etc/os-release; printf '%s' "$VERSION_ID")" == "13" ]] || fatal "Debian 13 is required"
[[ "$(dpkg --print-architecture)" == "amd64" ]] || fatal "AMD64 is required for the current runtime test scope"
[[ -f "$CONFIG_INPUT" ]] || fatal "Installer configuration is missing: ${CONFIG_INPUT}"

# The launcher creates this file locally from whiptail answers. It is root-only
# and intentionally not copied into the Honcho source tree.
# shellcheck source=/dev/null
source "$CONFIG_INPUT"
: "${HONCHO_LLM_MODE:?HONCHO_LLM_MODE is required}"
: "${HONCHO_LLM_API_KEY:?HONCHO_LLM_API_KEY is required}"
case "$HONCHO_LLM_MODE" in
  openai) ;;
  compatible)
    : "${HONCHO_LLM_BASE_URL:?HONCHO_LLM_BASE_URL is required for compatible mode}"
    : "${HONCHO_LLM_MODEL:?HONCHO_LLM_MODEL is required for compatible mode}"
    ;;
  *) fatal "Unsupported LLM mode: ${HONCHO_LLM_MODE}" ;;
esac

info "Checking required DNS"
for host in github.com raw.githubusercontent.com astral.sh deb.debian.org; do
  getent ahosts "$host" >/dev/null 2>&1 || fatal "DNS resolution failed for ${host}"
done
ok "Required DNS is reachable"

info "Updating container OS"
apt-get update
apt-get -y dist-upgrade
ok "Updated container OS"

info "Installing native runtime dependencies"
apt-get install -y --no-install-recommends \
  build-essential ca-certificates curl git jq openssl postgresql postgresql-contrib \
  python3 python3-venv redis-server iproute2 procps
systemctl enable --now postgresql.service redis-server.service
ok "Installed PostgreSQL, Redis, Python, and build dependencies"

PG_VERSION="$(pg_lsclusters -H | awk 'NR==1 {print $1}')"
[[ "$PG_VERSION" =~ ^[0-9]+$ ]] || fatal "Could not determine the PostgreSQL major version"
info "Installing pgvector for PostgreSQL ${PG_VERSION}"
apt-get install -y "postgresql-${PG_VERSION}-pgvector" \
  || fatal "Debian pgvector package is unavailable for PostgreSQL ${PG_VERSION}"
ok "Installed Debian pgvector package"

info "Creating dedicated Honcho application identity"
getent group honcho >/dev/null || groupadd --system honcho
if ! id honcho >/dev/null 2>&1; then
  useradd --system --gid honcho --home-dir /var/lib/honcho --create-home --shell /usr/sbin/nologin honcho
fi
install -d -o honcho -g honcho -m 0750 /var/lib/honcho /var/lib/honcho/tmp /var/lib/honcho/.cache
ok "Created dedicated honcho system account"

DB_PASSWORD="$(openssl rand -hex 24)"
info "Provisioning PostgreSQL database and least-privilege role"
if runuser -u postgres -- psql -Atqc "SELECT 1 FROM pg_roles WHERE rolname='honcho_user'" | grep -qx 1; then
  runuser -u postgres -- psql -v ON_ERROR_STOP=1 -c "ALTER ROLE honcho_user WITH LOGIN PASSWORD '${DB_PASSWORD}';" >/dev/null
else
  runuser -u postgres -- psql -v ON_ERROR_STOP=1 -c "CREATE ROLE honcho_user LOGIN PASSWORD '${DB_PASSWORD}';" >/dev/null
fi

if ! runuser -u postgres -- psql -Atqc "SELECT 1 FROM pg_database WHERE datname='honcho'" | grep -qx 1; then
  runuser -u postgres -- createdb --owner=honcho_user --encoding=UTF8 --template=template0 honcho
else
  db_encoding="$(runuser -u postgres -- psql -Atq -d postgres -c "SELECT pg_encoding_to_char(encoding) FROM pg_database WHERE datname='honcho';")"
  if [[ "$db_encoding" != "UTF8" ]]; then
    user_table_count="$(runuser -u postgres -- psql -Atq -d honcho -c "SELECT count(*) FROM pg_catalog.pg_tables WHERE schemaname NOT IN ('pg_catalog','information_schema');")"
    if [[ ! -e /etc/honcho/installation.json && "$user_table_count" == "0" ]]; then
      warn "Incomplete Honcho database uses ${db_encoding}; recreating empty database as UTF8"
      runuser -u postgres -- dropdb honcho
      runuser -u postgres -- createdb --owner=honcho_user --encoding=UTF8 --template=template0 honcho
    else
      fatal "Existing honcho database uses ${db_encoding}; UTF8 is required. Refusing to replace a database that may contain application data"
    fi
  fi
fi

db_encoding="$(runuser -u postgres -- psql -Atq -d postgres -c "SELECT pg_encoding_to_char(encoding) FROM pg_database WHERE datname='honcho';")"
[[ "$db_encoding" == "UTF8" ]] || fatal "Honcho database encoding validation failed: ${db_encoding}"
runuser -u postgres -- psql -v ON_ERROR_STOP=1 -d postgres -c "ALTER DATABASE honcho SET client_encoding TO 'UTF8';" >/dev/null
runuser -u postgres -- psql -v ON_ERROR_STOP=1 -d honcho <<'SQL' >/dev/null
CREATE EXTENSION IF NOT EXISTS vector;
ALTER SCHEMA public OWNER TO honcho_user;
GRANT ALL ON SCHEMA public TO honcho_user;
SQL
ok "Provisioned UTF8 honcho database with pgvector"

info "Installing project version manifest"
install -d -o root -g root -m 0755 "$LIB_DIR"
project_download "$LIB_DIR/versions.sh" lib/versions.sh
# shellcheck source=/dev/null
source "$LIB_DIR/versions.sh"
[[ "$TARGET_DEBIAN_VERSION" == "13" ]] || fatal "Project version manifest targets unexpected Debian version"
[[ "$TARGET_ARCH" == "amd64" ]] || fatal "Project version manifest targets unexpected architecture"
[[ "$HONCHO_COMMIT" =~ ^[0-9a-f]{40}$ ]] || fatal "Honcho commit pin is invalid"
ok "Loaded Honcho ${HONCHO_VERSION} pin ${HONCHO_COMMIT:0:12}"

info "Installing pinned uv ${UV_VERSION}"
curl -LsSf "https://astral.sh/uv/${UV_VERSION}/install.sh" \
  | env UV_UNMANAGED_INSTALL=/usr/local/bin sh
[[ "$(/usr/local/bin/uv --version | awk '{print $2}')" == "$UV_VERSION" ]] \
  || fatal "uv version validation failed"
ok "Installed uv ${UV_VERSION}"

info "Fetching pinned upstream Honcho source"
rm -rf "$BUILD_ROOT"
install -d -o honcho -g honcho -m 0750 "$BUILD_ROOT"
release_id="${HONCHO_VERSION}-${HONCHO_COMMIT:0:12}"
release_dir="/opt/honcho/releases/${release_id}"
[[ ! -e "$release_dir" ]] || rm -rf "$release_dir"
install -d -o honcho -g honcho -m 0755 /opt/honcho/releases
runuser -u honcho -- git clone --filter=blob:none --no-checkout "$HONCHO_REPOSITORY" "$BUILD_ROOT/source"
runuser -u honcho -- git -C "$BUILD_ROOT/source" fetch --depth 1 origin "$HONCHO_COMMIT"
runuser -u honcho -- git -C "$BUILD_ROOT/source" checkout --detach "$HONCHO_COMMIT"
# Keep every Git operation on the temporary checkout under the account that
# owns it. Running rev-parse as root triggers Git's safe.directory protection.
actual_commit="$(runuser -u honcho -- git -C "$BUILD_ROOT/source" rev-parse HEAD)"
[[ "$actual_commit" == "$HONCHO_COMMIT" ]] || fatal "Upstream checkout did not match pinned commit"
actual_version="$(python3 -c 'import tomllib; print(tomllib.load(open("/var/tmp/honcho-native-build/source/pyproject.toml", "rb"))["project"]["version"])')"
[[ "$actual_version" == "$HONCHO_VERSION" ]] || fatal "Pinned commit reports Honcho ${actual_version}, expected ${HONCHO_VERSION}"
ok "Verified upstream Honcho ${HONCHO_VERSION} source"

info "Creating pinned Python environment from upstream lockfile"
runuser -u honcho -- env \
  HOME=/var/lib/honcho \
  TMPDIR=/var/lib/honcho/tmp \
  UV_CACHE_DIR=/var/lib/honcho/.cache/uv \
  UV_LINK_MODE=copy \
  /usr/local/bin/uv sync --directory "$BUILD_ROOT/source" --frozen --no-install-project --no-group dev
[[ -x "$BUILD_ROOT/source/.venv/bin/fastapi" ]] || fatal "Honcho virtual environment is missing FastAPI"
[[ -x "$BUILD_ROOT/source/.venv/bin/python" ]] || fatal "Honcho virtual environment is missing Python"
runuser -u honcho -- env HOME=/var/lib/honcho \
  "$BUILD_ROOT/source/.venv/bin/python" -c 'import alembic' \
  || fatal "Honcho virtual environment is missing the Alembic runtime dependency"
mv "$BUILD_ROOT/source" "$release_dir"
chown -R root:root "$release_dir"
ln -sfn "$release_dir" /opt/honcho/current
ok "Installed immutable Honcho release ${release_id}"

info "Installing native service and health tooling"
project_download /etc/systemd/system/honcho-api.service systemd/honcho-api.service
project_download /etc/systemd/system/honcho-deriver.service systemd/honcho-deriver.service
project_download /usr/local/sbin/honcho-lxc-healthcheck scripts/honcho-healthcheck.sh
chmod 0755 /usr/local/sbin/honcho-lxc-healthcheck
systemd-analyze verify /etc/systemd/system/honcho-api.service /etc/systemd/system/honcho-deriver.service \
  || fatal "systemd unit validation failed"
ok "Installed Honcho systemd services"

info "Writing protected Honcho runtime configuration"
install -d -o root -g honcho -m 0750 /etc/honcho
: >/etc/honcho/environment
chmod 0600 /etc/honcho/environment
write_env_value DB_CONNECTION_URI "postgresql+psycopg://honcho_user:${DB_PASSWORD}@127.0.0.1:5432/honcho?client_encoding=utf8"
write_env_value CACHE_ENABLED "true"
write_env_value CACHE_URL "redis://127.0.0.1:6379/0?suppress=true"
write_env_value AUTH_USE_AUTH "false"
write_env_value SENTRY_ENABLED "false"
write_env_value TELEMETRY_ENABLED "false"
write_env_value LLM_OPENAI_API_KEY "$HONCHO_LLM_API_KEY"

if [[ "$HONCHO_LLM_MODE" == "compatible" ]]; then
  write_env_value EMBED_MESSAGES "false"
  for prefix in \
    DERIVER_MODEL_CONFIG \
    SUMMARY_MODEL_CONFIG \
    DIALECTIC_LEVELS__minimal__MODEL_CONFIG \
    DIALECTIC_LEVELS__low__MODEL_CONFIG \
    DIALECTIC_LEVELS__medium__MODEL_CONFIG \
    DIALECTIC_LEVELS__high__MODEL_CONFIG \
    DIALECTIC_LEVELS__max__MODEL_CONFIG \
    DREAM_DEDUCTION_MODEL_CONFIG \
    DREAM_INDUCTION_MODEL_CONFIG; do
    write_env_value "${prefix}__TRANSPORT" "openai"
    write_env_value "${prefix}__MODEL" "$HONCHO_LLM_MODEL"
    write_env_value "${prefix}__OVERRIDES__BASE_URL" "$HONCHO_LLM_BASE_URL"
  done
fi
ok "Created /etc/honcho/environment"

info "Validating PostgreSQL client encoding through Honcho venv"
set -a
# shellcheck source=/dev/null
source /etc/honcho/environment
set +a
(
  cd /opt/honcho/current
  runuser -u honcho --preserve-environment -- env HOME=/var/lib/honcho \
    /opt/honcho/current/.venv/bin/python - <<'PY'
import os
import psycopg

uri = os.environ["DB_CONNECTION_URI"].replace("postgresql+psycopg://", "postgresql://", 1)
with psycopg.connect(uri) as conn:
    encoding = conn.info.encoding.replace("-", "").lower()
    version = conn.execute("SELECT pg_catalog.version()").fetchone()[0]
    if encoding != "utf8":
        raise SystemExit(f"unexpected PostgreSQL client encoding: {conn.info.encoding}")
    if not isinstance(version, str):
        raise SystemExit(f"PostgreSQL version query returned {type(version).__name__}, expected str")
PY
) || fatal "PostgreSQL client encoding validation failed"
ok "PostgreSQL client encoding is UTF8 and text decoding is active"

info "Running Honcho database migrations"
(
  cd /opt/honcho/current
  runuser -u honcho --preserve-environment -- env HOME=/var/lib/honcho \
    /opt/honcho/current/.venv/bin/python -m alembic upgrade head
)
ok "Applied Honcho database migrations"

cat >/etc/honcho/installation.json <<MANIFEST
{
  "adaptation_version": "${ADAPTATION_VERSION}",
  "upstream_version": "${HONCHO_VERSION}",
  "upstream_commit": "${HONCHO_COMMIT}",
  "uv_version": "${UV_VERSION}",
  "postgresql_version": "${PG_VERSION}",
  "database": "PostgreSQL + pgvector (UTF8)",
  "cache": "Redis",
  "llm_mode": "${HONCHO_LLM_MODE}",
  "operating_system": "Debian 13",
  "architecture": "amd64",
  "installed_utc": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "active_release": "${release_dir}",
  "runtime_test_status": "UNTESTED"
}
MANIFEST
chmod 0600 /etc/honcho/installation.json

info "Enabling and starting Honcho services"
systemctl daemon-reload
systemctl enable honcho-api.service honcho-deriver.service
if ! systemctl start honcho-api.service; then
  service_diagnostics honcho-api.service
  fatal "Honcho API service failed to start"
fi
api_ready=0
for _ in {1..120}; do
  if curl -fsS --max-time 2 http://127.0.0.1:8000/health >/dev/null 2>&1; then
    api_ready=1
    break
  fi
  if ! systemctl is-active --quiet honcho-api.service; then
    service_diagnostics honcho-api.service
    fatal "Honcho API service exited during startup"
  fi
  sleep 1
done
[[ "$api_ready" -eq 1 ]] || { service_diagnostics honcho-api.service; fatal "Honcho API did not become healthy"; }
if ! systemctl start honcho-deriver.service; then
  service_diagnostics honcho-deriver.service
  fatal "Honcho Deriver service failed to start"
fi
sleep 3
/usr/local/sbin/honcho-lxc-healthcheck
ok "Honcho native services passed the installation health check"

rm -rf "$BUILD_ROOT" /var/lib/honcho/tmp/*
rm -f "$CONFIG_INPUT"
apt-get clean
rm -rf /var/lib/apt/lists/*

printf '\nHoncho %s is installed natively without Docker or another nested container runtime.\n' "$HONCHO_VERSION"
printf 'API: http://CONTAINER-IP:8000\n'
printf 'Runtime configuration: /etc/honcho/environment\n'
printf 'Health check: honcho-lxc-healthcheck\n'
