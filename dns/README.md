# Internal DNS

dnsmasq running on the nasbox, providing DNS resolution for the `.internal` TLD across the `172.29.0.0/x` LAN.

All other queries are forwarded to upstream resolvers (Cloudflare 1.1.1.1 / Google 8.8.8.8).

## Files

| File | Purpose |
|------|---------|
| `dnsmasq.conf` | dnsmasq configuration — deployed to `/etc/dnsmasq.d/nasbox.conf` |
| `hosts.internal` | Static A records for `.internal` hostnames — deployed to `/etc/dnsmasq.d/hosts.internal` |
| `scripts/setup.sh` | Idempotent install & deploy script |

## Hosts

| Hostname | IP |
|---------|----|
| `nasbox.internal` | `172.29.0.5` |
| `homeassistant.internal` | `172.29.0.20` |

To add a new host, edit `hosts.internal` and re-run the setup script.

## Setup

Run from the **repo root** on your laptop:

```bash
bash dns/scripts/setup.sh
```

If `nasbox.local` doesn't resolve (e.g. you're at the office), override the target with the IP:

```bash
NASBOX=nakomis@172.29.0.5 bash dns/scripts/setup.sh
```

The script is safe to re-run at any time — every step is idempotent.

## What the script does

1. **Installs dnsmasq** via apt (skips if already installed).
2. **Disables the systemd-resolved stub listener** — on modern Debian/Ubuntu, `systemd-resolved` binds port 53 on `127.0.0.53`; dnsmasq needs that port, so the stub is turned off and `/etc/resolv.conf` is redirected to the real resolved socket.
3. **Deploys `dnsmasq.conf`** to `/etc/dnsmasq.d/nasbox.conf`.
4. **Deploys `hosts.internal`** to `/etc/dnsmasq.d/hosts.internal`.
5. **Enables and restarts dnsmasq**, running a config syntax check first.
6. **Smoke-tests** resolution of a few `.internal` names and one external name, directly against `127.0.0.1`.

## Using the DNS server

Point any client at `172.29.0.5` port 53.

**Laptop (temporary):**
```bash
sudo networksetup -setdnsservers Wi-Fi 172.29.0.5
```

**Laptop (revert):**
```bash
sudo networksetup -setdnsservers Wi-Fi empty
```

**Linux `/etc/resolv.conf`:**
```
nameserver 172.29.0.5
```

**Router (recommended):** Set `172.29.0.5` as the DNS server pushed to DHCP clients so every device on the LAN gets `.internal` resolution automatically.
