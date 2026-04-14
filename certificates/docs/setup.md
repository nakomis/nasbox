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

Note the outputs — you'll need the credential provider endpoint (fetched separately):

```bash
AWS_PROFILE=nakom.is aws iot describe-endpoint \
  --endpoint-type iot:CredentialProvider \
  --query endpointAddress --output text
```

## Initial setup on the Pi

Run `certificates/scripts/setup-certbot.sh` from the repo root:

```bash
scp certificates/scripts/setup-certbot.sh nakomis@nasbox.local:/home/nakomis/
ssh nakomis@nasbox.local "sudo bash /home/nakomis/setup-certbot.sh"
```

The script:
1. Installs certbot and certbot-dns-route53
2. Downloads the IoT certificate and private key from SSM Parameter Store
3. Fetches the IoT credential provider endpoint
4. Writes a certbot pre-hook that exchanges the IoT cert for temporary AWS credentials
5. Runs certbot to obtain the initial certificate
6. Installs a systemd timer for automatic renewal

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
