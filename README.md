# nasbox

A Raspberry Pi 5 NAS serving as a wireless Time Machine backup destination for multiple machines on the LAN.

## Hardware

- Raspberry Pi 5 (2GB)
- Raspberry Pi 27W USB-C Power Supply
- 64GB microSD card (boot drive)
- 1TB USB SSD (in enclosure) — backup storage
- Powered USB hub — the SSD must draw from the hub's PSU, not the Pi's USB port (insufficient current under sustained write load)
- 3D printed enclosure

## Architecture

```
Physical SSD (LUKS UUID=48ec4684-1839-442b-b6e4-199b45dfe7d8, enumerates as /dev/sda or /dev/sdb)
  └── LUKS encryption (keyfile on SD card at /etc/luks-keys/sda.key)
       └── LVM Physical Volume
            └── Volume Group: nasvg
                 ├── Logical Volume: phi  (650GB) — this Mac
                 └── Logical Volume: cs   (180GB) — other machine
                      (~30GB held in reserve, unallocated)
```

Each logical volume is formatted ext4, mounted under `/mnt/timemachine/`, and served as a separate Samba share with Time Machine support.

### What software runs each layer

| Layer | Userspace tool | Kernel component |
|---|---|---|
| LUKS | `cryptsetup` | `dm-crypt` module |
| LVM | `lvm2` (`pvcreate`, `vgcreate`, `lvresize` etc.) | `dm` (device mapper) module |
| ext4 | `e2fsprogs` (`mkfs.ext4`, `e2fsck`, `resize2fs`) | `ext4` module |
| Samba | `samba` (`smbd`, `nmbd`) | — (userspace only) |

Both LUKS and LVM use the kernel's **device mapper** as their underlying mechanism — which is why `/dev/mapper/nasvault`, `/dev/mapper/nasvg-phi` etc. appear, and why `dmsetup` surfaces when things go wrong. It's the low-level kernel interface that both `dm-crypt` and LVM sit on top of.

### How the layers relate

The stack runs bottom to top — each layer is independent and unaware of what sits above it:

- **Physical SSD** — raw hardware
- **LUKS** — encrypts the raw device; sits directly on the physical SSD
- **LVM Physical Volume** — the decrypted LUKS volume, registered with LVM
- **LVM Volume Group (`nasvg`)** — a single pool of storage spanning all PVs
- **LVM Logical Volume (`phi`, `cs`)** — carved out of the VG pool
- **ext4** — filesystem inside each LV; sees one contiguous volume, unaware of the drives beneath
- **Samba** — serves each ext4 filesystem as a network share; unaware of everything below

The Volume Group abstracts away physical placement — you carve Logical Volumes out of the pool and LVM allocates the physical extents (4MB chunks) wherever it has space. You can influence placement, but by default you just say "give me 650G called phi" and LVM sorts it out.

The trade-off: if a drive fails, any LV whose extents touched that drive is lost — unless you configure LVM mirroring to keep duplicate extents on multiple drives.

### Expanding to two SSDs

With a second SSD the picture becomes:

- **SSD 1** → LUKS (nasvault) → PV1 in `nasvg`
- **SSD 2** → LUKS (nasvault2) → PV2 in `nasvg`
- **`nasvg`** spans both PVs — `phi` could span both drives; `cs` could sit entirely on one
- ext4 and Samba are unchanged — they see no difference

Adding a second SSD later: LUKS it, add it to `nasvg` as a new Physical Volume, and resize logical volumes as needed — no reformatting required.

## Phase 1 — Flash & First Boot

1. Download [Raspberry Pi Imager](https://www.raspberrypi.com/software/)
2. Flash **Raspberry Pi OS Lite (64-bit)** to microSD
3. In Imager's "OS customisation" screen set:
   - Hostname: `nasbox`
   - Username: `nakomis`
   - Password: (your chosen password)
   - WiFi SSID and password
   - Enable SSH with password authentication
4. Insert card, power on Pi, wait ~2 minutes for first-boot filesystem expansion
5. SSH in: `ssh nakomis@nasbox.local`

> **Note:** If SSH fails, check your router's device list for the Pi's IP. If the Pi doesn't appear at all, the WiFi credentials may have a typo — pull the SD card, mount it on another machine, and edit `/boot/firmware/firstrun.sh` or the network config directly.

## Phase 2 — System Prep

```bash
sudo apt update && sudo apt full-upgrade -y
```

Set a static IP via your router's DHCP reservation (preferred) or configure a static address on the Pi.

Copy your SSH public key for passwordless access:

```bash
ssh-copy-id nakomis@nasbox.local
```

## Checkpointing — SD Card Images

Before any risky operation (installing lvm2/cryptsetup, major config changes), snapshot the SD card over SSH directly to your Mac. No need to pull the card out.

**Create image (via SSH — convenient but slow, ~45-60 min over WiFi):**
```bash
ssh nakomis@nasbox.local "sudo dd if=/dev/mmcblk0 bs=4M" | gzip > ~/nasbox-base.img.gz
```

**Create image (via card reader — fast, ~5-10 min, preferred):**

Shut the Pi down first (`sudo shutdown -h now`), pull the card, plug into Mac via USB card reader, then:
```bash
sudo dd if=/dev/diskX bs=4M | gzip > ~/nasbox-base.img.gz
```

Find the correct disk with `diskutil list` — look for the ~64GB device. The card is 64GB but only ~5GB is used, so gzip brings it down to ~1.5GB.

**Restore image** (find your SD card device with `diskutil list` first):
```bash
gunzip -c ~/nasbox-base.img.gz | sudo dd of=/dev/diskX bs=4M
```

Suggested checkpoints:
- `nasbox-pre-base.img.gz` — after apt upgrade and Samba configured (Phase 3 complete), before lvm2/cryptsetup
- `nasbox-pre-luks.img.gz` — after lvm2/cryptsetup installed and crypttab/fstab configured, before first reboot with LUKS

## Phase 3 — Samba + Time Machine

> **Do this before Phase 4 (storage).** The LVM/cryptsetup packages regenerate the initramfs. If crypttab isn't fully configured at that point, the Pi can hang at boot waiting for volumes it can't activate, blocking network services. Install Samba first, verify it works, then proceed to storage.

Install:

```bash
sudo apt install -y samba avahi-daemon
```

Configure `/etc/samba/smb.conf`:

```ini
[global]
   server role = standalone server
   dns proxy = no
   fruit:metadata = stream
   fruit:model = MacSamba
   fruit:veto_appledouble = yes
   fruit:nfs_aces = no
   fruit:wipe_intentionally_left_blank_rfork = yes
   fruit:delete_empty_adfiles = yes

[phi]
   path = /mnt/timemachine/phi
   valid users = nakomis
   read only = no
   browseable = yes
   fruit:aapl = yes
   fruit:time machine = yes
   vfs objects = catia fruit streams_xattr

[cs]
   path = /mnt/timemachine/cs
   valid users = nakomis
   read only = no
   browseable = yes
   fruit:aapl = yes
   fruit:time machine = yes
   vfs objects = catia fruit streams_xattr
```

Create mount points and fix permissions:

```bash
sudo mkdir -p /mnt/timemachine/phi /mnt/timemachine/cs
sudo chown -R nakomis:nakomis /mnt/timemachine
```

Create Samba user (run interactively — do not paste password into chat):

```bash
sudo smbpasswd -a nakomis
```

Enable and start services:

```bash
sudo systemctl restart smbd nmbd avahi-daemon
sudo systemctl enable smbd nmbd avahi-daemon
```

Verify shares are visible from a Mac:

```bash
smbutil view //nakomis@nasbox.local
```

Should list `phi`, `cs`, and `IPC$`. The paths don't exist yet (storage comes next) but the shares will be visible. This is the right point to take the `nasbox-pre-base.img.gz` checkpoint.

## Phase 4 — Storage

### Install dependencies

```bash
sudo apt install -y lvm2 cryptsetup cryptsetup-initramfs systemd-cryptsetup
```

> **Important:** Three packages are required, not just `cryptsetup`:
> - `cryptsetup-initramfs` — adds LUKS support to the initramfs
> - `systemd-cryptsetup` — provides `systemd-cryptsetup-generator`, which reads `/etc/crypttab` and creates the systemd units that unlock LUKS at boot. Without this, LUKS never unlocks automatically.

### Identify the SSD

```bash
lsblk
```

The SSD will appear as `/dev/sdb` (or `/dev/sda` — check the size to confirm).

### Generate LUKS keyfile

```bash
sudo mkdir -p /etc/luks-keys
sudo dd if=/dev/urandom of=/etc/luks-keys/sda.key bs=4096 count=1
sudo chmod 700 /etc/luks-keys
sudo chmod 600 /etc/luks-keys/sda.key
```

### Format with LUKS

Replace `/dev/sdb` with your actual device.

```bash
sudo wipefs -a /dev/sdb
sudo cryptsetup luksFormat /dev/sdb --key-file /etc/luks-keys/sda.key --batch-mode
```

Add a backup passphrase (stored in your password manager — needed if the SD card ever fails):

```bash
sudo cryptsetup luksAddKey /dev/sdb --key-file /etc/luks-keys/sda.key
```

### Open and set up LVM

```bash
sudo cryptsetup luksOpen /dev/sdb nasvault --key-file /etc/luks-keys/sda.key

sudo pvcreate /dev/mapper/nasvault
sudo vgcreate nasvg /dev/mapper/nasvault
sudo lvcreate -L 650G -n phi nasvg
sudo lvcreate -L 180G -n cs nasvg

sudo mkfs.ext4 -L phi /dev/nasvg/phi
sudo mkfs.ext4 -L cs /dev/nasvg/cs

sudo mkdir -p /mnt/timemachine/phi /mnt/timemachine/cs
sudo mount /dev/nasvg/phi /mnt/timemachine/phi
sudo mount /dev/nasvg/cs /mnt/timemachine/cs
```

### Auto-unlock and auto-mount on boot

> **Important:** Use the UUID in crypttab, not `/dev/sda` or `/dev/sdb` — the device name is not stable and changes between reboots depending on when the drive enumerates. Get the UUID with `sudo cryptsetup luksUUID /dev/sdX`.

Add to `/etc/crypttab`:

```
nasvault  UUID=48ec4684-1839-442b-b6e4-199b45dfe7d8  /etc/luks-keys/sda.key  luks,nofail
```

Add to `/etc/fstab`:

```
/dev/nasvg/phi  /mnt/timemachine/phi  ext4  defaults,noatime,nofail  0  2
/dev/nasvg/cs   /mnt/timemachine/cs   ext4  defaults,noatime,nofail  0  2
```

> **Critical:** The `nofail` option on both entries is essential. Without it, the Pi hangs at boot waiting for LUKS to unlock, which blocks network services from starting — the Pi boots but never connects to WiFi. With `nofail`, if the SSD is unavailable at boot the Pi comes up anyway and the volumes can be activated manually over SSH.

### Disable USB autosuspend for the SSD

Linux autosuspends USB devices after 2 seconds of inactivity by default. The Crucial X9 does not wake reliably — it simply vanishes from the bus, leaving LUKS/LVM with stale ghost device-mapper entries that return IO errors on `/mnt/timemachine/phi`.

```bash
sudo tee /etc/udev/rules.d/69-crucial-x9-no-autosuspend.rules << 'EOF'
# Disable USB autosuspend for Crucial X9 SSD (vendor 0634, product 5606)
# The SSD drops off the bus when autosuspended, causing LUKS/LVM to lose the device.
ACTION=="add", SUBSYSTEM=="usb", ATTR{idVendor}=="0634", ATTR{idProduct}=="5606", TEST=="power/control", ATTR{power/control}="on"
EOF

sudo udevadm control --reload-rules && sudo udevadm trigger --subsystem-match=usb
```

Verify: `cat /sys/bus/usb/devices/3-1.2/power/control` should read `on`. (The device path may differ — use `udevadm info /dev/sdb` to find the actual USB path.)

> **USB power:** The Crucial X9 draws up to 900mA during writes — more than the Pi's USB port reliably supplies under sustained load. The SSD must be connected via a **powered USB hub** so it draws current from the hub's PSU rather than the Pi. Do not plug it directly into the Pi.
>
> Add to `/boot/firmware/config.txt`:
> ```
> usb_max_current_enable=1
> ```
>
> Also add to `/boot/firmware/cmdline.txt` (append to the single existing line, no newline) to prevent the UAS driver claiming the device if it ever ends up on a USB 3.0 path:
> ```
> usb-storage.quirks=0634:5606:u
> ```
> Through the hub the SSD runs at USB 2.0 (480M) via `usb-storage` anyway, but the quirk is a safeguard.

### Auto-recovery service

The powered hub does USB-PD negotiation with the Pi and may reset ~30–40 seconds after boot. When it does, all downstream devices (including the SSD) briefly disconnect, leaving LUKS/LVM with stale ghost device-mapper entries. An auto-recovery service detects the SSD re-enumerating and rebuilds the stack automatically.

Create the recovery script:

```bash
sudo tee /usr/local/bin/nas-recovery.sh << 'EOF'
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
EOF
sudo chmod +x /usr/local/bin/nas-recovery.sh
```

Create the systemd service:

```bash
sudo tee /etc/systemd/system/nas-recovery.service << 'EOF'
[Unit]
Description=NAS LUKS/LVM recovery after SSD re-enumeration
DefaultDependencies=no

[Service]
Type=oneshot
ExecStart=/usr/local/bin/nas-recovery.sh
StandardOutput=journal
StandardError=journal
EOF

sudo systemctl daemon-reload
```

Create the udev rule that triggers it:

```bash
sudo tee /etc/udev/rules.d/71-nas-recovery.rules << 'EOF'
# Trigger NAS recovery when the Crucial X9 SSD block device re-appears.
ACTION=="add", SUBSYSTEM=="block", DEVTYPE=="disk", ENV{ID_USB_VENDOR_ID}=="0634", ENV{ID_USB_MODEL_ID}=="5606", RUN+="/usr/bin/systemctl --no-block start nas-recovery.service"
EOF

sudo udevadm control --reload-rules
```

Monitor with: `journalctl -f -t nas-recovery`

### Resizing logical volumes

**Growing** a volume can be done live (no unmount needed):

```bash
sudo lvresize -L +100G /dev/nasvg/cs
sudo resize2fs /dev/nasvg/cs
```

**Shrinking** requires unmounting first. Always shrink the filesystem before the LV — getting this order wrong is data-destroying:

```bash
sudo systemctl stop smbd nmbd
sudo umount /mnt/timemachine/phi

sudo e2fsck -f -p /dev/nasvg/phi          # required before shrinking
sudo resize2fs /dev/nasvg/phi 539G        # shrink filesystem first
sudo lvresize -L 539G /dev/nasvg/phi      # then shrink the LV

sudo mount /mnt/timemachine/phi
sudo systemctl start smbd nmbd
```

To move 100G from `phi` to `cs` (shrink phi, grow cs):

```bash
# Shrink phi (requires unmount — briefly interrupts both shares)
sudo systemctl stop smbd nmbd
sudo umount /mnt/timemachine/phi
sudo e2fsck -f -p /dev/nasvg/phi
sudo resize2fs /dev/nasvg/phi 539G
sudo lvresize -L 539G /dev/nasvg/phi
sudo mount /mnt/timemachine/phi
sudo systemctl start smbd nmbd

# Grow cs (live — no unmount needed)
sudo lvresize -L +100G /dev/nasvg/cs
sudo resize2fs /dev/nasvg/cs
```

### Adding a second SSD later

```bash
# Encrypt and open the new drive
sudo cryptsetup luksFormat /dev/sdc --key-file /etc/luks-keys/sda.key --batch-mode
sudo cryptsetup luksOpen /dev/sdc nasvault2 --key-file /etc/luks-keys/sda.key

# Add to the existing volume group
sudo pvcreate /dev/mapper/nasvault2
sudo vgextend nasvg /dev/mapper/nasvault2

# The VG now has more free space — resize any LV as needed
sudo lvresize -L +500G /dev/nasvg/phi
sudo resize2fs /dev/nasvg/phi
```

## Phase 5 — Connect Time Machine

On each Mac:

**System Settings → General → Time Machine → Add Backup Disk**

Select the `nasbox` share for that machine (`phi` for this Mac, `cs` for the other), enter Samba credentials when prompted.

- **Encrypt Backup**: leave off — encryption is handled at the disk level by LUKS
- **Disk Usage Limit**: leave as None — the LVM logical volume size is the hard limit

> **Permissions note:** If Time Machine shows "disk does not allow reading, writing and appending", the share directory is owned by root. Fix with `sudo chown -R nakomis:nakomis /mnt/timemachine`.

## Credentials

| Secret | Where stored |
|---|---|
| Samba password | Password store: "NAS Box Samba Password" |
| LUKS backup passphrase | Password store: "NAS box key phrase" |
| LUKS keyfile | `/etc/luks-keys/sda.key` on the Pi's SD card |

## Phase 6 — Logging

Enable persistent journaling so logs survive reboots (essential for diagnosing crashes):

```bash
sudo mkdir -p /var/log/journal
sudo systemd-tmpfiles --create --prefix /var/log/journal
sudo systemctl restart systemd-journald
```

Cap journal size to prevent it filling the SD card (default would be ~10% of the partition):

```bash
sudo sed -i 's/#SystemMaxUse=/SystemMaxUse=200M/' /etc/systemd/journald.conf
sudo systemctl restart systemd-journald
```

After any crash, inspect the previous boot with `journalctl -b -1`.

## Phase 7 — Hardening (future)

- SSH key auth only (disable password SSH)
- `ufw` firewall — allow only SSH and Samba from LAN
- Automatic security updates (`unattended-upgrades`)

## Troubleshooting

### IO errors on `/mnt/timemachine/phi` / SSD dropped off bus

The auto-recovery service should handle this automatically within ~30 seconds of the SSD re-enumerating. Check whether it ran:

```bash
journalctl -t nas-recovery --no-pager
```

If it ran and succeeded, the mounts will be back up. If it didn't run, or failed, recover manually:

```bash
sudo systemctl stop smbd nmbd          # Samba holds file handles; must stop first
sudo umount -l /mnt/timemachine/phi /mnt/timemachine/cs

# Remove stale device mapper entries
sudo dmsetup remove nasvg-phi 2>/dev/null; sudo dmsetup remove nasvg-cs 2>/dev/null; sudo dmsetup remove nasvault 2>/dev/null

# Re-open LUKS — use whichever device lsblk shows (sda or sdb)
sudo cryptsetup luksOpen /dev/sda nasvault --key-file /etc/luks-keys/sda.key
sudo vgchange -ay nasvg
sudo mount /mnt/timemachine/phi && sudo mount /mnt/timemachine/cs
sudo systemctl start smbd nmbd
```

If the SSD is not present in `lsblk`, check the hub is powered and the USB cable is seated.

## Scripts

These live on the Pi at `/home/nakomis/` and `/usr/local/bin/`, and are versioned in `scripts/` in this repo.

| Script | Location on Pi | Purpose |
|---|---|---|
| `checksamba.sh` | `~/checksamba.sh` | Shows LUKS status, df for both volumes, and actual sparsebundle sizes on disk |
| `shutdown.sh` | `~/shutdown.sh` | Clean shutdown (`sudo shutdown -h now`) |
| `resize-lv.sh` | `~/resize-lv.sh` | Grow or shrink phi/cs logical volumes safely |
| `nas-recovery.sh` | `/usr/local/bin/nas-recovery.sh` | Automatically rebuilds LUKS/LVM stack after SSD re-enumeration (triggered by udev) |

### checksamba.sh

Quick health check — run this any time you want to know if everything is up:

```bash
ssh nasbox.local ~/checksamba.sh
```

Shows: LUKS/cryptsetup service status, `df` for phi and cs, and the actual on-disk size of each Time Machine sparsebundle (more accurate than `df` for understanding true backup size).

### shutdown.sh

Convenience wrapper for clean shutdown before pulling power:

```bash
ssh nasbox.local ~/shutdown.sh
```

### resize-lv.sh

Wrapper around the grow/shrink procedures in the LV Resize section. Handles ordering, fsck, Samba stop/start:

```bash
# Grow cs by 100G (live, no unmount needed)
ssh nasbox.local sudo ~/resize-lv.sh grow cs 100G

# Shrink phi to exactly 539G (stops Samba, unmounts, remounts)
ssh nasbox.local sudo ~/resize-lv.sh shrink phi 539G
```

### nas-recovery.sh

Called automatically by `systemd` when the SSD re-enumerates (via the udev rule in `/etc/udev/rules.d/71-nas-recovery.rules`). Can also be run manually after an unrecoverable IO error. See the Troubleshooting section.

## Annex — Rust UI Integration

The Pi runs a Rust touchscreen app (heating controller UI). A NAS status tab is a natural extension.

### What to display

- Used/free space on `phi` and `cs`
- Whether `smbd` is running
- Whether `nasvault` (LUKS) is open and volumes are mounted

### Crates and approaches

| Need | Approach |
|---|---|
| Filesystem usage (`df`) | `nix::sys::statvfs` or `sysinfo` crate — no shelling out |
| Systemd service status / start / stop | `zbus` crate — D-Bus to systemd directly |
| LVM volume info (`lvs`) | Shell out: `lvs --reportformat json` and parse with `serde_json` |
| LUKS status | Read `/sys/block` or `dmsetup info` — `cryptsetup-rs` exists but is overkill for status queries |
| Block device info | Read `/sys/block` directly — it's just files |

### LVM via JSON

`lvs` and `vgs` support `--reportformat json` which makes parsing straightforward:

```bash
lvs --reportformat json --units g -o lv_name,lv_size,data_percent nasvg
```

Call this from Rust with `std::process::Command`, deserialise with `serde_json`.

### Systemd via D-Bus

`zbus` lets you query and control systemd services without shelling out:

```rust
// Check if smbd is active
let connection = zbus::Connection::system().await?;
// query org.freedesktop.systemd1 for smbd.service ActiveState
```

### Advice

For a status display, `sysinfo` + `zbus` + `lvs --reportformat json` covers everything without exotic dependencies. The D-Bus route for LVM (`lvmdbusd`) is more correct but requires the daemon to be running and is significantly more work for little gain on a personal project.

## Future Plans

- **Remote LUKS unlock via AWS**: Replace the SD card keyfile with an HTTPS call to an AWS endpoint (Lambda + API Gateway) that only accepts requests from the home IP. Key material stored in AWS Secrets Manager. See [Trello card](https://trello.com/c/Ys0kOOVs/50-nas-replace-sd-keyfile-unlock-with-aws-endpoint-based-luks-unlock).
- **Alpine Linux**: Rebuild on a minimal Alpine Linux image for smaller footprint and faster boot.
- **Buildroot**: Eventually build a fully custom minimal OS image from scratch — educational goal.
