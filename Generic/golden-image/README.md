# Golden image OS templates

A golden image template doesn't run an OS installer. It writes a ready-made disk image to the server's
local disk, and the OS configures itself on first boot: cloud-init on Linux, Cloudbase-Init on Windows.
The steps are the same for any OS; only the image and the first-boot files differ.

This guide assumes you already have the golden image. Step 1 lists what it must have.

This guide uses `metalcloud-cli` 7.5. It lists two complete example templates in
[Example templates](#appendix-example-templates); in this repository they're also next to this file:

| Directory | Use for |
|---|---|
| `linux-cloud-init/` | any Linux image that has cloud-init |
| `windows-cloudbase-init/` | a sysprepped Windows image that has Cloudbase-Init |

## Overview

First, [before you start](#before-you-start): set up `metalcloud-cli`, and check that the servers boot UEFI
and their BMCs support dual virtual media mounts. Then:

1. [**Check the golden image**](#step-1-check-the-golden-image): a raw UEFI whole-disk image (zstd compression optional) with cloud-init or Cloudbase-Init set up for NoCloud.
2. [**Package it**](#step-2-package-the-image-iso): put the image file alone in an ISO.
3. [**Upload it**](#step-3-upload-the-image-iso) to a web server MetalSoft can [download it from](#who-downloads-the-isos), with a new file name for each version.
4. [**Write the template directory**](#step-4-write-the-template-directory): copy an example, then set the name, label, `os.name` and the image ISO's URL.
5. [**Check it offline**](#step-5-check-it-offline): `metalcloud-cli os-template list-directory`.
6. [**Create the template**](#step-6-create-the-template): `metalcloud-cli os-template create-from-directory`, then check its five assets.
7. [**Test it on one server**](#step-7-test-on-one-server): watch the console until the server powers off, then check its network and logins.
8. [**Maintain it**](#step-8-change-it-later): update rendered files in place, make a new template for each new image, publish once it passes.

To do steps 1 to 6 with one command, see [Helper scripts](#appendix-helper-scripts).

To change the boot ISO's script or build your own boot ISO, see
[How the boot ISO works](#appendix-how-the-boot-iso-works).

## How a deployment runs

MetalSoft mounts two virtual media on the server:

| Slot | Asset `usage` | What it is | Provided by |
|---|---|---|---|
| 1 | `build_source_image` | `boot-golden-image.iso`, a small live Linux with volume label `CIDATA`. For each server, MetalSoft renders `user-data`, `meta-data` and `network-config` and adds them to it. | MetalSoft |
| 2 | `secondary_image` | Your image ISO: one raw or zstd-compressed disk image. Mounted unchanged. Depending on the BMC, the server sees it as a CD or as a USB disk (HPE and older Dell iDRACs use their virtual USB device); the script finds it either way. | You |

1. **Write the image.** The server boots slot 1, a grml live Linux. After a 20-second boot menu, grml runs
   the ISO's `scripts/grml.sh` (the ISO's `bootparams/metalsoft` file adds the `scripts` boot parameter,
   which tells grml to run it). The script finds your image on slot 2 and picks
   the target disk: a Dell BOSS disk if there is one, otherwise the smallest local disk that isn't removable
   or USB. It wipes that disk, writes the image, moves the backup GPT to the end of the disk, creates a UEFI
   boot entry for the disk and reboots.
2. **First boot.** The server boots from the local disk. cloud-init or Cloudbase-Init finds the `CIDATA`
   ISO, which is still attached, and applies the hostname, network, password and SSH keys. The root
   partition (Linux) or C: (Windows) grows to fill the disk.
3. **Done.** The OS powers off, and MetalSoft's `wait_for_power_off` marks the install as finished. MetalSoft
   then sets the server to boot from its disk first, ejects both virtual media and powers the server on.

## Before you start

- **CLI:** the version must match the controller's (`metalcloud-cli version` shows the range it supports).
  Set the controller's address and your API key (in the UI: top right, API credentials). The last command
  in each example proves they work.

  Linux or macOS (bash, zsh):

  ```bash
  export METALCLOUD_ENDPOINT=https://<controller>
  export METALCLOUD_API_KEY=<api key>
  metalcloud-cli os-template list
  ```

  Windows (PowerShell):

  ```powershell
  $env:METALCLOUD_ENDPOINT = "https://<controller>"
  $env:METALCLOUD_API_KEY = "<api key>"
  metalcloud-cli os-template list
  ```

  Windows (Command Prompt):

  ```bat
  set METALCLOUD_ENDPOINT=https://<controller>
  set METALCLOUD_API_KEY=<api key>
  metalcloud-cli os-template list
  ```

  These settings last only as long as the terminal window. To keep them, add the lines to your shell
  profile (`~/.bashrc`, `~/.zshrc`, or `$PROFILE` in PowerShell).

- **Servers:** UEFI boot, and a BMC that supports dual virtual media mounts.
- **Workstation:** Linux or macOS with `xorriso` to package the image, plus `qemu-img` or `zstd` if you need
  to convert or compress it.

### Who downloads the ISOs

Both ISOs (the boot ISO and your image ISO) are downloaded from their URLs by one of two components. Which
one depends on how the site controller at the server's site was installed:

| Site controller | Downloads the ISOs | Then |
|---|---|---|
| Image building off (the default) | The global controller's image builder | The global controller sends each server's copy to the site controller through the tunnel. |
| Image building on (installed with the `BUILD_IMAGE` capability) | The site controller's agent, directly | Nothing more to do: the copy is already on the site controller. |

- **URLs:** they must be reachable from the component that downloads them, not just from your
  workstation: the global controller by default, the site controller when it builds images.
- **To check a site controller:** it builds images if it runs an `sc-image-builder` container
  (`docker ps`).
- **Either way**, the BMC mounts the copy that's on the site controller.
- **Disk space:** a separate copy of your image ISO is kept for each server being deployed. The site
  controller deletes its copy when the deploy ends; the global controller's image builder (release 7.5)
  keeps its copy afterwards, also for servers that were deleted. Plan the space on whichever controllers
  hold copies, especially for Windows images.

## Step 1: Check the golden image

Your golden image must meet these requirements, set by how the boot ISO writes it and by the example
first-boot files.

### Every image

- **A whole disk:** the partition table (GPT) and the EFI system partition, not just a root filesystem.
- **A fallback boot loader:** `\EFI\BOOT\BOOTX64.EFI` on the EFI system partition. The UEFI boot entry the
  boot ISO creates for the new disk points at it, and firmware without that entry falls back to it.
  Distribution cloud images and Windows have it.
- **Raw format:** `.raw` or `.img`. qcow2 is detected and rejected. Convert qcow2, VMDK or VHDX images
  first: `qemu-img convert -O raw <image> <name>.raw`.
- **Compression is optional:** a zstd-compressed raw image (`.raw.zst`, `.img.zst`) works too
  (`zstd -T0 -10 <name>.raw`). It usually pays off, because the ISO is smaller to upload, store and
  download, and the server reads less over virtual media. An uncompressed image does have one advantage:
  it's checked against the target disk's size before anything is written.
- **Small, with the root partition last:** the uncompressed image must fit on the smallest disk it can land
  on (10 to 40 GB is typical). The OS grows its last partition on first boot, so the root partition
  (Linux) or C: (Windows) must be the last partition. Windows Setup normally puts the recovery partition
  after C:, which prevents this.
- **Drivers** for the servers' NICs and storage controllers. Cloud images often carry only the drivers
  virtual machines need:
  - Ubuntu cloud images leave out `linux-modules-extra` (it comes with `linux-generic`).
  - Debian's `genericcloud` images leave out hardware drivers; the `generic` images have them.
  - SLES and openSUSE Leap `Minimal-VM` images can ship `kernel-default-base`, a reduced driver set (Leap
    16's does). `kernel-default` has the full set.
- **No machine identity:** see the Linux and Windows requirements below.

### Linux

- **cloud-init with the NoCloud data source.** Distribution cloud images have it. If the image sets
  `datasource_list` in `/etc/cloud/cloud.cfg` or `/etc/cloud/cloud.cfg.d/`, the list must include `NoCloud`.
- **cloud-init 22.3 or later** for the root password in the example `user-data` (see step 4).
- **A clean cloud-init state:** if the image was booted after it was made, it must have been cleaned with
  `cloud-init clean --logs --machine-id` before it was shut down. Otherwise the server's first boot isn't
  treated as a first boot.
- **Any kernel options the servers need, set in the image.** The boot ISO starts its own kernel with
  `intel_iommu=on iommu=pt`, but its options don't carry over to the installed OS, and cloud-init runs too
  late to add any. Set them in the image's boot loader configuration, the way that survives kernel updates:
  - Ubuntu and Debian: a file in `/etc/default/grub.d/`, then `update-grub`:
    ```bash
    echo 'GRUB_CMDLINE_LINUX_DEFAULT="$GRUB_CMDLINE_LINUX_DEFAULT intel_iommu=on iommu=pt"' \
        > /etc/default/grub.d/99-kernel-options.cfg
    update-grub
    ```
  - RHEL and its rebuilds: `grubby --update-kernel=ALL --args="intel_iommu=on iommu=pt"`.

  For example, on a Lenovo ThinkSystem SR250 with a ThinkSystem RAID 530-8i, Ubuntu 24.04's kernel, which
  turns the IOMMU on in translated mode by default, couldn't use the RAID controller. The controller's
  memory writes were blocked (`DMAR: [DMA Write NO_PASID] Request device [06:00.0] fault`), its driver gave
  up (`megaraid_sas ... Failed from megasas_init_fw`), no disk appeared, and the boot stopped at an
  `(initramfs)` prompt. That prompt is on the serial console when the image's kernel command line ends
  with `console=ttyS0`, as cloud images' do, so the screen just looks frozen. The boot ISO's kernel had
  used the same controller without trouble. With `intel_iommu=on iommu=pt` set in the image as shown above,
  Ubuntu found the RAID volume and the deploy completed.

### Windows

- **Cloudbase-Init 1.1.5 or later.** Older versions can't read the network config format the example
  templates use (version 2).
- **NoCloud as Cloudbase-Init's metadata service.** In `C:\Program Files\Cloudbase Solutions\Cloudbase-Init\conf\`,
  the `[DEFAULT]` section of both `cloudbase-init.conf` (used by the service) and
  `cloudbase-init-unattend.conf` (used during Sysprep's specialize pass) must have:

  ```ini
  metadata_services=cloudbaseinit.metadata.services.nocloudservice.NoCloudConfigDriveService
  ```

  Otherwise Cloudbase-Init tries the cloud metadata services first (OpenStack, EC2 and others) and waits for
  each one to time out.
- **The plugins the example needs.** With the default plugin list (no `plugins=` line) everything is there.
  If `plugins=` is set, it must include `SetHostNamePlugin`, `NetworkConfigPlugin` and `UserDataPlugin`.
- **Recommended: `LocalScriptsPlugin` with `local_scripts_path` set** in `cloudbase-init.conf` (and
  `LocalScriptsPlugin` last if `plugins=` is set). The example user-data then powers the server off from a
  script Cloudbase-Init runs after everything else. Without them, it schedules the power-off for two minutes
  after it finishes, which is enough when `UserDataPlugin` is the last plugin:

  ```ini
  local_scripts_path=C:\Program Files\Cloudbase Solutions\Cloudbase-Init\LocalScripts\
  ```

  `ExtendVolumesPlugin` is optional: the example user-data extends C: itself.
- **Drivers in the driver store**, so Windows installs them when it finds the hardware.
- **Sysprepped** with the `Unattend.xml` that ships with Cloudbase-Init, which starts Cloudbase-Init during
  the specialize pass, and not booted since:

  ```bat
  C:\Windows\System32\Sysprep\sysprep.exe /generalize /oobe /shutdown /unattend:"C:\Program Files\Cloudbase Solutions\Cloudbase-Init\conf\Unattend.xml"
  ```

- **Optional: OpenSSH Server**, for SSH key login. The example user-data sets up the keys only if it's
  installed.

## Step 2: Package the image ISO

```bash
mkdir osimage
mv rocky-9-golden-v1.raw.zst osimage/
xorriso -as mkisofs -iso-level 3 -V OSIMAGE -R -J -joliet-long \
  -o rocky-9-golden-v1.raw.zst.iso osimage/

# Check: exactly one image file at the top level (and "Volume Id : OSIMAGE" if you set the label)
xorriso -indev rocky-9-golden-v1.raw.zst.iso -ls / 2>/dev/null
xorriso -indev rocky-9-golden-v1.raw.zst.iso -pvd_info 2>/dev/null | grep 'Volume Id'
```

- **File name ending in `.iso`:** Dell and HPE BMCs, and possibly others, accept only `.iso` and `.img`
  files for virtual media, and MetalSoft mounts the file under the asset's `file.name`. That's why the
  examples are named `<image file>.iso`, such as `rocky-9-golden-v1.raw.zst.iso`. An iDRAC refuses any
  other name, `.zst` included (`RAC0788`: it takes the URL for a folder). It does accept a zstd file
  renamed to `.iso`, but presents it as a CD, where the script doesn't look for an image: name a zstd
  image you mount directly `.img` (see the Dell alternative below).
- **Label (optional, recommended):** the script looks first for a volume labeled `OSIMAGE`. Without that
  label, it searches every CD, removable and USB device except the boot ISO for a single image file. It
  stops with an error if more than one device holds one, for example a USB stick left in the server.
  The label makes the choice unambiguous.
- **One image file:** exactly one image file at the top level, named `*.raw`, `*.img`, `*.raw.zst` or
  `*.img.zst`. The script tells zstd from raw by the file's first bytes, not by its name.
- **Large files:** `-iso-level 3` allows files larger than 4 GiB, which Windows images usually are. Without
  it, xorriso refuses them.
- **Optional checksum:** put `<image file>.sha256` next to the image (`sha256sum <file> > <file>.sha256`)
  and the script verifies the image before writing it. That reads the whole image over virtual media one
  extra time, so imaging takes about twice as long.

### Alternative on Dell: mount the image without an ISO

Slot 2 can also hold the image file itself, named `.img`. On a Dell PowerEdge R340 with iDRAC 7.00, a zstd
image named `<name>.raw.zst.img` showed up as a USB disk, and the script wrote it to the local disk
directly. Conditions:

- **Name it `.img`.**
- **Pad a zstd image to a multiple of 512 bytes.** The server sees a disk, which always ends on a whole
  512-byte sector; the BMC fills the rest with zeros, and zstd rejects trailing zeros. This appends a zstd
  "skippable frame" that zstd ignores:

  ```bash
  python3 - rocky-9-golden-v1.raw.zst <<'PY'
  import os, struct, sys
  f = sys.argv[1]; pad = (-os.path.getsize(f)) % 512
  if pad:
      if pad < 8: pad += 512
      with open(f, "ab") as o: o.write(struct.pack("<II", 0x184D2A50, pad - 8) + b"\0" * (pad - 8))
  PY
  zstd -t rocky-9-golden-v1.raw.zst
  mv rocky-9-golden-v1.raw.zst rocky-9-golden-v1.raw.zst.img
  ```

  An uncompressed raw image is already a whole number of sectors.
- **Only one such disk:** without an ISO there's no label to find, so the script uses this only when exactly
  one removable or USB disk is attached besides the boot ISO, and doesn't check what's on it.
- **Not on Lenovo:** a Lenovo ThinkSystem SR250 (XClarity Controller firmware 6.00) refused a zstd `.img` in
  every virtual media slot (`InternalError`). It accepted an uncompressed `.img`, but the server then saw an
  empty drive in that slot once the boot ISO was mounted too. With the ISO packaging, the server saw both
  images and the deploy completed (with the kernel options from step 1). Use the ISO packaging on Lenovo
  servers.
- **Other vendors:** HPE and Supermicro BMCs haven't been tested this way.

## Step 3: Upload the image ISO

1. Put the ISO on an HTTP(S) server that the downloading component can reach (see
   [Who downloads the ISOs](#who-downloads-the-isos)). From there, `curl -sI <url>` should return `200` and
   the right `Content-Length`. An HTTPS URL needs a certificate the downloader trusts: a self-signed one,
   such as a site controller's, fails the download. Use plain HTTP for such a server.
2. **Give every new image version a new file name**, for example `rocky-9-golden-v2.raw.zst.iso`.
   Downloads are reused by file name, and the URL is never checked for a newer file, so an image
   re-uploaded under the same name can keep deploying the old copy:
   - A site controller that builds images keeps one copy of each file for every deploy at its site. It
     deletes a cached `.iso` only after 48 hours without use; a file with another extension stays until
     someone deletes it.
   - The global controller's image builder (the default) keeps each server's copy of the image and reuses it
     when the same server instance is deployed again, for example to reinstall it.

The boot ISO comes from MetalSoft at `https://repo.metalsoft.io/.iso/boot-golden-image.iso`. For an
air-gapped site, mirror it and use the mirror's URL in the `build_source_image` asset, or pass
`--source-iso <url>` in step 6. The global controller downloads the boot ISO again for every server. A
site controller that builds images caches it by file name like your image, so a new version published under
the same name reaches that site once its cached copy has gone 48 hours without use, or is deleted from
`buildImageRequest/` in the site controller's image folder.

## Step 4: Write the template directory

Create a directory for the template and put the example's four files in it (`template.yaml`, `user-data`,
`meta-data`, `network-config`): copy them from [Example templates](#appendix-example-templates), or copy
`linux-cloud-init/` or `windows-cloudbase-init/` if you have this repository.

```bash
mkdir -p ~/golden-templates/Golden/rocky-9/golden-v1
cd ~/golden-templates/Golden/rocky-9/golden-v1
# save template.yaml, user-data, meta-data and network-config here
```

- **Depth:** `create-from-directory` finds templates exactly three levels below `--dir`
  (`Golden/rocky-9/golden-v1` here).
- **No images in it:** the CLI reads every file in the template directory into memory. Keep images and
  ISOs out of it.

Edit `template.yaml`:

| Field | Set to |
|---|---|
| `name`, `label`, `description` | Your own values. The label must be unique on the controller. |
| `os.name` | A name for the OS, such as `rocky-golden-image`. **Never exactly `windows`, `rhel` or `redhat`** (in any case): the image builder chooses how to rebuild the boot ISO from this field, and those names select installer-specific methods that break the boot ISO. |
| `os.version` | Free text, such as `"9.6"`. |
| `os.credential` | `username: root` (Linux) or `Administrator` (Windows), with `passwordtype: generated`. MetalSoft generates a password for each server, and the user-data sets it. |
| `install.readymethod` | `wait_for_power_off`. The user-data powers the server off at the end. |
| `secondary_image` asset | `file.name`: your ISO's file name, ending in `.iso` (step 2). `file.path`: `/` plus the same name. `file.url`: where you uploaded it. |
| `build_source_image` asset | Leave as is, unless you use a mirror. |

The other assets (`build_component`) are rendered for each server with the MetalSoft template language
and added to the top level of the boot ISO:

| File | Linux (`linux-cloud-init`) | Windows (`windows-cloudbase-init`) |
|---|---|---|
| `user-data` | cloud-config: hostname, root password, SSH keys, grow the root partition, fix bond options on NetworkManager systems, disable cloud-init after first boot, power off | PowerShell (`#ps1_sysnative`): Administrator password, SSH keys if OpenSSH Server is installed, NTP servers, extend C:, power off |
| `meta-data` | instance ID and hostname | same file as Linux |
| `network-config` | network config version 2 built from MetalSoft's interface data: NICs matched by MAC and named `phy<N>`, bonds `bond<N>`, VLANs `<parent>.<id>`, with addresses, routes and DNS | same file as Linux |

Change them as you need. Points to keep:

- **Network: `network-config` only.** cloud-init reads it on every Linux distribution and Cloudbase-Init
  1.1.5 or later reads it on Windows; don't add other network files to the template.
- **Linux: root password.** The `chpasswd: users:` form needs cloud-init 22.3 or later. Older images, such
  as Debian 11 with 20.4, need the older `chpasswd: list:` form.
- **Linux: cloud-init is disabled after first boot.** Provisioning is one-shot. Without this, a distribution
  whose cloud-init still runs once the `CIDATA` ISO is gone may treat the server as a new instance and
  rewrite its network configuration. Remove the `runcmd` line if you need cloud-init later.
- **Windows: hostnames longer than 15 characters** are cut to 15 by Cloudbase-Init.
- **`managementSSHKey`** can render empty, so don't rely on it alone for access.

To change how the boot ISO's script behaves, add a `deployment.conf` asset (`usage: build_component`,
`path: /deployment.conf`, `templatingengine: false`). It's a shell file of `NAME=value` lines:

| Setting | Default | Use it to |
|---|---|---|
| `IMAGE_LABEL` | `OSIMAGE` | use a different volume label on your image ISO |
| `IMAGE_FILE` | the only image file | choose the file when the ISO holds more than one |
| `SOURCE_DEVICE` | detected | name the image's block device when detection picks the wrong one |
| `REPAIR_GPT` | `true` | turn off moving the backup GPT to the end of the disk |
| `REBOOT_ON_SUCCESS` | `true` | set `false` to stay in the live system after writing, for debugging |
| `CREATE_BOOT_ENTRY` | `true` | set `false` to leave the server's UEFI boot entries alone |
| `BOOT_ENTRY_LABEL` | `MetalSoft golden image` | name the UEFI boot entry the script creates |

There's no setting for the target disk. It's always the BOSS disk on Dell servers, or the smallest
eligible local disk otherwise.

### One set of Linux files for every distribution

The Linux files aren't specific to Ubuntu. `user-data` and `meta-data` are cloud-init's own formats, read
the same way on every distribution. `network-config` uses the netplan-style syntax that cloud-init reads
everywhere, and cloud-init converts it into the distribution's own network configuration on first boot:

| Image | cloud-init writes |
|---|---|
| Ubuntu, Debian 12 and 13 | netplan |
| RHEL, Rocky, AlmaLinux 8 and 9 | ifcfg files in `/etc/sysconfig/network-scripts` |
| RHEL, Rocky, AlmaLinux 10 | NetworkManager keyfiles |
| SLES, openSUSE Leap 15 | ifcfg and `ifroute` files in `/etc/sysconfig/network` (wicked) |
| SLES, openSUSE Leap 16 | NetworkManager keyfiles |

What does differ between distributions:

- **Default user:** `ubuntu`, `debian`, `cloud-user`, `rocky`, `almalinux`, `sles` and so on. `users: [default]`
  keeps whichever user the image defines and gives it the SSH keys.
- **cloud-init version:** the root password needs 22.3 or later (see above). Current releases all have it:
  Debian 12 has 22.4, RHEL 8.10 has 23.4, RHEL 9 and 10 have 24.4, Leap 15.6 has 23.3 and Leap 16 has 25.1.
- **Bonds on NetworkManager systems:** cloud-init 26.2 and earlier leave `lacp_rate` and
  `xmit_hash_policy` out of the bond when they write NetworkManager keyfiles. The bond still comes up, but
  with slow LACP and layer 2 hashing, so all routed traffic uses one link. The example `user-data` sets the
  two options with `nmcli`, and they apply from the next boot. Remove that `runcmd` entry once your image
  has a cloud-init release with the fix (upstream pull request 6936).

## Step 5: Check it offline

```bash
metalcloud-cli os-template list-directory --dir ~/golden-templates
```

Your template must appear in the list. This needs no controller, but it doesn't check that the asset
files exist: an asset whose `file.name` matches no file is created empty, and the deploy then fails with
`either ContentBase64 or SourceURL must be provided`. Compare the directory listing with the asset list.

## Step 6: Create the template

```bash
metalcloud-cli os-template create-from-directory Golden/rocky-9/golden-v1 --dir ~/golden-templates
metalcloud-cli os-template list                 # find the new template's ID
metalcloud-cli os-template get-assets <id>      # five assets: boot ISO, image ISO, user-data, meta-data, network-config
```

- **Visibility:** the template is created private, whatever `template.yaml` says.
- **Overrides:** `--name` and `--label` override the values in `template.yaml`. `--source-iso <url>`
  replaces the boot ISO URL.

## Step 7: Test on one server

Deploy one server with the template, on a network whose gateway works. MetalSoft only shows a failure as
the OS install step timing out, so watch the server's console:

| Stage | What you should see | Where to look if it goes wrong |
|---|---|---|
| Boot ISO | The grml boot menu for 20 seconds, then lines starting `MetalSoft:`, then the image being written | The console shows `MetalSoft deployment FAILED` and the reason. The full log is `/var/log/metalsoft-deploy.log` in the live system. |
| Reboot | The server boots from its local disk: `Booting from ...: MetalSoft golden image` | The script creates that boot entry and puts it first. Without it (`CREATE_BOOT_ENTRY=false`, or a boot ISO from before the script did this), the firmware decides: a Dell PowerEdge R340 tried its old boot entries and PXE, and listed the new disk last, after the virtual CD, so the boot ISO would have run again and rewritten the disk in a loop. Then put the disk ahead of PXE and the virtual CD in the boot order. |
| First boot | cloud-init or Cloudbase-Init configures the system | Linux: `/var/log/cloud-init.log` and `/var/log/cloud-init-output.log`. Windows: `C:\Program Files\Cloudbase Solutions\Cloudbase-Init\log\cloudbase-init.log`. |
| Power off | MetalSoft marks the install finished | If the server never powers off, the first boot failed: read the logs above. If the screen stops after the kernel's first messages and the server never answers on the network, the boot may be waiting at an `(initramfs)` prompt on the serial console (cloud images send their boot to `console=ttyS0`): open it with the BMC's serial-over-LAN, for example `ipmitool -I lanplus -H <bmc> -U <user> sol activate`, and press Enter. |

Then power the server on and check the hostname, IP addresses, routes, DNS, SSH key login and the password
MetalSoft shows for the server.

| Error on the console | Cause |
|---|---|
| `Media #1 must have volume label CIDATA` | The `build_source_image` isn't MetalSoft's boot ISO, or `os.name` is `windows`, `rhel` or `redhat`. |
| `Unable to locate Media #2 / golden image` | The image ISO has no image file at the top level, or more than one. |
| `Unable to safely determine Media #2` | The image ISO isn't labeled `OSIMAGE`, and another CD, removable or USB device on the server also holds an image file. Label the ISO, or remove the other device. |
| `QCOW2 image detected` | Convert the image to raw (step 1). |
| `Image is larger than target disk` | The raw image is bigger than the chosen disk. A zstd image isn't checked in advance; writing it fails instead. |
| `(initramfs)` prompt on the serial console, after the reboot | The image's kernel found no root disk. Look for its storage driver's errors with `dmesg`: a missing driver, or kernel options the servers need that the image doesn't set (step 1). |

## Step 8: Change it later

### Replace a rendered file

```bash
TID=<template id>
AID=$(metalcloud-cli os-template get-assets $TID -f json | jq -r '.data[] | select(.file.name=="user-data") | .id')
jq -n --argjson tid "$TID" --arg content "$(base64 < user-data | tr -d '\n')" \
  '{templateId: $tid, usage: "build_component",
    file: {name: "user-data", path: "/user-data", mimeType: "text/plain",
           templatingEngine: true, contentBase64: $content}}' > asset.json
metalcloud-cli template-asset update $AID --config-source asset.json
```

### Ship a new image version

Package the new image under a new file name (step 3 explains why), then create a new template
from a copy of the directory with a new label and the new `secondary_image` name and URL. The old template
stays available for rollback. Archive it once it's no longer needed:

```bash
metalcloud-cli os-template set-status <old id> archived
```

### Publish

Once a test install passes, make the template public. The update replaces the whole template, so send
every field back and check `publish.json` before you run the update. Making it public in the UI does the
same thing.

```bash
metalcloud-cli os-template get $TID -f json \
  | jq '{template: ({name, description, label, device, install, imageBuild, os, tags, status} + {visibility: "public"})}' \
  > publish.json
metalcloud-cli os-template update $TID --config-source publish.json
```

<!-- BEGIN EXAMPLES: generated from linux-cloud-init/ and windows-cloudbase-init/; regenerate after changing them -->
## Appendix: Helper scripts

Two scripts do steps of this guide for you. They're next to this file in the repository.

| Script | Runs on | Does |
|---|---|---|
| `create-golden-template.sh` | bash on Linux, macOS, or WSL on Windows | steps 1 to 6: checks the image, compresses it (optional), packages it, uploads it with `scp` (optional), writes the template directory, checks it and creates the template |
| `create-golden-template.ps1` | Windows PowerShell 5.1 and PowerShell 7 | steps 4 to 6, for an image ISO you've already packaged and uploaded (`-ImageUrl`) |

Run either one in a terminal without options and it asks for everything it needs, checks each answer, shows a
summary with the same run as one command, and asks before changing anything. Options you give aren't asked
again; `--no-prompt` (`-NoPrompt`) never asks, for scripts and CI.

- **Controller check first:** before any question, the script checks that `metalcloud-cli` has an endpoint,
  that the controller accepts the API key, and that the CLI supports the controller's version. It says what to
  set when one is missing. A dry run only warns.
- **Template fields:** label, name, description, `os.name`, `os.version` and the boot ISO's URL, with defaults.
- **First-boot files:** the built-in examples (the same files as in [Example templates](#appendix-example-templates)),
  or your own `user-data`, `meta-data` and `network-config` (`--user-data`, `--meta-data`, `--network-config`;
  `-UserDataFile`, `-MetaDataFile`, `-NetworkConfigFile`). Any you don't give comes from the example. Your files
  are rendered for each server like the examples, and written as UTF-8 without a byte order mark and with LF line
  endings.
- **Template directory:** written to `golden-templates/golden/<os>/<label>/` in the current folder, after you
  confirm, or in the folder you name (`--templates-dir`, `-TemplatesDir`). `metalcloud-cli` reads every file
  under the folder it's given, so the scripts give it a temporary copy of the new template: your folder may
  hold anything else.
- **Dry run:** `--dry-run` (`-DryRun`) does everything except creating the template.
- **Not done:** testing (step 7) and publishing (step 8).

```bash
./create-golden-template.sh            # asks for everything
./create-golden-template.sh --no-prompt --os linux --label rocky-9-golden-v1 --image rocky-9.raw.zst \
    --url-base https://repo.example.com/images --upload me@repo.example.com:/var/www/images
```

```powershell
.\create-golden-template.ps1           # asks for everything
.\create-golden-template.ps1 -NoPrompt -OS windows -Label ws2025-golden-v1 -OSVersion 2025 `
    -ImageUrl https://repo.example.com/images/ws2025-golden-v1.raw.zst.iso
```

- **Tools:** both need `metalcloud-cli`. The bash script also needs `xorriso` to package, `zstd` for zstd images,
  `qemu-img` only to convert qcow2, VMDK or VHDX images, and `scp` and `curl` only to upload.
- **Help:** `./create-golden-template.sh --help`; `Get-Help .\create-golden-template.ps1 -Full`.
- **Windows:** if the execution policy blocks the script, run it as
  `powershell -ExecutionPolicy Bypass -File .\create-golden-template.ps1`. To check and package an image on
  Windows too, run the bash script in WSL, from WSL's own file system rather than `/mnt/c`, which is slow for
  large images.
- **CLI flags:** `MC_CLI` (bash) or `-Cli` (PowerShell) sets the `metalcloud-cli` command with any global flags,
  for example `metalcloud-cli -c <path to metalcloud.yaml>`.

## Appendix: Example templates

Both examples are complete. Save each file under the name shown, in a directory three levels below the
directory you pass to `--dir` (step 4), then change the fields step 4 lists. They are the same files as
`linux-cloud-init/` and `windows-cloudbase-init/` next to this guide.

### Linux (cloud-init)

#### `template.yaml`

```yaml
template:
  name: Linux golden image (cloud-init)
  label: linux-golden-image-cloud-init
  description: Writes a raw or zstd-compressed Linux disk image to the local disk; cloud-init configures it on first boot
  visibility: private
  device:
    architecture: x86_64
    bootmode: uefi
    type: server
  imagebuild:
    required: true
  install:
    drivetype: local_drive
    method: oob
    readymethod: wait_for_power_off
  os:
    # Must not be "windows", "rhel" or "redhat": the image builder picks its build method from this name
    name: linux-golden-image
    version: "1.0"
    credential:
      username: root
      passwordtype: generated
  tags:
    - golden-image
    - linux
templateassets:
  # Virtual media 1: MetalSoft's boot ISO (volume label CIDATA). The files below are added to it per server.
  - file:
      name: boot-golden-image.iso
      path: /boot-golden-image.iso
      mimetype: application/octet-stream
      url: https://repo.metalsoft.io/.iso/boot-golden-image.iso
      templatingengine: false
    usage: build_source_image
  # Virtual media 2: your image ISO (volume label OSIMAGE recommended, not required). Give every image version a new file name.
  - file:
      name: linux-golden-v1.raw.zst.iso
      path: /linux-golden-v1.raw.zst.iso
      mimetype: application/octet-stream
      url: https://repo.example.com/images/linux-golden-v1.raw.zst.iso
      templatingengine: false
    usage: secondary_image
  - file:
      name: user-data
      path: /user-data
      mimetype: text/plain
      templatingengine: true
    usage: build_component
  - file:
      name: meta-data
      path: /meta-data
      mimetype: text/plain
      templatingengine: true
    usage: build_component
  - file:
      name: network-config
      path: /network-config
      mimetype: text/plain
      templatingengine: true
    usage: build_component
```

#### `user-data`

Rendered for each server with the MetalSoft template language.

```text
#cloud-config
{#- First boot of the golden image. cloud-init reads this from the CIDATA boot ISO, which stays attached. -#}
{%- set si = serverInstance or {} %}
{%- set password = si.osCredentials.initialPasswordEncrypted if si.osCredentials else '' %}
{%- set keys = [] %}
{%- for key in (userSSHKeys or []) %}{% if key %}{% set keys = (keys.push(key), keys) %}{% endif %}{% endfor %}
{%- if managementSSHKey %}{% set keys = (keys.push(managementSSHKey), keys) %}{% endif %}
{%- set bonds = [] %}
{%- for interface in ((network.interfaces if network else []) or []) %}{% if interface.interfaceType == 'bond' %}{% set bonds = (bonds.push(interface), bonds) %}{% endif %}{% endfor %}

preserve_hostname: false
hostname: {{ (si.hostname or si.label or 'localhost') | dump | safe }}
{%- if si.provisionInstanceDnsRecords and si.fqdn %}
fqdn: {{ si.fqdn | dump | safe }}
prefer_fqdn_over_hostname: true
{%- else %}
prefer_fqdn_over_hostname: false
{%- endif %}
manage_etc_hosts: true
timezone: UTC

# Keep the image's default user (ubuntu, rocky, debian, cloud-user, ...) with the SSH keys.
# disable_root: false also puts the keys in root's authorized_keys.
users:
  - default
disable_root: false
{%- if keys | length %}
ssh_authorized_keys:
{%- for key in keys %}
  - {{ key | dump | safe }}
{%- endfor %}
{%- endif %}

{%- if password %}

# root gets the password MetalSoft generated for this server (needs cloud-init 22.3 or later)
chpasswd:
  expire: false
  users:
    - name: root
      password: {{ password | dump | safe }}
      type: text
{%- endif %}

# Grow the root partition and filesystem to the size of the disk
growpart:
  mode: auto
  devices: ["/"]
resize_rootfs: true

package_update: false
package_upgrade: false

runcmd:
  # Provisioning is one-shot. Without this, a distro whose cloud-init still runs after the
  # CIDATA ISO is removed may treat the server as a new instance and rewrite its network config.
  - [touch, /etc/cloud/cloud-init.disabled]
{#-
  Where cloud-init writes NetworkManager files (RHEL 10, SLES 16 and others), cloud-init 26.2 and earlier
  leave lacp_rate and xmit_hash_policy out of the bond (fixed upstream in cloud-init PR 6936). Set them
  with nmcli; they take effect from the next boot. Elsewhere the file test is false and nothing runs.
  The values match the ones in network-config.
-#}
{%- for bond in bonds %}
  {%- set parameters = bond.parameters or {} %}
  {%- set mode = bond.bondMode or parameters.mode or '802.3ad' %}
  {%- if mode == '802.3ad' or mode == 'balance-xor' %}
  {%- set name = 'bond' ~ bond.typeInterfaceId %}
  {%- set options = 'mode=' ~ mode ~ ',miimon=' ~ (parameters.miiMonitorInterval or 100) ~ ((',lacp_rate=' ~ (parameters.lacpRate or 'fast')) if mode == '802.3ad' else '') ~ ',xmit_hash_policy=' ~ (parameters.transmitHashPolicy or 'layer3+4') %}
  - {{ ("if [ -f /etc/NetworkManager/system-connections/cloud-init-" ~ name ~ ".nmconnection ]; then nmcli connection modify 'cloud-init " ~ name ~ "' bond.options '" ~ options ~ "'; fi") | dump | safe }}
  {%- endif %}
{%- endfor %}

# MetalSoft's wait_for_power_off finishes the deployment when the server powers off
power_state:
  mode: poweroff
  delay: now
  message: MetalSoft provisioning complete
  timeout: 300
  condition: true
```

#### `meta-data`

```text
{%- set si = serverInstance or {} -%}
instance-id: {{ ('metalsoft-' ~ (si.label or 'instance')) | dump | safe }}
local-hostname: {{ (si.hostname or si.label or 'localhost') | dump | safe }}
```

#### `network-config`

```text
{#-
  NoCloud network-config, version 2. Read on first boot by cloud-init (Linux) and by
  Cloudbase-Init 1.1.5 or later (Windows). Interfaces are matched by MAC address and named
  phy<N>, bond<N> and <parent>.<vlan id>.
-#}
{%- set dns = [] %}
{%- for server in ((siteConfig.DNSServers if siteConfig else []) or []) %}{% if server %}{% set dns = (dns.push(server), dns) %}{% endif %}{% endfor %}
{%- set physicals = [] %}
{%- set bonds = [] %}
{%- set vlans = [] %}
{%- for interface in ((network.interfaces if network else []) or []) %}
  {%- if interface.interfaceType == 'physical' %}{% set physicals = (physicals.push(interface), physicals) %}
  {%- elif interface.interfaceType == 'bond' %}{% set bonds = (bonds.push(interface), bonds) %}
  {%- elif interface.interfaceType == 'vlan' and interface.links and interface.links | length %}{% set vlans = (vlans.push(interface), vlans) %}
  {%- endif %}
{%- endfor %}

{%- macro linkName(link) -%}
{{ 'bond' if link.interfaceType == 'bond' else 'phy' }}{{ link.id }}
{%- endmacro %}

{%- macro layer3(interface) %}
    {%- if interface.mtu %}
    mtu: {{ interface.mtu }}
    {%- endif %}
    {%- set ipv4 = interface.ipv4Addresses or [] %}
    {%- set ipv6 = interface.ipv6Addresses or [] %}
    {%- if ipv4 | length or ipv6 | length %}
    addresses:
      {%- for address in ipv4 %}
      - {{ address.cidr }}
      {%- endfor %}
      {%- for address in ipv6 %}
      - {{ address.cidr }}
      {%- endfor %}
    {%- if ipv4 | length and dns | length %}
    nameservers:
      addresses:
        {%- for server in dns %}
        - {{ server }}
        {%- endfor %}
    {%- endif %}
    {%- elif interface.dhcp4 %}
    dhcp4: true
    {%- endif %}
    {%- if interface.routes and interface.routes | length %}
    routes:
      {%- for route in interface.routes %}
      - to: {{ route.to }}
        via: {{ route.via }}
        {%- if route.metric %}
        metric: {{ route.metric }}
        {%- endif %}
      {%- endfor %}
    {%- endif %}
{%- endmacro -%}
version: 2
{%- if physicals | length %}
ethernets:
  {%- for interface in physicals %}
  phy{{ interface.typeInterfaceId }}:
    match:
      macaddress: {{ (interface.macAddress | lower) | dump | safe }}
    set-name: phy{{ interface.typeInterfaceId }}
    {{- layer3(interface) }}
  {%- endfor %}
{%- endif %}
{%- if bonds | length %}
bonds:
  {%- for bond in bonds %}
  {%- set parameters = bond.parameters or {} %}
  {%- set mode = bond.bondMode or parameters.mode or '802.3ad' %}
  bond{{ bond.typeInterfaceId }}:
    interfaces:
      {%- for member in (bond.members or []) %}
      - {{ linkName(member) }}
      {%- endfor %}
    parameters:
      mode: {{ mode }}
      {%- if mode == '802.3ad' %}
      lacp-rate: {{ parameters.lacpRate or 'fast' }}
      {%- endif %}
      {%- if mode == '802.3ad' or mode == 'balance-xor' %}
      transmit-hash-policy: {{ parameters.transmitHashPolicy or 'layer3+4' }}
      {%- endif %}
      mii-monitor-interval: {{ parameters.miiMonitorInterval or 100 }}
    {{- layer3(bond) }}
  {%- endfor %}
{%- endif %}
{%- if vlans | length %}
vlans:
  {%- for vlan in vlans %}
  {{ linkName(vlan.links[0]) }}.{{ vlan.vlanId }}:
    id: {{ vlan.vlanId }}
    link: {{ linkName(vlan.links[0]) }}
    {{- layer3(vlan) }}
  {%- endfor %}
{%- endif %}
```

### Windows (Cloudbase-Init)

#### `template.yaml`

```yaml
template:
  name: Windows golden image (Cloudbase-Init)
  label: windows-golden-image-cloudbase-init
  description: Writes a raw or zstd-compressed sysprepped Windows disk image to the local disk; Cloudbase-Init configures it on first boot
  visibility: private
  device:
    architecture: x86_64
    bootmode: uefi
    type: server
  imagebuild:
    required: true
  install:
    drivetype: local_drive
    method: oob
    readymethod: wait_for_power_off
  os:
    # Must not be exactly "windows": that name makes the image builder rebuild the boot ISO as a
    # Windows installer ISO, but the boot ISO here is MetalSoft's Linux-based boot ISO
    name: windows-golden-image
    version: "2022"
    credential:
      username: Administrator
      passwordtype: generated
  tags:
    - golden-image
    - windows
templateassets:
  # Virtual media 1: MetalSoft's boot ISO (volume label CIDATA). The files below are added to it per server.
  - file:
      name: boot-golden-image.iso
      path: /boot-golden-image.iso
      mimetype: application/octet-stream
      url: https://repo.metalsoft.io/.iso/boot-golden-image.iso
      templatingengine: false
    usage: build_source_image
  # Virtual media 2: your image ISO (volume label OSIMAGE recommended, not required). Give every image version a new file name.
  - file:
      name: windows-2022-golden-v1.raw.zst.iso
      path: /windows-2022-golden-v1.raw.zst.iso
      mimetype: application/octet-stream
      url: https://repo.example.com/images/windows-2022-golden-v1.raw.zst.iso
      templatingengine: false
    usage: secondary_image
  - file:
      name: user-data
      path: /user-data
      mimetype: text/plain
      templatingengine: true
    usage: build_component
  - file:
      name: meta-data
      path: /meta-data
      mimetype: text/plain
      templatingengine: true
    usage: build_component
  # Network: network-config (version 2), read by Cloudbase-Init 1.1.5 or later
  - file:
      name: network-config
      path: /network-config
      mimetype: text/plain
      templatingengine: true
    usage: build_component
```

#### `user-data`

Rendered for each server with the MetalSoft template language.

```text
#ps1_sysnative
{#-
  First boot of the golden image. Cloudbase-Init's UserDataPlugin runs this once, reading it from the
  CIDATA boot ISO. Hostname (meta-data) and network (network-config) are applied by Cloudbase-Init itself.
-#}
{%- set si = serverInstance or {} %}
{%- set password = si.osCredentials.initialPasswordEncrypted if si.osCredentials else '' %}
{%- set keys = [] %}
{%- for key in (userSSHKeys or []) %}{% if key %}{% set keys = (keys.push(key), keys) %}{% endif %}{% endfor %}
{%- if managementSSHKey %}{% set keys = (keys.push(managementSSHKey), keys) %}{% endif %}
{%- set ntp = [] %}
{%- for server in ((siteConfig.NTPServers if siteConfig else []) or []) %}{% if server %}{% set ntp = (ntp.push(server), ntp) %}{% endif %}{% endfor %}
$ErrorActionPreference = 'Stop'

# The built-in Administrator account, found by its well-known SID (its name can be localized or renamed)
$admin = Get-LocalUser | Where-Object { $_.SID.Value -like 'S-1-5-*-500' }
{%- if password %}

# Administrator password: the one MetalSoft generated for this server
$password = ConvertTo-SecureString -String '{{ password | replace("'", "''") | safe }}' -AsPlainText -Force
Set-LocalUser -SID $admin.SID -Password $password -PasswordNeverExpires $true
Remove-Variable password
{%- endif %}
Enable-LocalUser -SID $admin.SID
{%- if keys | length %}

# SSH keys, only if OpenSSH Server is installed in the image
if (Get-Service -Name sshd -ErrorAction SilentlyContinue) {
    $keysFile = Join-Path $env:ProgramData 'ssh\administrators_authorized_keys'
    New-Item -ItemType Directory -Force -Path (Split-Path $keysFile) | Out-Null
    $keys = @(
{%- for key in keys %}
        '{{ key | replace("'", "''") | safe }}'
{%- endfor %}
    )
    Set-Content -Path $keysFile -Value $keys -Encoding ascii
    # Administrators and SYSTEM only, as OpenSSH requires; SIDs so localized group names don't matter
    icacls.exe $keysFile /inheritance:r /grant '*S-1-5-32-544:F' /grant '*S-1-5-18:F' | Out-Null
    Set-Service -Name sshd -StartupType Automatic
}
{%- endif %}
{%- if ntp | length %}

# Time servers
Set-Service -Name W32Time -StartupType Automatic
Start-Service -Name W32Time
w32tm.exe /config /manualpeerlist:"{{ ntp | join(' ') }}" /syncfromflags:manual /update | Out-Null
{%- endif %}

# Grow C: to the end of the disk. ExtendVolumesPlugin does this too when it's enabled; repeating it is harmless.
$cPartition = Get-Partition -DriveLetter C
$cMax = (Get-PartitionSupportedSize -DriveLetter C).SizeMax
if ($cMax -gt ($cPartition.Size + 1MB)) {
    Resize-Partition -DriveLetter C -Size $cMax
}

# Power off once Cloudbase-Init has finished, so MetalSoft's wait_for_power_off completes.
# Provisioning is one-shot: Cloudbase-Init is also stopped from running on later boots.
$conf = Join-Path $env:ProgramFiles 'Cloudbase Solutions\Cloudbase-Init\conf\cloudbase-init.conf'
$confLines = @(if (Test-Path $conf) { Get-Content -Path $conf })
$scriptsSetting = $confLines | Select-String -Pattern '^\s*local_scripts_path\s*=\s*(.+?)\s*$' | Select-Object -First 1
$pluginsSetting = $confLines | Select-String -Pattern '^\s*plugins\s*=\s*(.+?)\s*$' | Select-Object -First 1
# The default plugin list (no plugins= line) includes LocalScriptsPlugin
$localScriptsRuns = $scriptsSetting -and ((-not $pluginsSetting) -or
    ($pluginsSetting.Matches[0].Groups[1].Value -match 'LocalScriptsPlugin'))
if ($localScriptsRuns) {
    # LocalScriptsPlugin runs after every other plugin, so a script left in its folder now
    # powers the server off at the very end of this boot
    $localScripts = $scriptsSetting.Matches[0].Groups[1].Value
    New-Item -ItemType Directory -Force -Path $localScripts | Out-Null
    @'
# Written by the MetalSoft user-data on first boot.
sc.exe config cloudbase-init start= disabled | Out-Null
shutdown.exe /s /t 15 /f /d p:4:1 /c "MetalSoft provisioning complete"
exit 0
'@ | Set-Content -Path (Join-Path $localScripts '99-metalsoft-poweroff.ps1') -Encoding ascii
} else {
    # No LocalScriptsPlugin in this image: power off two minutes after this script returns,
    # which leaves Cloudbase-Init time to finish its remaining plugins and save its state
    sc.exe config cloudbase-init start= disabled | Out-Null
    shutdown.exe /s /t 120 /f /d p:4:1 /c "MetalSoft provisioning complete"
}

exit 0
```

#### `meta-data` and `network-config`

The same files as for Linux, above.

<!-- END EXAMPLES -->

## Appendix: How the boot ISO works

Read this if you want to change the boot ISO's script or build your own boot ISO.

### What's in it

`boot-golden-image.iso` is the stock [grml](https://grml.org) `grml-small-2026.04-amd64.iso` live system
with four changes:

| Change | Why |
|---|---|
| Volume label `CIDATA` | cloud-init and Cloudbase-Init find their NoCloud data by this label, and the script refuses to run without it. |
| `/scripts/grml.sh` (executable) | The deployment script. |
| `/bootparams/metalsoft`, containing `scripts` | grml reads every file in `/bootparams/` as extra boot parameters. The `scripts` boot parameter makes grml run `/scripts/grml.sh` once it has booted. |
| `/boot/grub/grmlsmallamd64_default.cfg` | Adds `intel_iommu=on iommu=pt` to the kernel command line. These apply only to the boot ISO's kernel: an image that needs them sets them itself (step 1). |

The BIOS and UEFI boot records are grml's own, unchanged. Stock grml already has the 20-second boot menu.

For each server, the image builder copies the ISO and adds `user-data`, `meta-data`, `network-config` and
any other `build_component` assets to its top level. grml mounts the ISO at `/run/live/medium`, where the
script reads them.

### What the script does

Everything it prints goes to the console and to `/var/log/metalsoft-deploy.log`. If any command fails,
the script stops with `MetalSoft deployment FAILED`, the reason, and the failing line and command.

1. **Reads `deployment.conf`** from the ISO if it's there (settings in [step 4](#step-4-write-the-template-directory)).
2. **Checks the boot ISO:** its label must be `CIDATA` (in any case), and `user-data` and `meta-data` must be
   present. `network-config` and `deployment.conf` are optional.
3. **Finds the image**, trying these in order:
   1. `SOURCE_DEVICE` from `deployment.conf`, read directly as the image.
   2. A volume labeled `OSIMAGE` (`IMAGE_LABEL`) holding exactly one image file at its top level (or the file
      named by `IMAGE_FILE`).
   3. Every CD, removable and USB device except the boot ISO. Exactly one of them may hold an image file.
   4. If there's exactly one removable or USB disk besides the boot ISO's, the whole device as the image (a
      raw or zstd image mounted directly, without an ISO). The script doesn't check what's on it. A zstd
      image used this way must be padded to a multiple of 512 bytes with a zstd skippable frame, because
      the device's trailing zeros would otherwise make zstd fail.

   Image files are `*.raw`, `*.img`, `*.raw.zst` or `*.img.zst`.
4. **Verifies the checksum** if `<image file>.sha256` is next to the image file.
5. **Detects the format** from the first four bytes: zstd, qcow2 (rejected), or anything else as raw. The
   file name doesn't matter.
6. **Picks the target disk** from the whole disks that aren't the boot ISO's or the image's device and
   aren't removable or USB. On a Dell server, the smallest disk whose model contains `BOSS`; otherwise the
   smallest disk. It stops if the disk has mounted filesystems, or if a raw image is larger than the disk.
7. **Wipes the disk** (`wipefs -a`, `sgdisk --zap-all`) and **writes the image** with `dd`, decompressing
   zstd on the fly.
8. **Moves the backup GPT** to the end of the disk (`sgdisk -e`) unless `REPAIR_GPT=false`. It doesn't
   resize partitions or filesystems; the OS does that on first boot.
9. **Creates a UEFI boot entry** for the disk's fallback loader (`\EFI\BOOT\BOOTX64.EFI`) with `efibootmgr`,
   first in the boot order, unless `CREATE_BOOT_ENTRY=false`. It deletes entries with the same label from
   earlier runs first. Without this entry, firmware can try PXE or the still-attached boot ISO before the new
   disk. On the first boot, Ubuntu's shim adds its own entry ahead of it.
10. **Reboots** after 3 seconds, unless `REBOOT_ON_SUCCESS=false`. The boot ISO stays attached for the first
    boot.

### Build your own boot ISO

You need `xorriso`. Both ways below keep grml's boot records (`-boot_image any replay`) and give the
result the `CIDATA` label.

**Change only the script**, starting from MetalSoft's boot ISO:

```bash
curl -LO https://repo.metalsoft.io/.iso/boot-golden-image.iso
xorriso -osirrox on -indev boot-golden-image.iso -extract /scripts/grml.sh grml.sh
chmod 755 grml.sh
# edit grml.sh
xorriso -indev boot-golden-image.iso -outdev my-boot-golden-image.iso \
  -map grml.sh /scripts/grml.sh \
  -boot_image any replay
```

**Build it from stock grml**, which is how MetalSoft's boot ISO is made:

```bash
curl -LO https://download.grml.org/grml-small-2026.04-amd64.iso
curl -LO https://download.grml.org/grml-small-2026.04-amd64.iso.sha256
sha256sum -c grml-small-2026.04-amd64.iso.sha256

chmod 755 grml.sh                      # the script must be executable
mkdir -p bootparams
printf 'scripts\n' > bootparams/metalsoft

# Optional: change the kernel command line
xorriso -osirrox on -indev grml-small-2026.04-amd64.iso \
  -extract /boot/grub/grmlsmallamd64_default.cfg grmlsmallamd64_default.cfg
chmod u+w grmlsmallamd64_default.cfg   # then edit its "linux" line

xorriso -indev grml-small-2026.04-amd64.iso -outdev boot-golden-image.iso \
  -volid CIDATA \
  -map grml.sh /scripts/grml.sh \
  -map bootparams/metalsoft /bootparams/metalsoft \
  -map grmlsmallamd64_default.cfg /boot/grub/grmlsmallamd64_default.cfg \
  -boot_image any replay
```

Leave out the `grmlsmallamd64_default.cfg` line if you don't change the kernel command line. With MetalSoft's
`grml.sh` and its `grmlsmallamd64_default.cfg`, this produces an ISO with the same files, label and boot
records as MetalSoft's.

To use your ISO, upload it with a new file name (step 3 explains why) and set its URL in the
`build_source_image` asset, or pass `--source-iso <url>` in step 6. Keep the template's `os.name` away from
`windows`, `rhel` and `redhat` (step 4), so the image builder adds the files without rebuilding the ISO.
