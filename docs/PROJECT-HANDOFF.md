# Project technical handoff

**Project:** `ImmacularIT/Proxmox-LXC-Honcho`  
**State:** development / runtime-unvalidated  
**Target:** Proxmox VE 9.x, Debian 13 AMD64 unprivileged LXC  
**Upstream Honcho:** 3.0.12 at `bd5fd4df62b5002b7aeff6e7f5a5237eb7157260`  
**Nested application runtime:** none

## Executive summary

This project converts Honcho's official self-hosted service topology into a native Proxmox LXC installation. It does not reimplement Honcho. The exact upstream source revision is fetched and verified, Python dependencies come from the upstream lockfile, and the long-running Honcho processes execute from that source under a dedicated unprivileged service account.

The Docker-to-native mapping is intentionally direct:

| Official service | Native LXC mapping |
|---|---|
| `api` | `honcho-api.service` |
| `deriver` | `honcho-deriver.service` |
| `database` (`pgvector/pgvector`) | Debian PostgreSQL + matching pgvector package |
| `redis` | Debian `redis-server.service` |

## Proxmox launcher boundary

`ct/honcho.sh` runs on the Proxmox host and owns only Proxmox/container concerns:

1. validate root, PVE 9.x, AMD64, and required host tools;
2. collect container ID, hostname, storage, bridge, IP mode, gateway, VLAN, resources, and initial LLM mode;
3. refresh the official Proxmox appliance catalog;
4. resolve the newest Debian 13 AMD64 standard template and appropriate template-cache storage;
5. create an unprivileged LXC with `nesting=1` and keyctl left disabled;
6. start the CT and resolve its IPv4 address;
7. push the container installer and a temporary root-only LLM configuration file;
8. execute the native installer;
9. preserve the failed container by default when installation fails;
10. report port 8000 on success.

The launcher does not install a nested application runtime and does not rewrite application networking inside the CT.

## Container installer boundary

`install/honcho-install.sh` runs as root inside Debian 13 and performs the native application installation:

1. validate Debian 13 AMD64 and installer configuration;
2. update Debian and install PostgreSQL, Redis, Python/build dependencies, and utilities;
3. discover the PostgreSQL major version and install Debian's matching pgvector package;
4. create the `honcho` system account and runtime home;
5. generate a random database password and create/update the `honcho_user` role;
6. create the `honcho` database if absent and provision pgvector as PostgreSQL administrator;
7. install the project version manifest;
8. install the pinned uv release;
9. fetch the exact Honcho Git commit and verify both commit SHA and upstream project version;
10. run `uv sync --frozen --no-install-project --no-group dev` against the upstream lockfile;
11. move the completed source/venv into an immutable versioned release path and update `/opt/honcho/current`;
12. install systemd units and native health tooling;
13. create root-only runtime configuration;
14. run Alembic migrations as the `honcho` account;
15. write the installation manifest;
16. enable/start API then Deriver;
17. run the native health helper;
18. remove temporary installer configuration and package caches.

## Database privilege decision

Honcho's application role is deliberately not a PostgreSQL superuser. The installer creates the pgvector extension as PostgreSQL administrator before migrations. Alembic migrations then run as `honcho_user` through the `honcho` Linux account.

The installer intentionally does not use Honcho's Docker `scripts/provision_db.py` as the normal native migration path because that helper calls `CREATE EXTENSION IF NOT EXISTS vector` from the application connection. PostgreSQL privilege checks can make that unsuitable for a least-privilege role even when the extension already exists.

## Runtime services

### API

`honcho-api.service`:

- user/group `honcho`;
- working directory `/opt/honcho/current`;
- environment `/etc/honcho/environment`;
- direct venv `fastapi run` command;
- port 8000;
- restart on failure;
- basic systemd filesystem/kernel hardening;
- writable path limited to `/var/lib/honcho` from the application service's perspective.

### Deriver

`honcho-deriver.service` uses the same identity/configuration/hardening and starts `python -m src.deriver` from the pinned virtual environment. It starts after the API, PostgreSQL, and Redis.

## LLM configuration

The initial installer exposes two modes:

- `openai`: only `LLM_OPENAI_API_KEY` is supplied; upstream Honcho model defaults remain authoritative.
- `compatible`: one OpenAI-compatible base URL/model is supplied and mapped to Deriver, Summary, all Dialectic levels, and Dream deduction/induction. Message embeddings are disabled initially to avoid requiring a separate embeddings endpoint.

This is an installation convenience, not a claim that one model is optimal for every Honcho tier. Administrators can edit `/etc/honcho/environment` later and restart both services.

## Runtime health definition

`honcho-lxc-healthcheck` currently verifies:

- PostgreSQL service active;
- Redis service active and responds to `PING`;
- API and Deriver services active;
- port 8000 listening;
- `/health` reports `status=ok`;
- pgvector installed in database `honcho`;
- Honcho application DB connectivity using its own SQLAlchemy stack;
- active release symlink and installation manifest;
- Docker/Podman absent.

This helper is necessary but not sufficient for release promotion. The Deriver must also be tested with a real message/LLM processing workflow in the runtime matrix.

## Upstream maintenance rule

The project pins a moving upstream project by exact commit rather than following `main`. For every upstream change selected for adoption, review at minimum:

- Dockerfile and entrypoint;
- `pyproject.toml` and `uv.lock`;
- database initialization/migrations;
- Redis/cache configuration;
- API and Deriver entry points;
- `.env.template` and model configuration names;
- required Python version;
- pgvector/PostgreSQL assumptions;
- authentication/telemetry defaults.

A pin update requires a fresh build and appropriate real-Proxmox regression checks before promotion.

## Current known limitations

- AMD64 only in the initial runtime gate.
- Proxmox VE 9.x only in the initial launcher gate.
- No adaptation-level updater/rollback helper.
- No adaptation-level backup/restore helper.
- No LanceDB mode in the initial installer.
- Compatible-provider mode uses one model across reasoning tiers initially.
- `AUTH_USE_AUTH=false` matches upstream self-hosting defaults and requires surrounding network/reverse-proxy security when exposed beyond trusted networks.
- Real Proxmox runtime status remains UNTESTED until evidence is recorded.
