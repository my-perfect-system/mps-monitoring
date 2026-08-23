#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# Initial setup for the mps-monitoring stack.
#
# What this does:
#   1. Creates the bind-mounted data directories if they don't exist.
#   2. chowns them to the UIDs each container runs as (so the container can
#      create its subdirs at first start without permission-denied errors).
#   3. Verifies the docker data root used by Alloy matches the host (so log
#      tailing works). Suggests a fix if it doesn't.
#
# Usage:
#   ./scripts/setup.sh                 # create dirs and chown
#   ./scripts/setup.sh --skip-chown    # just create dirs (run if your host
#                                      # already has the right ownership)
#
# Idempotent: safe to re-run any time.
# -----------------------------------------------------------------------------

set -euo pipefail

# Run from the repo root, not the script's directory.
cd "$(dirname "$0")/.."

SKIP_CHOWN=0
for arg in "$@"; do
  case "$arg" in
    --skip-chown) SKIP_CHOWN=1 ;;
    -h|--help)
      sed -n '2,16p' "$0"; exit 0 ;;
    *)
      echo "Unknown argument: $arg" >&2
      exit 2
      ;;
  esac
done

require() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "error: required command '$1' not found in PATH" >&2
    exit 1
  fi
}

require docker
require chown

# Load .env so we know which paths/UIDs to use (without exporting it
# into the current shell).
if [[ -f .env ]]; then
  # shellcheck disable=SC2046
  set -a; . ./.env; set +a
else
  echo "error: .env file not found in $(pwd)" >&2
  exit 1
fi

# ----- directory layout -------------------------------------------------------
# Bind-mounted config directories (read-only mounts into containers).
CONFIG_DIRS=(
  services/prometheus
  services/loki
  services/alloy
  services/grafana
  services/grafana/provisioning
  services/grafana/provisioning/datasources
  services/grafana/provisioning/dashboards
  services/grafana/dashboards
)

# Bind-mounted data directories (need correct ownership).
# UID:GID mapping per service (matches the user baked into each image).
# Grafana runs as root in this stack so it can manage bundled plugins, so
# its data dir is left owned by the host user (or 472 if previously chowned).
declare -A DATA_DIR_OWNER=(
  [services/prometheus/data]="65534:65534"
  [services/loki/data]="10001:10001"
)

# ----- functions --------------------------------------------------------------
maybe_sudo() {
  # Use sudo only if we can't chown as the current user.
  if chown --ref="$(mktemp -d)" "$1" "$2" >/dev/null 2>&1; then
    :
  else
    if command -v sudo >/dev/null 2>&1; then
      sudo -n true 2>/dev/null && echo sudo || true
      sudo chown "$@"
    else
      echo "error: cannot chown $2 (no write permission, no sudo available)" >&2
      exit 1
    fi
  fi
}

ensure_dir() {
  local dir="$1"
  if [[ ! -d "$dir" ]]; then
    mkdir -p "$dir"
    echo "  created: $dir"
  fi
}

# ----- 1. directories ----------------------------------------------------------
echo "==> Ensuring directory layout exists..."
for d in "${CONFIG_DIRS[@]}" "${!DATA_DIR_OWNER[@]}" services/grafana/data; do
  ensure_dir "$d"
done

# ----- 2. ownership ------------------------------------------------------------
if [[ "$SKIP_CHOWN" -eq 0 ]]; then
  echo "==> Fixing ownership of bind-mounted data directories..."
  for dir in "${!DATA_DIR_OWNER[@]}"; do
    owner="${DATA_DIR_OWNER[$dir]}"
    echo "  chown -R $owner $dir"
    maybe_sudo -R "$owner" "$dir"
  done
else
  echo "==> Skipping chown (--skip-chown)"
fi

# ----- 3. docker data root sanity check ---------------------------------------
echo "==> Verifying docker data root for Alloy log shipping..."

# Detect Docker Root Dir; works on standard Docker, containerd-Docker,
# and rootless setups (fallback: try `docker info`).
if command -v docker >/dev/null 2>&1; then
  # Try multiple discovery methods because `docker info` output format varies.
  DOCKER_ROOT=$(docker info 2>/dev/null \
    | awk -F': ' '/Docker Root Dir/ {print $2; exit}' \
    | tr -d ' ')
  if [[ -z "$DOCKER_ROOT" ]]; then
    DOCKER_ROOT=$(docker info 2>/dev/null \
      | grep -oE 'docker.root.dir[^ ]* = [^ ]+' \
      | head -1 | awk -F'= ' '{print $2}')
  fi
fi

# Compose candidates: standard + containerd-snapshotter variant seen on
# this system + configurable fallback.
CANDIDATES=(
  "/var/lib/docker/containers"
  "$DOCKER_ROOT/containers"
)

if [[ -n "${DOCKER_CONTAINERS_DIR:-}" ]]; then
  TARGET="$DOCKER_CONTAINERS_DIR"
else
  TARGET="/var/lib/docker/containers"
fi

# Look for the first candidate that actually contains a *-json.log file.
FOUND=""
for c in "${CANDIDATES[@]}"; do
  [[ -z "$c" ]] && continue
  [[ ! -d "$c" ]] && continue
  # We can only inspect dirs we have permission to read.
  if compgen -G "$c/*/*-json.log" >/dev/null 2>&1; then
    FOUND="$c"
    break
  fi
done

if [[ -n "$FOUND" && "$FOUND" != "$TARGET" ]]; then
  echo "  NOTE: detected container JSON logs at:"
  echo "    $FOUND"
  echo "  But .env has DOCKER_CONTAINERS_DIR=$TARGET"
  echo "  Update .env to match (or run \`docker info | grep 'Docker Root Dir'\`)."
fi

if [[ -d "$TARGET" ]] || [[ -n "$FOUND" ]]; then
  USED="${FOUND:-$TARGET}"
  echo "  using: $USED"
else
  echo "  WARNING: could not locate container JSON log directory."
  echo "  If Alloy can't tail logs, set DOCKER_CONTAINERS_DIR in .env to"
  echo "  the path returned by: docker info | grep 'Docker Root Dir'"
fi

echo
echo "Done. Next steps:"
echo "  docker compose up -d"
echo
echo "If a service still fails with permission errors, run again with"
echo "  ./scripts/setup.sh     # re-applies chown"