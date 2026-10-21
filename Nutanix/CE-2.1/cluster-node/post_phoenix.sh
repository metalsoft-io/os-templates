#!/bin/bash
# {% raw %} (template asset with templatingEngine on - see template.yaml; raw keeps the bash verbatim)
# MetalSoft nutanix-ce: CE installer (phoenix) post_phoenix hook.
# Shipped inside the per-instance ISO (OS template asset, /post_phoenix.sh). The answer file's
# hook_scripts.post_phoenix mounts the installer ISO (label PHOENIX, still attached as virtual media)
# and runs this right before phoenix reboots.
#
# Phoenix only adds a host UEFI boot entry for AHV on layouts it recognises (Dell/iLO/Intel), not for
# CE's generic one, and the platform keeps the virtual CD attached until SSH answers - so without this the
# server boots the installer ISO again and reinstalls in a loop. Each loop pass also leaves a stale
# "Nutanix AHV" entry behind; enough of them and the firmware stops honouring the new entry's position.
# So: drop stale entries, create the entry for the disk AHV was just installed on, put it first and set
# BootNext to it (one-shot, honoured regardless of BootOrder). Hardware-agnostic: the AHV disk is found
# by its ESP contents, not by name.

LABEL='Nutanix AHV'
LOADER='EFI/centos/shimx64.efi'

log() { echo "post_phoenix: $*"; }

if [ ! -d /sys/firmware/efi ] || ! command -v efibootmgr >/dev/null 2>&1; then
  log "not booted in UEFI mode or no efibootmgr - nothing to do"
  exit 0
fi

# The AHV disk is the one whose first partition (the ESP) holds the AHV loader.
# sdX: SATA/SAS/USB, nvmeXnY: NVMe, vdX: virtio, mmcblkX: SD/eMMC
disk=""
for part in /dev/sd?1 /dev/sd??1 /dev/nvme*n*p1 /dev/vd?1 /dev/mmcblk?p1; do
  [ -b "$part" ] || continue
  mnt=$(mktemp -d)
  if mount -o ro "$part" "$mnt" 2>/dev/null; then
    if [ -f "$mnt/$LOADER" ]; then
      case "$part" in *p1) disk=${part%p1} ;; *) disk=${part%1} ;; esac
    fi
    umount "$mnt"
  fi
  rmdir "$mnt"
  [ -n "$disk" ] && break
done
if [ -z "$disk" ]; then
  log "no partition 1 holds $LOADER - leaving UEFI boot entries untouched"
  exit 1
fi
log "AHV boot disk: $disk"

entries() { efibootmgr | sed -n "s/^Boot\([0-9A-Fa-f]\{4\}\)\*\{0,1\} .*${LABEL}.*/\1/p"; }

for n in $(entries); do
  log "removing stale entry Boot$n"
  efibootmgr -q -b "$n" -B
done

# -c inserts the new entry at the front of BootOrder
efibootmgr -q -c -d "$disk" -p 1 -L "$LABEL" -l '\EFI\centos\shimx64.efi'
new=$(entries | head -1)
if [ -z "$new" ]; then
  log "failed to create the '$LABEL' entry"
  exit 1
fi
efibootmgr -q -n "$new"
log "created Boot$new on $disk, first in BootOrder and set as BootNext"
efibootmgr
# {% endraw %}
