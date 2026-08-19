# Runtime test plan

## Status

**Overall status: IN PROGRESS**

Repository/CI checks do not count as Proxmox runtime evidence. Mark an item passed only after it is exercised on a real supported Proxmox host and the result is recorded here.

## Target matrix

- Proxmox VE: 9.x
- LXC: unprivileged
- Guest: latest Debian 13 AMD64 standard template selected by launcher
- Feature: `nesting=1`
- keyctl: disabled
- Honcho pin: 3.0.12 / `bd5fd4df62b5002b7aeff6e7f5a5237eb7157260`

## A. Container creation

- [ ] Default Install creates an unused CT ID.
- [ ] Advanced Install honors CPU/RAM/disk overrides.
- [ ] DHCP configuration receives an IPv4 address.
- [ ] Static IPv4 + gateway succeeds.
- [ ] Optional VLAN succeeds in an appropriate test network.
- [ ] Invalid CT ID is rejected.
- [ ] Invalid hostname is rejected.
- [ ] Invalid CIDR/gateway/VLAN is rejected.
- [ ] LXC is unprivileged after creation.
- [ ] `nesting=1` is present.
- [ ] keyctl remains disabled.
- [x] No Docker/Podman runtime is installed.

## B. Native package/database installation

- [x] PostgreSQL service is active during installation.
- [x] Redis service is active during installation.
- [x] Detected PostgreSQL major version is accepted by the installer.
- [x] Matching Debian pgvector package installs.
- [x] Database `honcho` exists.
- [x] Role `honcho_user` exists.
- [x] `vector` extension exists in `honcho`.
- [x] Random DB password is written to protected runtime config.
- [x] Honcho database encoding is UTF8 with the patched installer.
- [x] Psycopg session client encoding is UTF8 and PostgreSQL text decodes to `str`.
- [ ] Verify role `honcho_user` is not superuser with an explicit runtime query.
- [x] Redis is reachable locally via the final health check.

## C. Upstream pin/build

- [x] uv installation step succeeds with pinned version 0.9.24.
- [x] Git checkout equals the pinned 40-character Honcho commit.
- [x] Upstream `pyproject.toml` reports 3.0.12.
- [x] `uv sync --frozen --no-install-project --no-group dev` succeeds.
- [x] FastAPI executable exists in the release venv.
- [x] `/opt/honcho/current` points at the expected immutable release.
- [x] Alembic module import succeeds on retained CT 210.

## D. Services

- [x] `systemd-analyze verify` passes during service-file installation.
- [x] Database migrations complete successfully through the pinned Alembic head.
- [ ] API starts and remains active for at least 10 minutes.
- [ ] Deriver starts and remains active for at least 10 minutes.
- [x] `/health` returns `{"status":"ok"}`.
- [ ] `/docs` loads from another host on the trusted network.
- [x] `honcho-lxc-healthcheck` passes.
- [ ] API restart recovers cleanly.
- [ ] Deriver restart recovers cleanly.
- [ ] Full LXC reboot returns both services to active state.

## E. Application functionality

Run these tests for each provider mode that will be advertised as supported.

### OpenAI direct

- [ ] Installer accepts API key without exposing it in terminal output/log summary.
- [ ] Workspace creation through `/v3/workspaces` succeeds.
- [ ] Session/peer/message creation succeeds.
- [ ] Deriver processes a real queued message.
- [ ] At least one derived observation/representation result can be retrieved.
- [ ] Dialectic request succeeds at a documented level.
- [ ] No repeated provider/auth errors appear in the Deriver journal.

### OpenAI-compatible endpoint

- [ ] Installer accepts base URL/model/key.
- [ ] API starts with `EMBED_MESSAGES=false`.
- [ ] Workspace creation succeeds.
- [ ] Real Deriver processing succeeds with the selected tool-capable model.
- [ ] Dialectic request succeeds.
- [ ] LXC can reconnect after provider endpoint restart.

## F. Security/persistence

- [ ] `/etc/honcho/environment` is root-only.
- [ ] `/etc/honcho/installation.json` is root-only.
- [ ] Honcho long-running processes run as `honcho`, not root.
- [ ] Database role is not PostgreSQL superuser.
- [ ] PostgreSQL data survives LXC reboot.
- [ ] Redis restarts cleanly after LXC reboot.
- [ ] Honcho application data survives API/Deriver restart and LXC reboot.
- [ ] No provider API key appears in Proxmox CT description.
- [ ] No provider API key appears in repository files.

## G. Failure handling

- [ ] Invalid provider key causes clear service diagnostics and keeps CT for debugging by default.
- [ ] Unreachable compatible endpoint produces understandable logs.
- [ ] PostgreSQL stopped: health helper fails explicitly on PostgreSQL.
- [ ] Redis stopped: health helper fails explicitly on Redis.
- [ ] API stopped: health helper fails explicitly on API.
- [ ] Deriver stopped: health helper fails explicitly on Deriver.
- [x] Failed launcher-managed installer keeps CT for debugging by default.

## Evidence record

### 2026-08-19 - pinned checkout ownership

```text
CT ID: 210
Honcho commit: bd5fd4df62b5002b7aeff6e7f5a5237eb7157260
Result: FAILED during pinned upstream checkout verification
Observed: clone/fetch/checkout as honcho succeeded, then root-owned `git rev-parse HEAD` triggered Git safe.directory/dubious-ownership protection.
Fix: verify the commit as the checkout owner.
Fix commits: 4820cb6b89e427cb0add2815c19a1f27d5d5d427, c553c22b89c3b817447d1bd07c7db56a198bae9a
Rerun: passed the original failure point.
```

### 2026-08-19 - Alembic console shim

```text
CT ID: 210
Result: FAILED at migration invocation because `/opt/honcho/current/.venv/bin/alembic` was unavailable.
Fix: verify `import alembic` after uv sync and invoke migrations as `.venv/bin/python -m alembic upgrade head` from `/opt/honcho/current`.
Fix commits: a55f4c21199e33f55069037155f63758cbe73faa, e2564ab4155abbac9417198a3907aa19480a3960, 2b88ba05f4f266fa9d41171372f4fc581107ad30
Rerun: Alembic module import passed.
```

### 2026-08-19 - PostgreSQL text decoding

```text
CT ID: 210
Result: FAILED while SQLAlchemy initialized PostgreSQL for Alembic.
Observed: `pg_catalog.version()` reached SQLAlchemy as bytes and caused `TypeError: cannot use a string pattern on a bytes-like object`.
Fix: explicit UTF8 database creation/validation, database client_encoding default, UTF8 connection parameter, and a direct Psycopg pre-migration probe requiring UTF8 plus string-valued PostgreSQL text.
Fix commits: 65756cda90347b4d7cfe91626aef31970f851b10, 2bedac7b0d99142dc665eeb50da95700f4c2ad5a, 047e58f082a74bf1af4edd9b49aa43d2c2b57611
Rerun: UTF8 probe passed and the complete Alembic migration chain reached head successfully.
```

### 2026-08-19 - API process startup

```text
CT ID: 210
Passed before failure: PostgreSQL UTF8/client decoding validation and complete database migration chain.
First API failure: systemd status 203/EXEC because the generated `.venv/bin/fastapi` console script retained its pre-relocation interpreter path after the venv was moved from `/var/tmp` into the immutable release directory.
Fix: API unit invokes FastAPI through the venv interpreter as `.venv/bin/python -m fastapi`; fresh installs now move the verified source to the final immutable release path before `uv sync`, so generated console-script shebangs reference the permanent venv path.
Fix commits: 15127ad19a292b4ada98549e5b93e5aa63d30995, 8076eec5aef5c05a4b45b82841e4dde827f25833, 579efd3e656e1e15b41cdc6d69456aa053be09ed, 7f389ad0767c4b99c42382bd5669749df106509d
Manual recovery: exact patched unit was installed and reloaded on CT 210. `/opt/honcho/current/.venv/bin/python` reported Python 3.11.14. The API then started successfully as PID 6502, imported `src.main:app`, connected to Redis, completed application startup, and Uvicorn bound `0.0.0.0:8000`.
Observed active duration before administrative stop: 2 minutes 48 seconds. At 20:51:31 UTC systemd sent SIGTERM, Uvicorn performed a clean application shutdown, systemd recorded `Result=success`, and `NRestarts=0`. This was an explicit service stop from the debugging workflow, not an application crash or sustained-runtime failure.
```

### 2026-08-19 - API, Deriver, and native health check

```text
CT ID: 210
Result: PASSED immediate native service health checks.
API: restarted after the administrative stop and `/health` returned `{"status":"ok"}`.
Deriver: active and running as `.venv/bin/python -m src.deriver`; journal showed `Starting deriver queue processor`, `Running main loop`, successful Redis cache connection, and `ReconcilerScheduler started` with `sync_vectors` and `cleanup_queue` tasks.
Native health helper passed: PostgreSQL active; Redis active and PING succeeded; API active and listening on TCP/8000; Deriver active; `/health` reported ok; Honcho database encoding UTF8; pgvector 0.8.0 installed; application SQLAlchemy connection succeeded with UTF8 client encoding; release symlink and installation manifest present; no Docker/Podman runtime installed.
Observed locale warnings: inherited Proxmox locale variables referenced Swedish/en_US locales not generated in the guest. These warnings were non-fatal and did not affect PostgreSQL results. Health helper now normalizes LANG/LC_ALL to Debian C.UTF-8.
Locale cleanup commits: 971960e5cc8f22560d1271d234f91616c1308b73, eb5c64b1d13047caba2ad9f7d446013d510d2c5c
Intermediate stability check: API remained active for 5 minutes and Deriver for 4 minutes 43 seconds, and the complete native health helper still passed. This does not yet satisfy the 10-minute continuous-active gate. The retained CT was still running the pre-locale-cleanup health helper at this checkpoint, which explains the repeated non-fatal locale warnings.
Remaining: API and Deriver must still demonstrate at least 10 minutes continuous active time; external `/docs`, restart recovery, reboot persistence, security checks, and real application/provider functionality remain pending.
```

## Promotion gate

Do not promote the development implementation to a released `main` state until the maintainer explicitly approves after the required runtime items above are recorded as passed or deliberately scoped out with rationale.
