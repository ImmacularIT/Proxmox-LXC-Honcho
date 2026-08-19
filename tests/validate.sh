#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }
pass() { printf 'PASS: %s\n' "$1"; }

for file in ct/honcho.sh install/honcho-install.sh scripts/honcho-healthcheck.sh lib/versions.sh tests/validate.sh; do
  bash -n "$file" || fail "bash syntax: $file"
done
pass "Bash syntax"

python3 -m json.tool json/honcho.json >/dev/null || fail "json/honcho.json is invalid JSON"
pass "Project metadata JSON"

# shellcheck source=/dev/null
source lib/versions.sh
[[ "$HONCHO_COMMIT" =~ ^[0-9a-f]{40}$ ]] || fail "HONCHO_COMMIT is not an exact SHA"
[[ "$HONCHO_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail "HONCHO_VERSION is not semver-like"
[[ "$UV_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail "UV_VERSION is not pinned"
[[ "$TARGET_DEBIAN_VERSION" == "13" ]] || fail "Target Debian version changed unexpectedly"
[[ "$TARGET_ARCH" == "amd64" ]] || fail "Target architecture changed unexpectedly"
pass "Canonical version pins"

if grep -REn --exclude='validate.sh' --exclude='README.md' --exclude='PROJECT-HANDOFF.md' --exclude='RUNTIME-TEST-PLAN.md' \
  '(docker[[:space:]]+(run|compose|pull|build)|podman[[:space:]]+(run|pull|build)|apt(-get)?[[:space:]].*(docker|podman))' \
  ct install lib scripts systemd json .github 2>/dev/null; then
  fail "Nested application runtime command found"
fi
pass "No Docker/Podman installation/runtime commands"

if grep -REn --exclude='validate.sh' 'plastic-labs/honcho(.git)?[^\n]*(main|master)' ct install lib scripts systemd 2>/dev/null; then
  fail "Moving upstream Honcho branch reference found in runtime code"
fi
pass "No moving upstream Honcho branch reference"

grep -q 'git -C "$BUILD_ROOT/source" fetch --depth 1 origin "$HONCHO_COMMIT"' install/honcho-install.sh \
  || fail "Installer does not fetch exact Honcho commit"
grep -q 'actual_commit="$(runuser -u honcho -- git -C "$BUILD_ROOT/source" rev-parse HEAD)"' install/honcho-install.sh \
  || fail "Installer does not verify Honcho checkout as the checkout owner"
if grep -q 'actual_commit="$(git -C "$BUILD_ROOT/source" rev-parse HEAD)"' install/honcho-install.sh; then
  fail "Installer verifies the Honcho checkout as root and can trigger Git dubious-ownership protection"
fi
pass "Exact upstream checkout and Git ownership invariants"

grep -q -- '--unprivileged 1' ct/honcho.sh || fail "Launcher does not force unprivileged LXC"
grep -q -- '--features nesting=1' ct/honcho.sh || fail "Launcher does not set nesting=1"
if grep -Eq 'keyctl[=, ]+1|features[^\n]*keyctl' ct/honcho.sh; then fail "Launcher enables keyctl"; fi
pass "LXC privilege/features invariants"

grep -q '^User=honcho$' systemd/honcho-api.service || fail "API service is not honcho user"
grep -q '^User=honcho$' systemd/honcho-deriver.service || fail "Deriver service is not honcho user"
grep -q '^EnvironmentFile=/etc/honcho/environment$' systemd/honcho-api.service || fail "API environment path changed"
grep -q '^EnvironmentFile=/etc/honcho/environment$' systemd/honcho-deriver.service || fail "Deriver environment path changed"
grep -q '^WorkingDirectory=/opt/honcho/current$' systemd/honcho-api.service || fail "API working directory changed"
grep -q '^WorkingDirectory=/opt/honcho/current$' systemd/honcho-deriver.service || fail "Deriver working directory changed"
pass "systemd identity/config invariants"

grep -q '^ExecStart=/opt/honcho/current/.venv/bin/python -m fastapi run --host 0.0.0.0 --port 8000 src/main.py$' systemd/honcho-api.service \
  || fail "API service does not invoke FastAPI through the relocated venv Python module"
if grep -q '^ExecStart=/opt/honcho/current/.venv/bin/fastapi ' systemd/honcho-api.service; then
  fail "API service depends on a console-script shebang that becomes stale when the venv is relocated"
fi
pass "FastAPI relocated-venv startup invariant"

grep -q 'mv "$BUILD_ROOT/source" "$release_dir"' install/honcho-install.sh \
  || fail "Installer does not promote verified source to the final release path"
grep -q '/usr/local/bin/uv sync --directory "$release_dir" --frozen --no-install-project --no-group dev' install/honcho-install.sh \
  || fail "Installer does not create the Honcho venv at the final release path"
if grep -q '/usr/local/bin/uv sync --directory "$BUILD_ROOT/source"' install/honcho-install.sh; then
  fail "Installer still creates the venv under the temporary build path"
fi
move_line="$(grep -nF 'mv "$BUILD_ROOT/source" "$release_dir"' install/honcho-install.sh | head -n1 | cut -d: -f1)"
sync_line="$(grep -nF '/usr/local/bin/uv sync --directory "$release_dir"' install/honcho-install.sh | head -n1 | cut -d: -f1)"
[[ "$move_line" -lt "$sync_line" ]] || fail "Installer creates the venv before the source reaches its final release path"
grep -q 'FastAPI launcher contains a stale temporary-build interpreter path' install/honcho-install.sh \
  || fail "Installer does not reject stale temporary-path console-script shebangs"
pass "Final-path virtualenv build invariant"

grep -q 'cd /opt/honcho/current' install/honcho-install.sh || fail "Migrations are not anchored to the Honcho release directory"
grep -q 'cd /opt/honcho/current' scripts/honcho-healthcheck.sh || fail "Health check Python probe is not anchored to the Honcho release directory"
grep -q '/opt/honcho/current/.venv/bin/python -m alembic upgrade head' install/honcho-install.sh \
  || fail "Migrations do not invoke Alembic through the pinned venv Python module"
if grep -q '/opt/honcho/current/.venv/bin/alembic' install/honcho-install.sh; then
  fail "Installer depends on an Alembic console-script shim that may not exist"
fi
grep -q -- "-c 'import alembic'" install/honcho-install.sh \
  || fail "Installer does not verify the Alembic runtime dependency after uv sync"
pass "Honcho working-directory and Alembic invariants"

grep -q -- '--encoding=UTF8 --template=template0' install/honcho-install.sh \
  || fail "Installer does not create the Honcho database explicitly as UTF8 from template0"
grep -q 'Honcho database encoding validation failed' install/honcho-install.sh \
  || fail "Installer does not validate the existing Honcho database encoding"
grep -q "ALTER DATABASE honcho SET client_encoding TO 'UTF8'" install/honcho-install.sh \
  || fail "Installer does not set the Honcho database client encoding default to UTF8"
grep -q 'honcho?client_encoding=utf8' install/honcho-install.sh \
  || fail "Honcho DB URI does not force UTF8 client encoding"
grep -q 'conn.info.encoding' install/honcho-install.sh \
  || fail "Installer does not probe Psycopg client encoding before migrations"
grep -q 'isinstance(version, str)' install/honcho-install.sh \
  || fail "Installer does not verify PostgreSQL text decoding before migrations"
grep -q 'Honcho database encoding is UTF8' scripts/honcho-healthcheck.sh \
  || fail "Health check does not verify UTF8 database encoding"
pass "PostgreSQL UTF8 invariants"

grep -q 'write_env_value TELEMETRY_ENABLED "false"' install/honcho-install.sh || fail "Telemetry is not explicitly disabled"
grep -q 'write_env_value SENTRY_ENABLED "false"' install/honcho-install.sh || fail "Sentry is not explicitly disabled"
pass "Telemetry defaults"

grep -q '"updateable": false' json/honcho.json || fail "Development metadata unexpectedly advertises updates"
grep -q '"privileged": false' json/honcho.json || fail "Project metadata unexpectedly advertises a privileged CT"
pass "Development metadata safety invariants"

if grep -REn '(sk-[A-Za-z0-9_-]{20,}|BEGIN (RSA |EC |OPENSSH )?PRIVATE KEY|ghp_[A-Za-z0-9]{20,})' . \
  --exclude-dir=.git --exclude='validate.sh'; then
  fail "Possible secret/private key material found"
fi
pass "Obvious secret patterns"

[[ -x ct/honcho.sh ]] || fail "ct/honcho.sh is not executable"
[[ -x install/honcho-install.sh ]] || fail "install/honcho-install.sh is not executable"
[[ -x scripts/honcho-healthcheck.sh ]] || fail "healthcheck is not executable"
pass "Executable script modes"

printf '\nAll static project validation checks passed.\n'
