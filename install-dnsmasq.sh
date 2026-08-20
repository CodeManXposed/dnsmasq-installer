#!/usr/bin/env bash
set -Eeuo pipefail

CONFIG_FILE="/etc/dnsmasq.d/zznet.conf"
RESOLV_FILE="/etc/resolv.conf"
UPSTREAM="${1:-}"

usage() {
  echo "Usage: sudo bash $0 <DNS_IP>"
  echo "Example: sudo bash $0 103.214.22.32"
}

if [[ ${EUID} -ne 0 ]]; then
  echo "Error: run this script as root." >&2
  exit 1
fi

if [[ -z "${UPSTREAM}" || "${UPSTREAM}" == -* || "${UPSTREAM}" =~ [^0-9A-Fa-f:.] ]]; then
  usage >&2
  exit 1
fi

if [[ ! -r /etc/os-release ]]; then
  echo "Error: cannot identify the operating system." >&2
  exit 1
fi

# shellcheck disable=SC1091
. /etc/os-release
case "${ID:-}" in
  debian|ubuntu) ;;
  *)
    echo "Error: only Debian and Ubuntu are supported (detected: ${ID:-unknown})." >&2
    exit 1
    ;;
esac

export DEBIAN_FRONTEND=noninteractive
echo "[1/6] Installing dnsmasq and DNS test tools..."
apt-get update
apt-get install -y dnsmasq dnsutils

STAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP_DIR="/root/dnsmasq-backup-${STAMP}"
mkdir -p "${BACKUP_DIR}"
cp -a "${RESOLV_FILE}" "${BACKUP_DIR}/resolv.conf" 2>/dev/null || true
if [[ -e "${CONFIG_FILE}" ]]; then
  cp -a "${CONFIG_FILE}" "${BACKUP_DIR}/zznet.conf"
fi

echo "[2/6] Writing a local-only dnsmasq configuration..."
install -d -m 0755 /etc/dnsmasq.d
{
  echo "# Local caching DNS; installed ${STAMP}"
  echo "no-resolv"
  echo "server=${UPSTREAM}"
  echo "listen-address=127.0.0.1,::1"
  echo "bind-interfaces"
  echo "cache-size=10000"
  echo "domain-needed"
  echo "bogus-priv"
} > "${CONFIG_FILE}"
chmod 0644 "${CONFIG_FILE}"

echo "[3/6] Checking the configuration..."
dnsmasq --test

echo "[4/6] Starting dnsmasq..."
systemctl enable dnsmasq >/dev/null
systemctl restart dnsmasq

echo "[5/6] Pointing this server at local dnsmasq..."
rm -f "${RESOLV_FILE}"
{
  echo "# Managed by install-dnsmasq.sh"
  echo "nameserver 127.0.0.1"
  echo "options timeout:2 attempts:2"
} > "${RESOLV_FILE}"
chmod 0644 "${RESOLV_FILE}"

echo "[6/6] Verifying DNS and listener scope..."
if ! dig example.com A +time=3 +tries=1 +short | grep -q .; then
  echo "Error: DNS verification failed; restoring resolv.conf." >&2
  rm -f "${RESOLV_FILE}"
  cp -a "${BACKUP_DIR}/resolv.conf" "${RESOLV_FILE}" 2>/dev/null || true
  exit 1
fi

if ss -H -lntup | awk '$0 ~ /dnsmasq/ && $5 !~ /^(127\.0\.0\.1|\[::1\]):53$/ { found=1 } END { exit !found }'; then
  echo "Warning: review the listeners below; dnsmasq may be exposed publicly." >&2
fi

echo
echo "dnsmasq installation completed."
echo "Upstream DNS: ${UPSTREAM}"
echo "Backup: ${BACKUP_DIR}"
echo "Service: $(systemctl is-active dnsmasq) / $(systemctl is-enabled dnsmasq)"
ss -lntup | grep dnsmasq || true
