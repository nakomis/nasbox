#!/bin/bash
# Installs nginx on the nasbox and configures it as a reverse proxy.
# Run on your Mac: bash nginx/scripts/deploy-nginx.sh

set -euo pipefail

log() { echo "[$(date '+%H:%M:%S')] $*"; }

PI="nakomis@nasbox.local"
CONF="nginx/nasbox.nakomis.com.conf"
STREAM_CONF="nginx/nasbox-stream.conf"
REMOTE_CONF="/etc/nginx/sites-available/nasbox.nakomis.com"
REMOTE_STREAM_CONF="/etc/nginx/stream.d/nasbox-stream.conf"

# ── 1. Install nginx + stream module ─────────────────────────────────────────
log "Installing nginx..."
ssh "${PI}" "sudo apt-get install -y nginx libnginx-mod-stream"

# ── 2. Deploy site config ─────────────────────────────────────────────────────
log "Copying nginx config..."
scp "${CONF}" "${PI}:/tmp/nasbox.nakomis.com.conf"
ssh "${PI}" "sudo mv /tmp/nasbox.nakomis.com.conf ${REMOTE_CONF}"

# Enable site, disable default
ssh "${PI}" "sudo ln -sf ${REMOTE_CONF} /etc/nginx/sites-enabled/nasbox.nakomis.com \
  && sudo rm -f /etc/nginx/sites-enabled/default"

# ── 3. Deploy stream config ───────────────────────────────────────────────────
log "Copying stream config..."
scp "${STREAM_CONF}" "${PI}:/tmp/nasbox-stream.conf"
ssh "${PI}" "sudo mkdir -p /etc/nginx/stream.d && sudo mv /tmp/nasbox-stream.conf ${REMOTE_STREAM_CONF}"

# Patch nginx.conf to include stream configs (idempotent)
ssh "${PI}" "grep -q 'stream.d' /etc/nginx/nginx.conf || echo 'stream { include /etc/nginx/stream.d/*.conf; }' | sudo tee -a /etc/nginx/nginx.conf > /dev/null"

# ── 4. Test config and reload ─────────────────────────────────────────────────
log "Testing nginx config..."
ssh "${PI}" "sudo nginx -t"

log "Enabling and starting nginx..."
ssh "${PI}" "sudo systemctl enable --now nginx"
ssh "${PI}" "sudo systemctl reload nginx"

# ── 5. Add cert renewal reload hook ──────────────────────────────────────────
log "Adding nginx reload hook for cert renewal..."
ssh "${PI}" "sudo tee /etc/letsencrypt/renewal-hooks/post/reload-nginx.sh > /dev/null" << 'EOF'
#!/bin/bash
systemctl reload nginx
EOF
ssh "${PI}" "sudo chmod +x /etc/letsencrypt/renewal-hooks/post/reload-nginx.sh"

log "Done. nginx is serving https://nasbox.nakomis.com"
