#!/bin/bash
# Creates the 1GB logs logical volume, formats it, mounts it,
# adds it to fstab, and adds the Samba share.
#
# Run on the Pi as: sudo bash create-logs-partition.sh
# Idempotent — safe to re-run if a step was previously interrupted.

set -euo pipefail

log() { echo "[$(date '+%H:%M:%S')] $*"; }

# ── 1. Create LV ──────────────────────────────────────────────────────────────
if lvs /dev/nasvg/logs &>/dev/null; then
    log "LV nasvg/logs already exists, skipping lvcreate"
else
    log "Creating 1GB logical volume nasvg/logs"
    lvcreate -L 1G -n logs nasvg
fi

# ── 2. Format ─────────────────────────────────────────────────────────────────
if blkid /dev/nasvg/logs | grep -q ext4; then
    log "ext4 filesystem already present on nasvg/logs, skipping mkfs"
else
    log "Formatting as ext4"
    mkfs.ext4 -L logs /dev/nasvg/logs
fi

# ── 3. Mount point ────────────────────────────────────────────────────────────
mkdir -p /mnt/logs

if mountpoint -q /mnt/logs; then
    log "/mnt/logs already mounted"
else
    log "Mounting /mnt/logs"
    mount /dev/nasvg/logs /mnt/logs
fi

chown -R nakomis:nakomis /mnt/logs

# ── 4. fstab ──────────────────────────────────────────────────────────────────
FSTAB_ENTRY="/dev/nasvg/logs  /mnt/logs  ext4  defaults,noatime,nofail  0  2"
if grep -qF '/mnt/logs' /etc/fstab; then
    log "fstab entry already present"
else
    log "Adding fstab entry"
    echo "$FSTAB_ENTRY" >> /etc/fstab
fi

# ── 5. Samba share ────────────────────────────────────────────────────────────
if grep -q '^\[logs\]' /etc/samba/smb.conf; then
    log "Samba [logs] share already configured"
else
    log "Adding Samba [logs] share"
    cat >> /etc/samba/smb.conf << 'EOF'

[logs]
   path = /mnt/logs
   valid users = nakomis
   read only = yes
   browseable = yes
EOF
    systemctl restart smbd nmbd
    log "Samba restarted"
fi

log "Done. Verify with: smbutil view //nakomis@nasbox.local"
