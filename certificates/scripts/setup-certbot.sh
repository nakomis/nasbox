#!/bin/bash
# Sets up Let's Encrypt wildcard certificate for *.nasbox.nakomis.com.
#
# Run on your Mac (not the Pi). Requires:
#   - AWS CLI with AWS_PROFILE=nakom.is (SSO)
#   - ssh access to nasbox.local
#   - NasboxIotStack already deployed
#
# Usage: AWS_PROFILE=nakom.is bash certificates/scripts/setup-certbot.sh

set -euo pipefail

log() { echo "[$(date '+%H:%M:%S')] $*"; }
die() { echo "ERROR: $*" >&2; exit 1; }

# ── Preflight checks ──────────────────────────────────────────────────────────
[ -n "${AWS_PROFILE:-}" ] || die "AWS_PROFILE is not set. Run: export AWS_PROFILE=nakom.is"

aws sts get-caller-identity --query Account --output text > /dev/null 2>&1 \
  || die "AWS credentials are not valid. Run: aws sso login --profile ${AWS_PROFILE}"

aws ssm get-parameter --name "/nasbox/certPem" --query Name --output text > /dev/null 2>&1 \
  || die "SSM parameter /nasbox/certPem not found. Deploy the CDK stack first: cd infra && npm install && cdk deploy NasboxIotStack"

ssh -q -o BatchMode=yes -o ConnectTimeout=5 "${PI:-nakomis@nasbox.local}" exit 2>/dev/null \
  || die "Cannot SSH to nasbox.local. Is the Pi on the network?"

log "Preflight checks passed."

PI="nakomis@nasbox.local"
DOMAIN="nasbox.nakomis.com"
WILDCARD_DOMAIN="*.nasbox.nakomis.com"
EMAIL="martin@nakom.is"
ROLE_ALIAS="NasboxRoleAlias"
IOT_DIR="/etc/iot"
RENEW_SCRIPT="/usr/local/bin/certbot-renew-nasbox.sh"

# ── 1. Fetch IoT credentials from SSM (runs on Mac with SSO) ─────────────────
log "Fetching IoT certificate from SSM..."
CERT_PEM=$(aws ssm get-parameter \
  --name "/nasbox/certPem" \
  --with-decryption \
  --query "Parameter.Value" \
  --output text)

PRIV_KEY=$(aws ssm get-parameter \
  --name "/nasbox/privKey" \
  --with-decryption \
  --query "Parameter.Value" \
  --output text)

log "Fetching IoT credential provider endpoint..."
IOT_ENDPOINT=$(aws iot describe-endpoint \
  --endpoint-type iot:CredentialProvider \
  --query endpointAddress \
  --output text)
log "IoT endpoint: ${IOT_ENDPOINT}"

# ── 2. Copy IoT credentials to the Pi ────────────────────────────────────────
log "Copying IoT credentials to Pi..."
ssh "${PI}" "sudo mkdir -p ${IOT_DIR} && sudo chmod 700 ${IOT_DIR}"

echo "${CERT_PEM}" | ssh "${PI}" "sudo tee ${IOT_DIR}/cert.pem > /dev/null"
echo "${PRIV_KEY}" | ssh "${PI}" "sudo tee ${IOT_DIR}/privkey.pem > /dev/null"
ssh "${PI}" "sudo chmod 600 ${IOT_DIR}/cert.pem ${IOT_DIR}/privkey.pem"

# Download AWS root CA onto the Pi (just HTTPS, no AWS CLI needed)
ssh "${PI}" "sudo curl -sS https://www.amazontrust.com/repository/AmazonRootCA1.pem \
  -o ${IOT_DIR}/root-ca.pem"

log "IoT credentials in place on Pi"

# ── 3. Install certbot on the Pi ──────────────────────────────────────────────
log "Installing certbot on Pi..."
ssh "${PI}" "sudo apt-get install -y certbot python3-certbot-dns-route53 jq"

# ── 4. Write the renewal wrapper script onto the Pi ──────────────────────────
# This script:
#   a) calls the IoT credential provider (pure HTTP — no AWS CLI)
#   b) writes temporary AWS credentials to /root/.aws/credentials
#   c) runs certbot renew
#   d) cleans up the temporary credentials
#
# certbot-dns-route53 uses boto3, which reads the standard credential chain —
# so we just write the temp creds where boto3 will find them.
log "Writing renewal script to Pi..."

ssh "${PI}" "sudo tee ${RENEW_SCRIPT} > /dev/null" << EOF
#!/bin/bash
set -euo pipefail

IOT_DIR="${IOT_DIR}"
IOT_ENDPOINT="${IOT_ENDPOINT}"
ROLE_ALIAS="${ROLE_ALIAS}"
CREDS_FILE="\$(mktemp)"
AWS_CREDS_DIR="/root/.aws"

cleanup() { rm -f "\${CREDS_FILE}"; rm -f "\${AWS_CREDS_DIR}/credentials"; }
trap cleanup EXIT

# Exchange IoT certificate for temporary STS credentials (pure HTTP, no AWS CLI)
curl --silent --fail \\
  --cert "\${IOT_DIR}/cert.pem" \\
  --key "\${IOT_DIR}/privkey.pem" \\
  --cacert "\${IOT_DIR}/root-ca.pem" \\
  "https://\${IOT_ENDPOINT}/role-aliases/\${ROLE_ALIAS}/credentials" \\
  -o "\${CREDS_FILE}"

ACCESS_KEY=\$(jq -r '.credentials.accessKeyId'     "\${CREDS_FILE}")
SECRET_KEY=\$(jq -r '.credentials.secretAccessKey' "\${CREDS_FILE}")
SESSION_TOK=\$(jq -r '.credentials.sessionToken'   "\${CREDS_FILE}")

# Write credentials where boto3/certbot-dns-route53 will find them
mkdir -p "\${AWS_CREDS_DIR}"
chmod 700 "\${AWS_CREDS_DIR}"
cat > "\${AWS_CREDS_DIR}/credentials" << CREDS
[default]
aws_access_key_id = \${ACCESS_KEY}
aws_secret_access_key = \${SECRET_KEY}
aws_session_token = \${SESSION_TOK}
CREDS
chmod 600 "\${AWS_CREDS_DIR}/credentials"

certbot renew --dns-route53 --dns-route53-propagation-seconds 30 --quiet

# trap EXIT cleans up credentials
EOF

ssh "${PI}" "sudo chmod +x ${RENEW_SCRIPT}"

# ── 5. Obtain the initial certificate ─────────────────────────────────────────
# The Mac calls the IoT credential provider using the cert we just downloaded
# from SSM. This gives us temporary STS credentials without needing the AWS CLI
# on the Pi. We pass them as environment variables over SSH so certbot on the Pi
# can complete the Route53 DNS-01 challenge.
log "Exchanging IoT certificate for temporary AWS credentials (on Mac)..."

CREDS_JSON=$(mktemp)
curl --silent --fail \
  --cert <(echo "${CERT_PEM}") \
  --key <(echo "${PRIV_KEY}") \
  --cacert <(curl -sS https://www.amazontrust.com/repository/AmazonRootCA1.pem) \
  "https://${IOT_ENDPOINT}/role-aliases/${ROLE_ALIAS}/credentials" \
  -o "${CREDS_JSON}"

ACCESS_KEY=$(jq -r '.credentials.accessKeyId'     "${CREDS_JSON}")
SECRET_KEY=$(jq -r '.credentials.secretAccessKey' "${CREDS_JSON}")
SESSION_TOK=$(jq -r '.credentials.sessionToken'   "${CREDS_JSON}")
rm -f "${CREDS_JSON}"

log "Obtaining initial certificate (this may take ~30s for DNS propagation)..."
ssh "${PI}" \
  "AWS_ACCESS_KEY_ID=${ACCESS_KEY} \
   AWS_SECRET_ACCESS_KEY=${SECRET_KEY} \
   AWS_SESSION_TOKEN=${SESSION_TOK} \
   sudo -E certbot certonly \
     --dns-route53 \
     --dns-route53-propagation-seconds 30 \
     --non-interactive \
     --agree-tos \
     --email ${EMAIL} \
     -d ${DOMAIN} \
     -d ${WILDCARD_DOMAIN}"

# ── 6. Set up systemd timer for automatic renewal ─────────────────────────────
log "Setting up renewal timer..."
ssh "${PI}" "sudo tee /etc/systemd/system/certbot-renew-nasbox.service > /dev/null" << 'EOF'
[Unit]
Description=Let's Encrypt certificate renewal (nasbox)
After=network.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/certbot-renew-nasbox.sh
EOF

ssh "${PI}" "sudo tee /etc/systemd/system/certbot-renew-nasbox.timer > /dev/null" << 'EOF'
[Unit]
Description=Renew Let's Encrypt certificate twice daily

[Timer]
OnCalendar=*-*-* 03:00:00
OnCalendar=*-*-* 15:00:00
RandomizedDelaySec=1h
Persistent=true

[Install]
WantedBy=timers.target
EOF

ssh "${PI}" "sudo systemctl daemon-reload && sudo systemctl enable --now certbot-renew-nasbox.timer"

log ""
log "Done."
log "Certificate: /etc/letsencrypt/live/${DOMAIN}/"
log "Renewal:     sudo systemctl status certbot-renew-nasbox.timer"
log "Test renew:  sudo ${RENEW_SCRIPT}"
