#!/bin/bash
# Sets up certbot with Let's Encrypt wildcard certificate for *.nasbox.nakomis.com
# using AWS IoT credential provider for Route53 DNS-01 challenge.
#
# Prerequisites:
#   - NasboxIotStack deployed (CDK)
#   - AWS SSM parameters /nasbox/certPem and /nasbox/privKey populated by CDK
#
# Run on the Pi as: sudo bash setup-certbot.sh
# Requires AWS credentials with SSM read access to be available at runtime
# (pass AWS_PROFILE or set AWS_* env vars before calling with sudo).

set -euo pipefail

log() { echo "[$(date '+%H:%M:%S')] $*"; }

DOMAIN="nasbox.nakomis.com"
WILDCARD_DOMAIN="*.nasbox.nakomis.com"
EMAIL="martin@nakom.is"
IOT_DIR="/etc/iot"
ROLE_ALIAS="NasboxRoleAlias"

# ── 1. Install certbot ────────────────────────────────────────────────────────
log "Installing certbot and certbot-dns-route53..."
apt-get install -y certbot python3-certbot-dns-route53

# ── 2. Download IoT certificate and key from SSM ──────────────────────────────
log "Creating ${IOT_DIR}..."
mkdir -p "${IOT_DIR}"
chmod 700 "${IOT_DIR}"

log "Downloading IoT certificate from SSM..."
aws ssm get-parameter \
  --name "/nasbox/certPem" \
  --with-decryption \
  --query "Parameter.Value" \
  --output text > "${IOT_DIR}/cert.pem"

aws ssm get-parameter \
  --name "/nasbox/privKey" \
  --with-decryption \
  --query "Parameter.Value" \
  --output text > "${IOT_DIR}/privkey.pem"

chmod 600 "${IOT_DIR}/cert.pem" "${IOT_DIR}/privkey.pem"

# Download AWS root CA (needed for IoT credential provider mTLS)
curl -sS https://www.amazontrust.com/repository/AmazonRootCA1.pem \
  -o "${IOT_DIR}/root-ca.pem"

log "IoT credentials saved to ${IOT_DIR}"

# ── 3. Fetch IoT credential provider endpoint ─────────────────────────────────
log "Fetching IoT credential provider endpoint..."
IOT_ENDPOINT=$(aws iot describe-endpoint \
  --endpoint-type iot:CredentialProvider \
  --query endpointAddress \
  --output text)
log "Endpoint: ${IOT_ENDPOINT}"

# ── 4. Write certbot pre-hook to obtain temporary AWS credentials ─────────────
log "Writing certbot pre-hook..."
mkdir -p /etc/letsencrypt/renewal-hooks/pre

tee /etc/letsencrypt/renewal-hooks/pre/iot-credentials.sh > /dev/null << EOF
#!/bin/bash
# Exchanges the IoT device certificate for temporary AWS STS credentials.
# These are written to /tmp/aws-iot-creds and sourced by certbot via an
# AWS_CONFIG_FILE that points to a credential_process entry.
set -euo pipefail

CREDS_FILE="/tmp/aws-iot-creds.json"

curl --silent --fail \\
  --cert "${IOT_DIR}/cert.pem" \\
  --key "${IOT_DIR}/privkey.pem" \\
  --cacert "${IOT_DIR}/root-ca.pem" \\
  "https://${IOT_ENDPOINT}/role-aliases/${ROLE_ALIAS}/credentials" \\
  -o "\${CREDS_FILE}"

# Parse and export as environment variables for certbot-dns-route53
ACCESS_KEY=\$(jq -r '.credentials.accessKeyId'     "\${CREDS_FILE}")
SECRET_KEY=\$(jq -r '.credentials.secretAccessKey' "\${CREDS_FILE}")
SESSION_TOK=\$(jq -r '.credentials.sessionToken'   "\${CREDS_FILE}")

# Write an AWS credentials file certbot will pick up via AWS_SHARED_CREDENTIALS_FILE
mkdir -p /tmp/certbot-aws
cat > /tmp/certbot-aws/credentials << CREDS
[default]
aws_access_key_id = \${ACCESS_KEY}
aws_secret_access_key = \${SECRET_KEY}
aws_session_token = \${SESSION_TOK}
CREDS
chmod 600 /tmp/certbot-aws/credentials

rm -f "\${CREDS_FILE}"
EOF
chmod +x /etc/letsencrypt/renewal-hooks/pre/iot-credentials.sh

# ── 5. Write certbot post-hook to clean up temp credentials ───────────────────
log "Writing certbot post-hook..."
mkdir -p /etc/letsencrypt/renewal-hooks/post

tee /etc/letsencrypt/renewal-hooks/post/cleanup-iot-creds.sh > /dev/null << 'EOF'
#!/bin/bash
rm -rf /tmp/certbot-aws
EOF
chmod +x /etc/letsencrypt/renewal-hooks/post/cleanup-iot-creds.sh

# ── 6. Write a wrapper script that sets AWS_SHARED_CREDENTIALS_FILE ───────────
# certbot-dns-route53 reads from the standard AWS credential chain,
# so we point it at our temp file via the environment.
log "Writing certbot renewal config..."

RENEWAL_CONF="/etc/letsencrypt/renewal/${DOMAIN}.conf"

# ── 7. Obtain the initial certificate ─────────────────────────────────────────
log "Running certbot to obtain initial certificate..."

# Run pre-hook manually so credentials are available for the initial run
/etc/letsencrypt/renewal-hooks/pre/iot-credentials.sh

AWS_SHARED_CREDENTIALS_FILE=/tmp/certbot-aws/credentials \
certbot certonly \
  --dns-route53 \
  --dns-route53-propagation-seconds 30 \
  --non-interactive \
  --agree-tos \
  --email "${EMAIL}" \
  -d "${DOMAIN}" \
  -d "${WILDCARD_DOMAIN}"

/etc/letsencrypt/renewal-hooks/post/cleanup-iot-creds.sh

# ── 8. Patch renewal config to set credentials env var ────────────────────────
# Ensure subsequent renewals also pick up the temp credentials file.
if [ -f "${RENEWAL_CONF}" ]; then
  if ! grep -q 'AWS_SHARED_CREDENTIALS_FILE' "${RENEWAL_CONF}"; then
    sed -i '/^\[renewalparams\]/a environ_AWS_SHARED_CREDENTIALS_FILE = /tmp/certbot-aws/credentials' \
      "${RENEWAL_CONF}"
  fi
fi

# ── 9. Set up systemd timer for automatic renewal ─────────────────────────────
log "Enabling certbot renewal timer..."
systemctl enable --now certbot.timer

log ""
log "Done. Certificate issued for ${WILDCARD_DOMAIN}"
log "Files: /etc/letsencrypt/live/${DOMAIN}/"
log "Renewal: systemctl status certbot.timer"
