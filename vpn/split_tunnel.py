#!/usr/bin/env python3
"""
Convert an OpenVPN .ovpn config to split-tunnel mode, with optional DNS routing.

By default, home routers push a redirect-gateway directive that routes ALL
traffic through the VPN. This script:
  - Removes any client-side redirect-gateway directive
  - Adds pull-filter to ignore redirect-gateway pushed by the server
  - Adds route-nopull to prevent the server pushing other unwanted routes
  - Adds an explicit route for the specified subnet only

DNS routing
-----------
Two modes are available via --dns-mode:

  split (default)
    Only .internal queries go to the home DNS server.
    Adds dhcp-option DNS + dhcp-option DOMAIN internal to the .ovpn.
    Tunnelblick and OpenVPN Connect recognise these and automatically set up
    per-domain routing with no extra steps.  For other clients (raw openvpn
    CLI etc.) companion scripts (<output>.dns-up.sh / dns-down.sh) are also
    generated; run dns-up.sh once after connecting.

  all
    All DNS queries are routed through the home DNS server.
    Adds  dhcp-option DNS <server>  to the .ovpn config.  Simpler and works
    on any OS; the DNS server forwards non-.internal queries upstream anyway.

  none
    No DNS configuration is added.

The subnet to route via VPN is resolved in this order (highest priority first):
  1. Command-line argument (--subnet)
  2. LAN_SUBNET environment variable
  3. Hard-coded default (DEFAULT_LAN_SUBNET)

Usage:
    python3 split_tunnel.py <input.ovpn> [output.ovpn] [--subnet <cidr>]
                            [--dns-mode {split,all,none}] [--dns-server <ip>]

Examples:
    python3 split_tunnel.py OpenVPN_Config.ovpn
    python3 split_tunnel.py OpenVPN_Config.ovpn --subnet 172.29.0.0/16
    python3 split_tunnel.py OpenVPN_Config.ovpn home-split.ovpn --subnet 172.29.0.0/16
    python3 split_tunnel.py OpenVPN_Config.ovpn --dns-mode all
    python3 split_tunnel.py OpenVPN_Config.ovpn --dns-mode none
    LAN_SUBNET=172.29.0.0/16 python3 split_tunnel.py OpenVPN_Config.ovpn home-split.ovpn
"""

import argparse
import ipaddress
import os
import re
import sys
from pathlib import Path

DEFAULT_LAN_SUBNET = "172.29.0.0/16"
DEFAULT_DNS_SERVER = "172.29.0.5"
DEFAULT_DNS_DOMAIN = "internal"

DIRECTIVES_TO_REMOVE = {
    "redirect-gateway",
    "redirect-private",
}

SPLIT_TUNNEL_COMMENT = "# Split-tunnel configuration (added by split_tunnel.py)"


def cidr_to_ovpn_route(network: ipaddress.IPv4Network) -> str:
    """Return an OpenVPN route directive for the given network."""
    return f"route {network.network_address} {network.netmask}"


def parse_directive_name(line: str) -> str | None:
    """Return the directive keyword from a config line, or None for blank/comment lines."""
    stripped = line.strip()
    if not stripped or stripped.startswith("#") or stripped.startswith(";"):
        return None
    return stripped.split()[0].lower()


def write_macos_resolver_scripts(output_path: Path, dns_server: str, domain: str) -> None:
    """Generate dns-up.sh and dns-down.sh companion scripts for macOS split-DNS."""
    resolver_dir = "/etc/resolver"
    resolver_file = f"{resolver_dir}/{domain}"

    up_path = output_path.with_stem(output_path.stem + ".dns-up").with_suffix(".sh")
    down_path = output_path.with_stem(output_path.stem + ".dns-down").with_suffix(".sh")

    up_script = f"""\
#!/bin/bash
# Enables split-DNS for .{domain} queries — route them to the home DNS server.
# Run this after connecting to the VPN.
#
# macOS uses /etc/resolver/<domain> files to direct per-domain DNS queries
# to a specific nameserver.  Only .{domain} lookups go to {dns_server};
# everything else continues using your normal DNS.
#
# Requires sudo.

set -euo pipefail

sudo mkdir -p {resolver_dir}
sudo tee {resolver_file} > /dev/null << 'EOF'
nameserver {dns_server}
EOF

echo ".{domain} DNS → {dns_server}  (split-DNS active)"
"""

    down_script = f"""\
#!/bin/bash
# Disables split-DNS for .{domain} queries.
# Run this before disconnecting from the VPN (or it will clean up harmlessly anyway).
#
# Requires sudo.

set -euo pipefail

if [ -f {resolver_file} ]; then
    sudo rm {resolver_file}
    echo ".{domain} DNS resolver removed."
else
    echo ".{domain} DNS resolver was not present — nothing to do."
fi
"""

    up_path.write_text(up_script)
    up_path.chmod(0o755)
    down_path.write_text(down_script)
    down_path.chmod(0o755)

    print(f"  Split-DNS scripts:     {up_path.name} / {down_path.name}")
    print(f"  Run after connecting:  sudo bash {up_path.name}")
    print(f"  Run to clean up:       sudo bash {down_path.name}")


def convert(
    input_path: Path,
    subnet: str,
    output_path: Path,
    dns_mode: str,
    dns_server: str,
) -> None:
    try:
        network = ipaddress.IPv4Network(subnet, strict=False)
    except ValueError as exc:
        sys.exit(f"Invalid subnet '{subnet}': {exc}")

    content = input_path.read_text()

    output_plain: list[str] = []
    output_blocks: list[str] = []
    current_block: list[str] = []
    in_block = False

    lines = content.splitlines(keepends=True)

    for line in lines:
        stripped = line.strip()

        if in_block:
            current_block.append(line)
            if re.match(r"^</\w+>", stripped):
                in_block = False
                output_blocks.append("".join(current_block))
                current_block = []
            continue

        if re.match(r"^<\w+>", stripped):
            in_block = True
            current_block = [line]
            continue

        directive = parse_directive_name(line)
        if directive in DIRECTIVES_TO_REMOVE:
            output_plain.append(f"# [split_tunnel.py] removed: {line.rstrip()}\n")
            continue

        output_plain.append(line)

    if output_plain and not output_plain[-1].endswith("\n"):
        output_plain[-1] += "\n"

    existing_directives = {
        parse_directive_name(l)
        for l in output_plain
        if parse_directive_name(l) is not None
    }

    additions: list[str] = ["\n", SPLIT_TUNNEL_COMMENT + "\n"]

    if "route-nopull" not in existing_directives:
        additions.append("route-nopull\n")

    additions.append('pull-filter ignore "redirect-gateway"\n')
    additions.append(cidr_to_ovpn_route(network) + "\n")

    if dns_mode in ("split", "all"):
        additions.append(f"\n# DNS — home DNS server ({dns_server})\n")
        additions.append(f"dhcp-option DNS {dns_server}\n")
    if dns_mode == "split":
        # DOMAIN tells clients like Tunnelblick/OpenVPN Connect to restrict this
        # DNS server to .internal queries only (sets up /etc/resolver/internal).
        # The companion dns-up/down scripts achieve the same for other clients.
        additions.append(f"dhcp-option DOMAIN {DEFAULT_DNS_DOMAIN}\n")

    final_lines = output_plain + additions + ["\n"] + output_blocks
    output_path.write_text("".join(final_lines))

    print(f"Written to: {output_path}")
    print(f"  Subnet routed via VPN: {network}")
    print(f"  All other traffic:     local gateway (not tunnelled)")

    if dns_mode == "split":
        print(f"  DNS:                   .{DEFAULT_DNS_DOMAIN} only → {dns_server}")
        print(f"                         (Tunnelblick/OpenVPN Connect: automatic via dhcp-option DOMAIN)")
        write_macos_resolver_scripts(output_path, dns_server, DEFAULT_DNS_DOMAIN)
    elif dns_mode == "all":
        print(f"  DNS:                   all queries → {dns_server} (via VPN)")
    else:
        print(f"  DNS:                   unchanged (no DNS routing configured)")


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Convert an .ovpn config to split-tunnel mode for a single subnet."
    )
    parser.add_argument("input", type=Path, help="Input .ovpn file")
    parser.add_argument(
        "--subnet", "-s",
        help=(
            "Subnet to route via VPN, in CIDR notation (e.g. 172.29.0.0/16). "
            "Overrides LAN_SUBNET env var and the hard-coded default."
        ),
    )
    parser.add_argument(
        "output",
        type=Path,
        nargs="?",
        help="Output .ovpn file (default: <input>-split-tunnel.ovpn)",
    )
    parser.add_argument(
        "--dns-mode",
        choices=["split", "all", "none"],
        default="split",
        help=(
            "How to configure DNS. "
            "'split' (default): generate macOS /etc/resolver/internal scripts for .internal-only routing. "
            "'all': add dhcp-option DNS to the .ovpn to route all DNS via the home server. "
            "'none': no DNS configuration."
        ),
    )
    parser.add_argument(
        "--dns-server",
        default=DEFAULT_DNS_SERVER,
        metavar="IP",
        help=f"IP of the home DNS server (default: {DEFAULT_DNS_SERVER})",
    )
    args = parser.parse_args()

    subnet = args.subnet or os.environ.get("LAN_SUBNET") or DEFAULT_LAN_SUBNET
    if not args.subnet:
        source = "LAN_SUBNET env var" if os.environ.get("LAN_SUBNET") else "default"
        print(f"Using subnet from {source}: {subnet}")

    if not args.input.exists():
        sys.exit(f"Input file not found: {args.input}")

    if args.input.suffix.lower() != ".ovpn":
        print(f"Warning: '{args.input}' does not have an .ovpn extension.")

    output_path = args.output or args.input.with_stem(args.input.stem + "-split-tunnel")

    if output_path == args.input:
        sys.exit("Output path must differ from input path.")

    convert(args.input, subnet, output_path, args.dns_mode, args.dns_server)


if __name__ == "__main__":
    main()
