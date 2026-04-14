#!/bin/bash
log() { logger -t nas-recovery "$*"; }

log "Triggered — waiting for LUKS device to settle"

# Hub may connect/disconnect a few times before settling; wait up to 30s
DEVICE=""
for i in $(seq 1 10); do
    DEVICE=$(blkid -t TYPE=crypto_LUKS 2>/dev/null | grep '48ec4684-1839-442b-b6e4-199b45dfe7d8' | cut -d: -f1)
    [ -n "$DEVICE" ] && break
    sleep 3
done

if [ -z "$DEVICE" ]; then
    log "LUKS device not found after 30s, aborting"
    exit 1
fi

log "Found LUKS device at $DEVICE"

# If mounts are already healthy, nothing to do
if mountpoint -q /mnt/timemachine/phi 2>/dev/null && ls /mnt/timemachine/phi &>/dev/null; then
    log "Mounts already healthy, nothing to do"
    exit 0
fi

log "Rebuilding LUKS/LVM stack"

# Samba must stop first so dmsetup remove succeeds
systemctl stop smbd nmbd 2>/dev/null || true

# Tear down stale device mapper entries
umount -l /mnt/timemachine/phi /mnt/timemachine/cs 2>/dev/null || true
dmsetup remove nasvg-phi 2>/dev/null || true
dmsetup remove nasvg-cs 2>/dev/null || true
dmsetup remove nasvault 2>/dev/null || true

# Re-open LUKS
if ! cryptsetup luksOpen "$DEVICE" nasvault --key-file /etc/luks-keys/sda.key; then
    log "ERROR: cryptsetup luksOpen failed"
    exit 1
fi

# Activate LVM and mount
vgchange -ay nasvg
mount /mnt/timemachine/phi
mount /mnt/timemachine/cs

# Restart Samba
systemctl start smbd nmbd

log "Recovery complete"
