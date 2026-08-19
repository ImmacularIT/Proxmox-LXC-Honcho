# Proxmox LXC Honcho

An unofficial native Proxmox VE LXC adaptation of [Honcho](https://github.com/plastic-labs/honcho), maintained by [ImmacularIT](https://github.com/ImmacularIT).

> **Development status:** This branch contains the initial native adaptation and repository validation. The real-Proxmox runtime matrix has **not** been marked complete yet. Do not treat the current development branch as a released/runtime-certified build.

## What this project does

Honcho's official self-hosted Docker Compose stack runs four core services: the Honcho API, the Deriver background worker, PostgreSQL with pgvector, and Redis. Honcho also documents a manual non-Docker installation path.

This project maps those components into one unprivileged Debian 13 LXC without installing Docker, Docker Compose, Podman, Kubernetes, or another nested application runtime:

- PostgreSQL and pgvector run as native Debian services/packages.
- Redis runs as the native Debian `redis-server` service.
- Honcho is fetched from an exact pinned upstream Git commit.
- Python dependencies are installed from Honcho's upstream lockfile with a pinned `uv` release.
- The Honcho API and Deriver run as separate systemd services under a dedicated `honcho` system account.
- Runtime secrets are stored in `/etc/honcho/environment` with root-only permissions.
- A native health helper validates PostgreSQL, pgvector, Redis, both Honcho services, the API health endpoint, application DB connectivity, and absence of Docker/Podman.

## Current upstream pin

| Component | Version / revision |
|---|---|
| Honcho | `3.0.12` |
| Honcho commit | `bd5fd4df62b5002b7aeff6e7f5a5237eb7157260` |
| uv | `0.9.24` |
| Base OS | Debian 13 |
| Architecture | AMD64 |

The installer never clones a moving Honcho branch for the runtime release. It fetches the exact commit above and verifies both the Git SHA and the version declared by that source tree before installation proceeds.

## Development installation

Run this command as `root` in the Proxmox VE host shell:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/ImmacularIT/Proxmox-LXC-Honcho/development/ct/honcho.sh)
```

The launcher currently targets Proxmox VE 9.x and AMD64.

### Default container resources

- 2 CPU cores
- 4096 MiB RAM
- 20 GiB root disk
- unprivileged Debian 13 AMD64 LXC
- Proxmox `nesting=1`
- `keyctl` remains disabled

`nesting=1` is used as a Debian 13/Systemd-in-LXC compatibility choice. Honcho itself does not use a nested Docker/Podman/Kubernetes runtime.

Advanced Install allows CPU, RAM, and disk customization.

## Installer prompts

The host-side launcher asks for:

- container ID and hostname;
- root-disk storage;
- bridge;
- DHCP or static IPv4;
- static gateway when required;
- optional VLAN;
- LLM provider configuration;
- optional advanced CPU/RAM/disk values.

The complete container configuration is shown before the LXC is created.

### LLM provider choices

Honcho requires a working LLM provider. The initial adaptation supports two installer modes:

1. **OpenAI direct** - enter an OpenAI API key and use Honcho's upstream default model configuration.
2. **OpenAI-compatible endpoint** - enter a base URL, API key (or a local placeholder such as `ollama`), and one tool-capable model name. The installer initially assigns that model to all Honcho reasoning tiers and disables message embeddings so a text-only local endpoint can start cleanly.

The resulting provider secrets are pushed into the LXC through a temporary root-only installer file and are stored at `/etc/honcho/environment`. They are not written into the Proxmox description or this repository.

## Native architecture

```text
Client / Agent
     |
     v
Honcho API :8000
     |
     +---- PostgreSQL + pgvector (local service)
     |
     +---- Redis (local service)
     |
     +---- Honcho Deriver (systemd background worker)
                |
                v
          configured LLM provider
```

The exact PostgreSQL major version is discovered from Debian's installed cluster. The installer then installs the matching `postgresql-<major>-pgvector` package.

### Filesystem layout

| Path | Purpose |
|---|---|
| `/opt/honcho/releases/<version>-<commit>` | Immutable pinned Honcho release |
| `/opt/honcho/current` | Active release symlink |
| `/var/lib/honcho` | Runtime home/cache for the unprivileged `honcho` account |
| `/etc/honcho/environment` | Root-only database/provider/runtime configuration |
| `/etc/honcho/installation.json` | Installation manifest |
| `/usr/local/sbin/honcho-lxc-healthcheck` | Native health helper |
| `/etc/systemd/system/honcho-api.service` | FastAPI service |
| `/etc/systemd/system/honcho-deriver.service` | Deriver worker service |

PostgreSQL and Redis retain their standard Debian persistent-data locations.

## Service commands

```bash
systemctl status honcho-api.service
systemctl status honcho-deriver.service
journalctl -u honcho-api.service -b
journalctl -u honcho-deriver.service -b
honcho-lxc-healthcheck
```

The API is exposed on:

```text
http://CONTAINER-IP:8000
```

Interactive API documentation is available at:

```text
http://CONTAINER-IP:8000/docs
```

## Database model

The installer creates:

- database: `honcho`
- application role: `honcho_user`
- a random URL-safe database password
- pgvector extension installed by PostgreSQL's administrative account
- schema ownership assigned to `honcho_user`

The application role is not made a PostgreSQL superuser. Database migrations run under the dedicated `honcho` Linux account after pgvector has been provisioned.

## Security boundaries

- LXC is unprivileged.
- Honcho API and Deriver run as the `honcho` system account, not root.
- PostgreSQL and Redis use their normal Debian service identities.
- Honcho's provider/API secrets are stored in a root-only environment file.
- Sentry and Honcho CloudEvents telemetry are disabled by the adaptation's generated runtime configuration.
- No Docker/Podman runtime is installed by this project.
- Proxmox remains responsible for bridge/VLAN/IP/firewall/NAT policy.
- `AUTH_USE_AUTH=false` is currently retained to match Honcho's documented self-hosting default. Do not expose port 8000 directly to an untrusted network without adding appropriate authentication/reverse-proxy controls.

## Lifecycle scope

The initial adaptation is deliberately **not** marked updateable. A future Honcho revision must be treated as a new native adaptation cycle:

1. select and pin the exact upstream commit;
2. inspect upstream Dockerfile, `pyproject.toml`, lockfile, migrations, service startup, configuration, PostgreSQL/Redis assumptions, and LLM settings;
3. update project pins only after review;
4. run repository validation;
5. build a fresh Proxmox LXC;
6. execute the applicable real-runtime matrix;
7. promote only after recorded runtime evidence passes.

No adaptation-level backup/restore or in-place updater is advertised in the initial development build.

## Repository layout

```text
.github/workflows/syntax.yml
    Repository validation.

ct/honcho.sh
    Proxmox-host launcher.

install/honcho-install.sh
    Container-side native installer.

lib/versions.sh
    Canonical Honcho/uv/version pins.

scripts/honcho-healthcheck.sh
    Native runtime health helper.

systemd/honcho-api.service
systemd/honcho-deriver.service
    Native long-running services.

json/honcho.json
    Project metadata/default resources.

docs/PROJECT-HANDOFF.md
    Architecture and maintenance boundaries.

docs/RUNTIME-TEST-PLAN.md
    Real-Proxmox validation matrix and evidence template.

tests/validate.sh
    Static project invariants.
```

## Validation status

Static repository validation is part of this branch. Real Proxmox validation remains **UNTESTED** until results are recorded in `docs/RUNTIME-TEST-PLAN.md`.

Repository review or CI success must never be described as a passed Proxmox runtime test.

## Project identity and licensing

Honcho remains an upstream project maintained by Plastic Labs and is licensed under AGPL-3.0. This repository does not vendor or relicense Honcho source; the installer fetches an exact upstream revision during installation.

The ImmacularIT launcher, native integration scripts, systemd units, metadata, and documentation in this repository are licensed under the MIT License unless otherwise noted.
