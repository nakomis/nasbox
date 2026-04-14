#!/bin/bash
# Resize LVM logical volumes for phi and cs.
# Usage:
#   ./resize-lv.sh grow cs 100G        # grow cs by 100G (live, no unmount)
#   ./resize-lv.sh shrink phi 539G     # shrink phi to 539G (requires unmount)
#
# Rules:
#   - Always shrink the filesystem before the LV (resize2fs then lvresize)
#   - Always grow the LV before the filesystem (lvresize then resize2fs)
#   - Shrinking requires Samba to stop and the volume to unmount
#   - Growing can be done live

set -e

usage() {
    echo "Usage: $0 <grow|shrink> <phi|cs> <size>"
    echo "  grow   phi 100G   — grow phi by 100G (live)"
    echo "  shrink phi 539G   — shrink phi to exactly 539G (requires unmount)"
    exit 1
}

[ "$#" -ne 3 ] && usage

ACTION="$1"
LV="$2"
SIZE="$3"

if [[ "$LV" != "phi" && "$LV" != "cs" ]]; then
    echo "Error: LV must be 'phi' or 'cs'"
    exit 1
fi

DEVICE="/dev/nasvg/$LV"
MOUNTPOINT="/mnt/timemachine/$LV"

case "$ACTION" in
    grow)
        echo "Growing $LV by $SIZE (live)..."
        sudo lvresize -L "+$SIZE" "$DEVICE"
        sudo resize2fs "$DEVICE"
        echo "Done."
        df -h "$MOUNTPOINT"
        ;;

    shrink)
        echo "Shrinking $LV to $SIZE (requires Samba stop and unmount)..."
        echo "Stopping Samba..."
        sudo systemctl stop smbd nmbd

        echo "Unmounting $MOUNTPOINT..."
        sudo umount "$MOUNTPOINT"

        echo "Running fsck..."
        sudo e2fsck -f -p "$DEVICE"

        echo "Shrinking filesystem to $SIZE..."
        sudo resize2fs "$DEVICE" "$SIZE"

        echo "Shrinking LV to $SIZE..."
        sudo lvresize -L "$SIZE" "$DEVICE"

        echo "Remounting and restarting Samba..."
        sudo mount "$MOUNTPOINT"
        sudo systemctl start smbd nmbd

        echo "Done."
        df -h "$MOUNTPOINT"
        ;;

    *)
        usage
        ;;
esac
