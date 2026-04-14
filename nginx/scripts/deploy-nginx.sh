#!/bin/bash
# Installs nginx on the nasbox and configures it as a reverse proxy.
# Run on your Mac: bash nginx/scripts/deploy-nginx.sh

set -euo pipefail

log() { echo "[$(date '+%H:%M:%S')] $*"; }

PI="nakomis@nasbox.local"
CONF="nginx/nasbox.nakomis.com.conf"
REMOTE_CONF="/etc/nginx/sites-available/nasbox.nakomis.com"

# ── 1. Install nginx ──────────────────────────────────────────────────────────
log "Installing nginx..."
ssh "${PI}" "sudo apt-get install -y nginx"

# ── 2. Deploy site config ─────────────────────────────────────────────────────
log "Copying nginx config..."
scp "${CONF}" "${PI}:/tmp/nasbox.nakomis.com.conf"
ssh "${PI}" "sudo mv /tmp/nasbox.nakomis.com.conf ${REMOTE_CONF}"

# Enable site, disable default
ssh "${PI}" "sudo ln -sf ${REMOTE_CONF} /etc/nginx/sites-enabled/nasbox.nakomis.com \
  && sudo rm -f /etc/nginx/sites-enabled/default"

# ── 3. Test config and reload ─────────────────────────────────────────────────
log "Testing nginx config..."
ssh "${PI}" "sudo nginx -t"

log "Enabling and starting nginx..."
ssh "${PI}" "sudo systemctl enable --now nginx"
ssh "${PI}" "sudo systemctl reload nginx"

# ── 4. Add cert renewal reload hook ──────────────────────────────────────────
log "Adding nginx reload hook for cert renewal..."
ssh "${PI}" "sudo tee /etc/letsencrypt/renewal-hooks/post/reload-nginx.sh > /dev/null" << 'EOF'
#!/bin/bash
systemctl reload nginx
EOF
ssh "${PI}" "sudo chmod +x /etc/letsencrypt/renewal-hooks/post/reload-nginx.sh"

log "Done. nginx is serving https://nasbox.nakomis.com"
