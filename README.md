# mps-monitoring

A self-contained Docker Compose monitoring stack for **logs + metrics**:

- **Prometheus** `v3.12.0` — metrics storage & querying
- **Loki** `3.7.2` — log storage & querying
- **Grafana** `13.0.2` — dashboards, with pre-provisioned Prometheus & Loki datasources and an overview dashboard
- **Alloy** `v1.17.0` — Docker-aware log shipper that tails container logs and pushes them to Loki

All services persist their data to bind-mounted host directories.

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