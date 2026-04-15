# TLS Certificates — Setup

A wildcard Let's Encrypt certificate (`*.nasbox.nakomis.com`) obtained via DNS-01 challenge against Route53. The Pi authenticates to AWS using an IoT Thing certificate (provisioned by the `NasboxIotStack` CDK stack), exchanging it for short-lived STS credentials via the AWS IoT credential provider. No long-lived AWS credentials live on the Pi.

## How it works

```
Pi                              AWS IoT                     Route53
 |                                |                            |
 |-- POST /role-aliases/... ----> |                            |
 |   (client cert + key)         |                            |
 |<-- { AccessKeyId, ... } -------                            |
 |                                                            |
 |-- certbot renew (DNS-01) --------------------------------> |
 |   (using temp credentials)    creates _acme-challenge TXT  |
 |<-- certificate issued --------|--------------------------- |
```

1. The Pi holds its IoT certificate and private key (downloaded from SSM once during setup)
2. Before each renewal, a pre-hook script calls the IoT credential provider endpoint to obtain temporary STS credentials (valid 1 hour)
3. certbot uses those credentials to create/delete Route53 TXT records for the DNS-01 challenge
4. Let's Encrypt issues the certificate; certbot saves it to `/etc/letsencrypt/`
5. A post-hook restarts any services that use the certificate

## Prerequisites

Deploy the `NasboxIotStack` CDK stack first:

```bash
cd infra
npm install
AWS_PROFILE=nakom.is cdk deploy NasboxIotStack
```

## Initial setup

Run `certificates/scripts/setup-certbot.sh` **on your Mac** (not on the Pi). The script uses your SSO credentials to pull the IoT cert/key from SSM, then SSHes/SCPs everything to the Pi. The AWS CLI is not required on the Pi.

```bash
AWS_PROFILE=nakom.is bash certificates/scripts/setup-certbot.sh
```

The script:
1. Fetches the IoT certificate, private key, and credential provider endpoint from AWS (on your Mac, using SSO)
2. SCPs the certificate and key to `/etc/iot/` on the Pi
3. Installs `certbot`, `python3-certbot-dns-route53`, and `jq` on the Pi via SSH
4. Writes `/usr/local/bin/certbot-renew-nasbox.sh` onto the Pi — a wrapper that exchanges the IoT cert for temporary STS credentials (pure `curl`/`jq`, no AWS CLI) then runs certbot
5. Obtains the initial certificate
6. Installs a systemd timer (`certbot-renew-nasbox.timer`) for automatic twice-daily renewal attempts

## Certificate location

After setup, certificates live at:

```
/etc/letsencrypt/live/nasbox.nakomis.com/
  cert.pem        — server certificate
  chain.pem       — intermediate chain
  fullchain.pem   — cert + chain (use this for most services)
  privkey.pem     — private key
```

## Renewal

Renewal is automatic via a systemd timer (`certbot-renew.timer`). To check status:

```bash
systemctl status certbot-renew.timer
journalctl -u certbot-renew
```

To trigger renewal manually:

```bash
sudo certbot renew --force-renewal
```

## Granting a service user access to the certificates

The Let's Encrypt directories are root-only by default. Use `setfacl` to grant a specific service user read access without changing ownership. This needs to cover both `live/` (which contains the well-known paths) and `archive/` (where the actual files live — `live/` entries are symlinks into `archive/`).

```bash
sudo apt-get install -y acl
sudo setfacl -R -m u:<service-user>:rX /etc/letsencrypt/live /etc/letsencrypt/archive
```

Replace `<service-user>` with the user the service runs as (e.g. `nakotp`). The `-R` flag applies the ACL recursively; `rX` grants read permission and execute on directories only.

Re-run this command after adding a new service — the ACLs on `archive/` need to cover new versioned subdirectories created by certbot on each renewal.

## Adding services that use the certificate

Add a post-renewal hook in `/etc/letsencrypt/renewal-hooks/post/`:

```bash
sudo tee /etc/letsencrypt/renewal-hooks/post/reload-nginx.sh << 'EOF'
#!/bin/bash
systemctl reload nginx 2>/dev/null || true
EOF
sudo chmod +x /etc/letsencrypt/renewal-hooks/post/reload-nginx.sh
```

## IoT credentials store

The Pi's IoT certificate and key are stored at:

```
/etc/iot/cert.pem    — device certificate
/etc/iot/privkey.pem — device private key
```

These are credentials for the IoT Thing only (not AWS account credentials) and allow the Pi to obtain temporary STS credentials scoped to the `NasboxThingIamRole`. Permissions are limited to Route53 DNS challenge operations.
