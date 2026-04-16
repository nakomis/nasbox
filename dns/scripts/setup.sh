#!/bin/bash
# Sets up dnsmasq on the nasbox as an internal DNS server.
#
# Resolves *.internal hostnames to 172.29.x.y LAN addresses.
# All other queries are forwarded to upstream resolvers (1.1.1.1 / 8.8.8.8).
#
# Safe to re-run — every step is idempotent.
#
# Run from the repo root on your laptop:
#   bash dns/scripts/setup.sh
#
# If nasbox.local doesn't resolve (e.g. you're at the office), use the IP:
#   NASBOX=nakomis@172.29.0.5 bash dns/scripts/setup.sh

set -euo pipefail

log() { echo "[$(date '+%H:%M:%S')] $*"; }

NASBOX="${NASBOX:-nakomis@nasbox.local}"
DNSMASQ_CONF="dns/dnsmasq.conf"
HOSTS_FILE="dns/hosts.internal"
REMOTE_CONF="/etc/dnsmasq.d/nasbox.conf"
REMOTE_HOSTS="/etc/hosts.internal"

log "Target: ${NASBOX}"

# ── 1. Install dnsmasq ────────────────────────────────────────────────────────
log "Installing dnsmasq..."
ssh "${NASBOX}" "dpkg -s dnsmasq &>/dev/null && dpkg -s dnsutils &>/dev/null || sudo apt-get install -y dnsmasq dnsutils"

# ── 2. Disable systemd-resolved stub listener (if running) ───────────────────
# On modern Ubuntu/Debian, systemd-resolved binds port 53 on 127.0.0.53.
# We need to free port 53 so dnsmasq can take it.
# On some Debian installs systemd-resolved is not active — skip gracefully.
log "Checking systemd-resolved..."
ssh "${NASBOX}" bash << 'REMOTE'
set -euo pipefail

if ! systemctl is-active --quiet systemd-resolved; then
    echo "  systemd-resolved is not running — nothing to do."
    exit 0
fi

echo "  systemd-resolved is active; disabling stub listener..."

# Use a drop-in so we don't need the base file to exist.
DROPIN_DIR=/etc/systemd/resolved.conf.d
sudo mkdir -p "${DROPIN_DIR}"
sudo tee "${DROPIN_DIR}/no-stub.conf" > /dev/null << 'EOF'
[Resolve]
DNSStubListener=no
EOF

sudo systemctl restart systemd-resolved

# Point /etc/resolv.conf at the real resolved socket (not the stub)
if [ "$(readlink /etc/resolv.conf)" != "/run/systemd/resolve/resolv.conf" ]; then
    sudo ln -sf /run/systemd/resolve/resolv.conf /etc/resolv.conf
fi
REMOTE

# ── 3. Remove hosts file from dnsmasq.d if it ended up there previously ──────
# dnsmasq treats everything in /etc/dnsmasq.d/ as a config file; the hosts
# file must live outside that directory.
ssh "${NASBOX}" "sudo rm -f /etc/dnsmasq.d/hosts.internal"

# ── 4. Deploy dnsmasq config ──────────────────────────────────────────────────
log "Deploying dnsmasq config..."
scp "${DNSMASQ_CONF}" "${NASBOX}:/tmp/nasbox-dnsmasq.conf"
ssh "${NASBOX}" "sudo mv /tmp/nasbox-dnsmasq.conf ${REMOTE_CONF} && sudo chmod 644 ${REMOTE_CONF}"

# ── 5. Deploy hosts file ──────────────────────────────────────────────────────
log "Deploying hosts.internal..."
scp "${HOSTS_FILE}" "${NASBOX}:/tmp/hosts.internal"
ssh "${NASBOX}" "sudo mv /tmp/hosts.internal ${REMOTE_HOSTS} && sudo chmod 644 ${REMOTE_HOSTS}"

# ── 6. Enable and restart dnsmasq ─────────────────────────────────────────────
log "Enabling and restarting dnsmasq..."
ssh "${NASBOX}" bash << 'REMOTE'
set -euo pipefail
sudo dnsmasq --test 2>&1  # config syntax check
sudo systemctl enable dnsmasq
sudo systemctl restart dnsmasq
sudo systemctl status dnsmasq --no-pager
REMOTE

# ── 7. Smoke test ─────────────────────────────────────────────────────────────
log "Running smoke tests..."
ssh "${NASBOX}" bash << 'REMOTE'
set -euo pipefail
echo "  nasbox.internal        → $(dig +short @127.0.0.1 nasbox.internal)"
echo "  homeassistant.internal → $(dig +short @127.0.0.1 homeassistant.internal)"
echo "  example.com (upstream) → $(dig +short @127.0.0.1 example.com | head -1)"
REMOTE

log "Done."
log ""
log "Point clients at 172.29.0.5:53 to use this DNS server."
log "Or add to your /etc/resolv.conf:  nameserver 172.29.0.5"
