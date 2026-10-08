#!/bin/bash
# Build ubuntu-cidata-boot.iso, the small UEFI boot ISO this template uses as its
# build_source_image (virtual media 1). It contains no installer: its GRUB boots the
# kernel of the stock Ubuntu ISO mounted on virtual media 2 (see grub.cfg).
#
# The boot pieces (Ubuntu's signed shim/GRUB EFI partition, GRUB MBR, BIOS El Torito
# image) and the boot layout are copied from the stock ISO, because the MetalSoft
# image builder's Ubuntu path expects exactly that layout when it rebuilds the ISO
# with the template's files. The volume label must stay CIDATA so cloud-init finds
# user-data/meta-data on it.
#
# usage: ./build-cidata-boot-iso.sh <stock ubuntu live-server ISO> [output ISO]
set -euo pipefail

STOCK=$(realpath "$1")
OUT=$(realpath -m "${2:-ubuntu-cidata-boot.iso}")
HERE=$(cd "$(dirname "$0")" && pwd)
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

xorriso -osirrox on -indev "$STOCK" \
    -extract_boot_images "$WORK/boot" \
    -extract /boot/grub/i386-pc/eltorito.img "$WORK/tree/boot/grub/i386-pc/eltorito.img" \
    >/dev/null 2>&1
chmod -R u+w "$WORK/tree"
cp "$HERE/grub.cfg" "$WORK/tree/boot/grub/grub.cfg"

rm -f "$OUT"
xorriso -as mkisofs -r -J -joliet-long -l -V CIDATA \
    --grub2-mbr "$WORK/boot/mbr_code_grub2.img" \
    --protective-msdos-label -partition_cyl_align off -partition_offset 16 --mbr-force-bootable \
    -append_partition 2 28732ac11ff8d211ba4b00a0c93ec93b "$WORK/boot/gpt_part2_efi.img" -appended_part_as_gpt \
    -iso_mbr_part_type a2a0d0ebe5b9334487c068b6b72699c7 \
    -c /boot.catalog \
    -b /boot/grub/i386-pc/eltorito.img -no-emul-boot -boot-load-size 4 -boot-info-table --grub2-boot-info \
    -eltorito-alt-boot \
    -e --interval:appended_partition_2:all:: -no-emul-boot \
    -o "$OUT" "$WORK/tree" 2>&1 | grep -E "FAILURE|SORRY|Written" || true

ls -la "$OUT"
