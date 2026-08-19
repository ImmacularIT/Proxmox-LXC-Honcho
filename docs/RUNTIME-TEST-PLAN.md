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
- [ ] No Docker/Podman runtime is installed.

## B. Native package/database installation

- [ ] PostgreSQL service is active.
- [ ] Redis service is active.
- [ ] Detected PostgreSQL major version is correct.
- [ ] Matching Debian pgvector package installs.
- [ ] Database `honcho` exists.
- [ ] Role `honcho_user` exists and is not superuser.
- [ ] `vector` extension exists in `honcho`.
- [ ] Random DB password is stored only in root-protected runtime config.
- [ ] Redis is reachable locally.

## C. Upstream pin/build

- [ ] uv reports pinned version 0.9.24.
- [ ] Git checkout equals the pinned 40-character Honcho commit.
- [ ] Upstream `pyproject.toml` reports 3.0.12.
- [ ] `uv sync --frozen --no-install-project --no-group dev` succeeds.
- [ ] FastAPI executable exists in the release venv.
- [ ] `/opt/honcho/current` points at the expected immutable release.

## D. Services

- [ ] `systemd-analyze verify` passes in the completed LXC.
- [ ] API starts and remains active for at least 10 minutes.
- [ ] Deriver starts and remains active for at least 10 minutes.
- [ ] `/health` returns `{"status":"ok"}`.
- [ ] `/docs` loads from another host on the trusted network.
- [ ] `honcho-lxc-healthcheck` passes.
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
- [ ] Failed installer offers keep/destroy choice.

## Evidence record

### 2026-08-19 - first real Proxmox installation attempt

```text
Date: 2026-08-19
Tester: maintainer
CT ID: 210
Honcho commit: bd5fd4df62b5002b7aeff6e7f5a5237eb7157260
Result: FAILED during pinned upstream checkout verification
Observed: clone/fetch/checkout as honcho succeeded, then root-owned `git rev-parse HEAD` triggered Git safe.directory/dubious-ownership protection.
Fix: commit verification changed to run as the checkout owner (`runuser -u honcho -- git ... rev-parse HEAD`). Regression validation added to reject the root-owned pattern.
Fix commits: 4820cb6b89e427cb0add2815c19a1f27d5d5d427 and c553c22b89c3b817447d1bd07c7db56a198bae9a
Rerun: pending on retained CT 210
```

Record subsequent real validation here before promotion:

```text
Date:
Tester:
Proxmox VE version:
Kernel:
Node architecture:
Debian template:
CT ID:
Install method:
Network mode:
Provider mode:
Honcho commit:
Result:
Notes / deviations:
```

## Promotion gate

Do not promote the development implementation to a released `main` state until the maintainer explicitly approves after the required runtime items above are recorded as passed or deliberately scoped out with rationale.
