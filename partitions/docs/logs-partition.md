# Logs Partition

A 1GB logical volume (`logs`) carved from the existing `nasvg` volume group, mounted at `/mnt/logs`. Because it lives inside the existing LUKS container, it is automatically encrypted at rest — no additional setup is needed.

Log files are written by the `logserver` service (see `logserver/`) and organised into per-device subdirectories:

```
/mnt/logs/
  garage-sensor/
    2026-04-14_09-00-00.log
    2026-04-14_10-00-00.log
  workshop-env/
    2026-04-14_08-45-00.log
```

The directory is shared over Samba as `[logs]` for read access from laptops on the LAN.

## Create the partition

Use the script at `partitions/scripts/create-logs-partition.sh`, or run the steps manually:

```bash
# Create the logical volume
sudo lvcreate -L 1G -n logs nasvg

# Format and mount
sudo mkfs.ext4 -L logs /dev/nasvg/logs
sudo mkdir -p /mnt/logs
sudo mount /dev/nasvg/logs /mnt/logs
sudo chown -R nakomis:nakomis /mnt/logs
```

Add to `/etc/fstab` for automatic mounting at boot:

```
/dev/nasvg/logs  /mnt/logs  ext4  defaults,noatime,nofail  0  2
```

## Add the Samba share

Add to `/etc/samba/smb.conf`:

```ini
[logs]
   path = /mnt/logs
   valid users = nakomis
   read only = yes
   browseable = yes
```

> **Read-only** from the Samba side — writes come only via the logserver HTTP API. Set `read only = no` if you need to delete or reorganise files from your laptop.

Restart Samba:

```bash
sudo systemctl restart smbd nmbd
```

Verify from a Mac:

```bash
smbutil view //nakomis@nasbox.local
```

`logs` should appear in the list. Connect in Finder via **Go → Connect to Server → smb://nasbox.local/logs**.

## Update nas-recovery.sh

The existing `nas-recovery.sh` script tears down and rebuilds all LVM mounts after an SSD re-enumeration. It needs to know about the logs volume. Add the following lines to the teardown and recovery sections respectively:

**Teardown (after the `umount -l` line):**
```bash
dmsetup remove nasvg-logs 2>/dev/null || true
```

**Mount (after `vgchange -ay nasvg`):**
```bash
mount /mnt/logs
```

## Resizing

Growing (live, no unmount needed):

```bash
sudo lvresize -L +500M /dev/nasvg/logs
sudo resize2fs /dev/nasvg/logs
```

Check current usage first: `df -h /mnt/logs`

## Notes

- The ~30GB of unallocated space in `nasvg` is more than sufficient for a 1GB logs volume.
- If log volume grows significantly, resize as above rather than creating a second volume.
