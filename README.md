# mps-monitoring

A self-contained Docker Compose monitoring stack for **logs + metrics**:

- **Prometheus** `v3.12.0` — metrics storage & querying
- **Loki** `3.7.2` — log storage & querying
- **Grafana** `13.0.2` — dashboards, with pre-provisioned Prometheus & Loki datasources and an overview dashboard
- **Alloy** `v1.17.0` — Docker-aware log shipper that tails container logs and pushes them to Loki

An optional **Wazuh** `5.0.0-beta5` SIEM (manager, indexer, dashboard) can be
added via the `wazuh` compose profile — see [Wazuh SIEM (optional)](#wazuh-siem-optional).

All services persist their data to bind-mounted host directories, except the
optional Wazuh SIEM, which uses Docker-managed named volumes.

## Layout

```
.
├── docker-compose.yml
├── .env                       # configurable bind IP + ports + versions
├── prometheus/
│   ├── prometheus.yml         # scrape config (self-scrape only by default)
│   └── data/                  # TSDB
├── loki/
│   ├── loki-config.yml
│   └── data/                  # chunks, tsdb, compactor, rules
├── alloy/
│   └── alloy.alloy            # River config
└── grafana/
    ├── grafana.ini
    ├── provisioning/
    │   ├── datasources/datasources.yml
    │   └── dashboards/dashboards.yml
    ├── dashboards/overview.json
    └── data/
```

## First-time setup

Bind-mounted data directories must be owned by the UID each container runs as before the first `docker compose up`, otherwise Loki/Grafana will fail with `permission denied` while creating subdirectories. Run the included setup script:

```bash
./setup.sh
```

It runs `sudo chown -R` on each data directory:

| Path                | Owner     | Why                                     |
|---------------------|-----------|-----------------------------------------|
| `./prometheus/data` | `65534:65534` | Prometheus runs as the unprivileged `nobody` user |
| `./loki/data`       | `10001:10001` | `grafana/loki` image runs as UID 10001 |
| `./grafana/data`    | `472:472`    | `grafana/grafana` image runs as UID 472 |

The script is idempotent — running it again does not reset your data.

## Bring the stack up

```bash
docker compose up -d
```

Endpoints (default `BIND_IP=127.0.0.1`):

| Service     | URL                              |
|-------------|----------------------------------|
| Grafana     | http://127.0.0.1:3000            |
| Prometheus  | http://127.0.0.1:9090            |
| Loki        | http://127.0.0.1:3100            |
| Alloy UI    | http://127.0.0.1:12345           |

Grafana login: `admin` / `admin` (change in `.env` and re-create the container, or change from the UI on first login).

## Wazuh SIEM (optional)

The stack ships an optional [Wazuh](https://wazuh.com) 5.x SIEM (manager,
indexer, dashboard), started only when the `wazuh` compose profile is enabled.
It is agent-based: the manager receives events from Wazuh agents running on the
hosts you want to monitor, the indexer stores the alerts, and the dashboard
presents them.

It is off by default. Enabling it adds roughly 3 GB of RAM usage (the indexer
alone reserves a 1 GB JVM heap, tunable via `WAZUH_INDEXER_HEAP`).

### First-time setup

The Wazuh containers mount TLS certificates that are not tracked in git.
Generate them once with:

```bash
./scripts/wazuh-setup.sh
```

It is idempotent and does the following:

1. Generates the deployment TLS certificates with the vendored
   `scripts/wazuh-certs-tool.sh` (built from `wazuh/wazuh-installation-assistant`
   `v5.0.0-beta5`) — **never regenerated**, since regenerating invalidates the
   TLS trust between the containers.
2. Persists `vm.max_map_count=262144` (required by the Wazuh indexer).

The manager generates its own agent-listener (`remoted`) certificate on first
start; container data lives in the Docker-managed named volumes
(`mps-monitoring_wazuh_*`).

### Enable and start

Set the profile in `.env`, then bring the stack up:

```env
COMPOSE_PROFILES=wazuh
```

```bash
docker compose up -d
```

### Endpoints

| Service          | URL / port                                          |
|------------------|-----------------------------------------------------|
| Wazuh dashboard  | `https://<BIND_IP>:<WAZUH_DASHBOARD_PORT>`          |
| Wazuh API        | `https://<BIND_IP>:<WAZUH_API_PORT>`                |
| Agent events     | `<BIND_IP>:<WAZUH_AGENT_PORT>` (TCP)                |
| Agent enrollment | `<BIND_IP>:<WAZUH_ENROLLMENT_PORT>` (TCP)           |
| Manager TLS      | `<BIND_IP>:<WAZUH_TLS_PORT>` (TCP)                  |
| Syslog           | `<BIND_IP>:<WAZUH_SYSLOG_PORT>` (UDP)               |

Log in to the dashboard as `admin` / `admin`. The 5.0 beta images ship the
OpenSearch demo credentials and also keep the demo indexer users — rotate or
remove them before exposing the dashboard. The internal service accounts are
configurable via `WAZUH_MANAGER_INDEXER_*` and `WAZUH_DASHBOARD_*` in `.env`;
changing them there requires the matching indexer user database.

### Prerequisites

- The agent / enrollment / API ports must be reachable from the hosts running
  Wazuh agents (open them in the firewall and set `BIND_IP` accordingly).
- `vm.max_map_count` must be at least `262144` (set by `wazuh-setup.sh`).
- The dashboard serves https with a self-signed certificate, so browsers warn.
- `WAZUH_DASHBOARD_PORT` defaults to `443`; change it (e.g. `8443`) if another
  service already binds `443` (a reverse proxy, etc.).
- These are **pre-release (5.0 beta) images**; pin a GA tag once available.

## Adding Prometheus scrape targets

Edit `prometheus/prometheus.yml` and add a new job under `scrape_configs`. Reload Prometheus without a restart:

```bash
curl -X POST http://127.0.0.1:9090/-/reload
```

A template block is included at the bottom of `prometheus.yml`.

## Exposing on a different IP

Edit `.env`:

```env
BIND_IP=0.0.0.0         # all interfaces
BIND_IP=192.168.1.10     # specific host IP
```

Then `docker compose up -d` (or `docker compose up -d --force-recreate`).

## How logs get into Loki

Alloy uses `discovery.docker` over `/var/run/docker.sock` to enumerate running containers, drops the monitoring stack itself (prometheus, loki, alloy, grafana) via relabel, then tails each remaining container's JSON log file at `/var/lib/docker/containers/<id>/<id>-json.log` (Docker's default `json-file` log driver) and ships it to Loki with `job=docker/<container_name>`.

**Requirement:** Docker must be using the default `json-file` log driver. If you've switched to `journald`, `syslog`, or a remote driver, adjust `alloy/alloy.alloy` accordingly.

## Notes

- Data persists on the host under each service's `data/` directory. Remove the directory to reset state.
- Retention: Prometheus `15d`, Loki `14d` (adjust in their respective configs).
- The overview dashboard auto-loads via provisioning under the **Overview** folder.
- To stop the stack cleanly: `docker compose down` (add `-v` to also remove Docker-managed anonymous volumes; bind-mounts are unaffected).