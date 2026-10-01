#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# Initial setup for the Wazuh SIEM service of the mps-monitoring stack.
#
# What this does (idempotent):
#   1. Generates the deployment TLS certificates -- ONLY when no root CA
#      exists. Certificates are never regenerated: doing so would invalidate the
#      TLS trust between the containers.
#   2. Persists vm.max_map_count=262144, required by the Wazuh indexer.
#
# The certificate tool is vendored at scripts/wazuh-certs-tool.sh (built from
# wazuh/wazuh-installation-assistant v5.0.0-beta5); nothing is downloaded.
# Container data lives in Docker-managed named volumes (see docker-compose.yml),
# and credentials come from the environment -- neither is prepared here.
#
# Usage:
#   ./scripts/wazuh-setup.sh
#
# Idempotent: safe to re-run any time.
# -----------------------------------------------------------------------------

set -euo pipefail

SCRIPT_PATH="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"

# Re-exec as root: certificate ownership and the sysctl need it.
if [[ "$(id -u)" -ne 0 ]]; then
  if command -v sudo >/dev/null 2>&1; then
    exec sudo bash "$SCRIPT_PATH" "$@"
  fi
  echo "error: this script needs root (or sudo)" >&2
  exit 1
fi

# Run from the repo root, not the script's directory.
cd "$(dirname "$SCRIPT_PATH")/.."

while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help)
      sed -n '2,22p' "$0"; exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
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

require openssl
require chown

WAZUH_DIR="services/wazuh"
CONFIG_DIR="${WAZUH_DIR}/config"
VENDORED_TOOL="scripts/wazuh-certs-tool.sh"

# ----- 1. certificates -------------------------------------------------------
echo "==> Certificates..."

# A previous `docker compose up` before the certificates existed makes Docker
# create the missing bind-mount sources as *directories* (e.g. root-ca.pem/).
# Clear those placeholders so the real files can be written.
if [[ -d "${CONFIG_DIR}" ]] && find "${CONFIG_DIR}" -name '*.pem' -type d | read -r; then
  echo "  removing invalid certificate placeholders (directories) under ${CONFIG_DIR}"
  rm -rf "${CONFIG_DIR}"
fi

if [[ -f "${CONFIG_DIR}/root-ca/certs/root-ca.pem" ]]; then
  echo "  root CA present (${CONFIG_DIR}/root-ca/certs/root-ca.pem) -- not regenerated"
else
  echo "  generating deployment certificates"
  # certificates-conf.sh expects the tool and config.yml in the working dir.
  cp -f "$VENDORED_TOOL" "${WAZUH_DIR}/wazuh-certs-tool.sh"
  chmod 700 "${WAZUH_DIR}/wazuh-certs-tool.sh"
  (
    cd "$WAZUH_DIR"
    bash "../../scripts/wazuh-certificates-conf.sh" --cert --copy --priv
  )
fi

# The cert tool rewrites config.yml (CRLF -> LF) with umask 0077 while running
# as root, which would leave the tracked file root:root 600. Restore the
# working-tree artifacts to the user who invoked sudo so the repo stays
# committable. The generated certificates under config/ keep their 101:101 /
# 0:101 ownership -- the containers need it.
if [[ -n "${SUDO_UID:-}" ]]; then
  chown "${SUDO_UID}:${SUDO_GID}" "${WAZUH_DIR}/config.yml" 2>/dev/null || true
  chmod 644 "${WAZUH_DIR}/config.yml" 2>/dev/null || true
  for p in "${WAZUH_DIR}/wazuh-certs-tool.sh" \
           "${WAZUH_DIR}/wazuh-certificates" \
           "${WAZUH_DIR}/wazuh-certificates-tool.log"; do
    [[ -e "$p" ]] && chown -R "${SUDO_UID}:${SUDO_GID}" "$p" 2>/dev/null || true
  done
fi

# ----- 2. vm.max_map_count ---------------------------------------------------
echo "==> Ensuring vm.max_map_count for the Wazuh indexer..."
TARGET_MAX_MAP=262144
CURRENT_MAX_MAP="$(cat /proc/sys/vm/max_map_count 2>/dev/null || echo 0)"
if [[ "${CURRENT_MAX_MAP:-0}" -ge "$TARGET_MAX_MAP" ]]; then
  echo "  vm.max_map_count=${CURRENT_MAX_MAP} (ok)"
else
  echo "  vm.max_map_count=${CURRENT_MAX_MAP} < ${TARGET_MAX_MAP}: setting it"
  echo "vm.max_map_count = ${TARGET_MAX_MAP}" > /etc/sysctl.d/99-mps-wazuh.conf
  sysctl -p /etc/sysctl.d/99-mps-wazuh.conf >/dev/null 2>&1 || true
fi

echo
echo "Done. Next steps:"
echo "  set COMPOSE_PROFILES=wazuh in .env"
echo "  docker compose up -d"
