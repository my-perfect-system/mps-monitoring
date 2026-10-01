# AGENTS.md — mps-monitoring

Docker Compose monitoring stack for **logs + metrics** — Prometheus, Loki,
Grafana — plus an **optional Wazuh SIEM** (manager, indexer, dashboard) behind
a compose profile. Deployed by `odem.services.monitoring`.

## Stack

| Service | Image | Notes |
|---|---|---|
| Prometheus | `${PROMETHEUS_VERSION}` | metrics; remote-write receiver enabled (Alloy pushes to it) |
| Loki | `${LOKI_VERSION}` | logs |
| Grafana | `${GRAFANA_VERSION}` | dashboards |
| Wazuh manager / indexer / dashboard | `${WAZUH_VERSION}` (`5.0.0-beta5`) | compose profile `wazuh`, opt-in |

Core services persist to bind-mounted `services/*/data/`. **Wazuh uses Docker
named volumes** (`mps-monitoring_wazuh_*`).

## Layout

```
docker-compose.yml
.env / .env.example            # bind IP, ports, versions, Wazuh creds, COMPOSE_PROFILES
scripts/
  setup.sh                     # core data dirs + chowns + Alloy data-root check
  wazuh-setup.sh               # one-time Wazuh setup (certificates + vm.max_map_count)
  wazuh-certs-tool.sh          # vendored cert tool (generated, tracked)
  wazuh-certificates-conf.sh   # vendored upstream helper (unmodified)
services/
  prometheus/ loki/ grafana/   # bind-mounted config + data
  wazuh/
    config.yml                 # tracked — cert-tool node config (DNS names)
    config/                    # gitignored — generated certs
    wazuh-certificates/        # gitignored — cert-tool output
    wazuh-certs-tool.sh        # gitignored — runtime copy of the vendored tool
```

## Wazuh SIEM conventions

- **Opt-in**: `profiles: ["wazuh"]` on the three services, enabled via
  `COMPOSE_PROFILES=wazuh` in `.env`. `odem.services.monitoring` renders this
  from `monitoring_enable_wazuh`.
- **Hostnames are the certificate DNS names**: `wazuh.manager`,
  `wazuh.indexer`, `wazuh.dashboard` must match `services/wazuh/config.yml`
  and stay on the shared `monitoring` network.
- **Certificates are never regenerated.** `wazuh-setup.sh` generates them only
  when `services/wazuh/config/root-ca/certs/root-ca.pem` is missing;
  regenerating invalidates the TLS trust between the containers. The manager
  self-generates its agent-listener (`remoted`) pair on first start.
- **Named volumes, not bind mounts** (deliberate). Bind mounts were tried and
  failed two ways: `docker cp` seeding loses file ownership (the daemons run
  as uid 101, so they could not read `wazuh-manager.conf`), and mounting the
  cert files *inside* a bind-mounted `etc` makes the directory look non-empty,
  so the manager entrypoint skips installing its config. Named volumes get the
  image content and ownership automatically.
- **Credentials come from the environment** (`.env`):
  `WAZUH_MANAGER_INDEXER_{USER,PASSWORD}` (`wazuh-manager`/`wazuh-manager`) and
  `WAZUH_DASHBOARD_{USER,PASSWORD}` (`kibanaserver`/`kibanaserver`). The
  dashboard login is the indexer demo user `admin`/`admin`; the beta images
  also keep the OpenSearch demo users — rotate or remove them before exposing.
- **Version `5.0.0-beta5`.** The `wazuh-docker` `main` branch targets `5.1.0`,
  whose images are **not published**, and `packages.wazuh.com/5.0/` returns
  403 (pre-release artifacts), so the cert tool is vendored rather than
  downloaded.
- **Cert tool provenance**: `scripts/wazuh-certs-tool.sh` is built from
  `wazuh/wazuh-installation-assistant` tag `v5.0.0-beta5` via `builder.sh -c`
  (self-contained; needs only `openssl`). `wazuh-certificates-conf.sh` is
  vendored unmodified from the same tag's `tools/utils/deployment/`.
- **Dashboard port**: `WAZUH_DASHBOARD_PORT` defaults to `443`; use `8443`
  when another service (e.g. `swag`) already binds `443`.
- **Indexer `9200` is not published** to the host.
- **`vm.max_map_count=262144`** is required by the indexer; `wazuh-setup.sh`
  persists it under `/etc/sysctl.d/`.

## Gotchas

- Run `./scripts/wazuh-setup.sh` **before** the first `docker compose up` with
  the `wazuh` profile enabled. If containers start first, Docker creates the
  missing certificate bind sources as *directories*; the setup script detects
  and removes those placeholders, but the containers must then be recreated
  (`docker compose up -d --force-recreate wazuh.indexer wazuh.manager wazuh.dashboard`).
- Do not hand-edit or delete the generated certificates without expecting the
  containers/agents to lose trust.
- Legacy `services/wazuh/data/` is unused (pre-named-volume state) and stays
  gitignored only so an old private key cannot be committed; safe to delete.
- Wazuh container logs reach Loki via the host's `odem.alloy` Docker log
  tailing (they are not in the monitoring stack's own drop list).
- A stale `alloy` container may be reported as an orphan by Compose
  (`--remove-orphans`); it is unrelated to this stack.

## Commands

```bash
./scripts/setup.sh              # core stack data dirs (idempotent)
./scripts/wazuh-setup.sh        # Wazuh certificates + sysctl (idempotent)
docker compose up -d            # respects COMPOSE_PROFILES
docker compose ps
```