# Nutanix Community Edition 2.1 Cluster Node Template

OS template for an unattended **Nutanix Community Edition (CE) 2.1** node install: AOS 6.8.1 with the
AHV 20230302 hypervisor, from `phoenix.x86_64-fnd_5.6.1_patch-aos_6.8.1_ga.iso`.
Label: `nutanix-ce-2-1-cluster-node`. It is used by the `nutanix-ce` extension
(`metalsoft-extensions/nutanix-ce`), which turns 1, 3 or 4 of these nodes into a Nutanix cluster.

**Lab and evaluation use only.** CE is unlicensed, community-supported, and limited to 4 nodes. It is not
supported for production. The binaries are Nutanix property under the CE EULA, so keep the hosted copies
on an internal or access-controlled path.

## What it does

The template installs AHV on the node and puts the CVM (Controller VM) on it, with no keyboard input.
It does **not** create a cluster, and the CVM is left **without an external IP**. Both are done by the
extension after install, because the platform doesn't know the CVM address when the ISO is built.

1. The platform builds a per-instance ISO: the stock CE ISO plus two template assets.
   - `/EFI/BOOT/grub.cfg` replaces the ISO's boot menu with a single `CEInstaller` entry.
   - `/post_phoenix.sh` is a boot-order fix, described under "Boot order".
2. `grub.cfg` passes the installer (phoenix) its network settings and its answer file on the kernel line.
   - Network: `PHOENIX_IP`/`MASK`/`GATEWAY`/`NAMESERVER`, the node's host IP.
   - Answer file: `AZ_CONF_URL=data:,<url-encoded JSON>`. This is phoenix's unattended "Arizona" mode,
     so no web server or DHCP is needed for the answer file.
3. The installer downloads the AOS package and the AHV ISO over HTTPS and checks their MD5 sums. It
   then installs AHV on the hypervisor disk, deploys the CVM on the CVM disks, runs the `post_phoenix`
   hook and reboots.
4. AHV's first boot defines and starts the CVM, which takes 15–20 minutes. The template's ready method is
   `wait_for_ssh`, so the platform considers the node ready once AHV answers on port 22.

Default credentials (CE factory defaults, also set in `template.yaml`): AHV `root` / `nutanix/4u`,
CVM `nutanix` / `nutanix/4u`. The extension changes the Prism `admin` password; it does not change these.

## Files

| File | Purpose |
|---|---|
| `template.yaml` | Template definition: UEFI, out-of-band (virtual media) install, local drive, `wait_for_ssh`. |
| `grub.cfg` | Templated boot menu that builds the answer file (see "Answer file"). |
| `post_phoenix.sh` | Run by the installer right before its final reboot; fixes the UEFI boot order. |

`post_phoenix.sh` is marked `templatingengine: true` although nothing in it is templated, and wraps itself
in `{% raw %}` / `{% endraw %}` inside bash comments. Image builds only encrypt rendered text assets; a
non-templated text asset fails the build with "Invalid encrypted data. It must contain encryption metadata
delimiter." Keep the wrapper until that is fixed.

## Hosted files

These are expected under `https://repo.metalsoft.io/.nutanix/ce-2.1/`:

| File | Size | MD5 | Used as |
|---|---|---|---|
| `phoenix.x86_64-fnd_5.6.1_patch-aos_6.8.1_ga.iso` | 7,123,425,280 | `0e7c800b46986c84d4fcdae92e73dc53` | Source ISO (`build_source_image`) |
| `nutanix_installer_package.tar` | 4,687,655,614 | `c2cf84ceae79b9aef945bbb5386f790f` | AOS, downloaded by the installer |
| `AHV-DVD-x86_64-el8.nutanix.20230302.101026.iso.iso` | 1,562,918,912 | `d83f73ac1f444ddba3825d335daf908a` | AHV, downloaded by the installer |

The double `.iso.iso` is the real file name. The ISO comes from the Nutanix community portal after
[registering for CE](https://www.nutanix.com/products/community-edition/register) (NEXT account); the
direct link is `https://download.nutanix.com/ce/2024.08.19/phoenix.x86_64-fnd_5.6.1_patch-aos_6.8.1_ga.iso`.
In unattended mode the installer does not read the AOS and AHV images from the attached ISO, so they are
extracted from it and hosted separately:

```bash
xorriso -osirrox on -indev phoenix.x86_64-fnd_5.6.1_patch-aos_6.8.1_ga.iso \
  -extract /images/svm svm -extract /images/hypervisor/kvm kvm
cat svm/nutanix_installer_package.tar.p00 svm/nutanix_installer_package.tar.p01 > nutanix_installer_package.tar
cp kvm/AHV-DVD-x86_64-el8.nutanix.20230302.101026.iso.iso .
md5sum phoenix.x86_64-fnd_5.6.1_patch-aos_6.8.1_ga.iso nutanix_installer_package.tar AHV-DVD-*.iso.iso
```

To host them elsewhere (for example a site-local mirror; each node downloads about 6.2 GB), change the
URL in `template.yaml` and the `aos` / `ahv` URLs in `grub.cfg`.

## Answer file

Built in `grub.cfg` from the platform's template context:

| Answer-file field | Source |
|---|---|
| `host_ip`, `host_subnet_mask`, `default_gw` | The interface with the default gateway (else the first with an IPv4 address) |
| `dns_ip`, `NAMESERVER` | Site config `DNSServers` |
| `hypervisor_hostname`, `block_id` | `serverInstance.label` |
| `vswitches` (`br0`, `active-backup`) | MACs of the physical NICs on the management network |
| `ce_hyp_boot_disk`, `ce_cvm_boot_disks`, `ce_cvm_data_disks` | Custom variables, default `sda` / `sdb` / `sdc` |
| `svm_ip`, `svm_subnet_mask`, `svm_default_gw` | Always `""`: the CVM gets its IP from the extension |
| `svm_installer_url`, `hypervisor_iso_url` | `{url, md5sum}` objects for the hosted files |
| `hook_scripts.post_phoenix` | Mounts the installer ISO and runs `/post_phoenix.sh` |

Constraints that are easy to break when editing `grub.cfg`:
- The installer's command-line parser rejects `=` and spaces in values, so the JSON is URL-encoded.
- GRUB adds a backslash before every `\`, `'` and `"` in kernel arguments, which corrupts the JSON.
  The template therefore also encodes `'` as `%27`.
- `hypervisor_iso_url` and `svm_installer_url` must be `{url, md5sum}` objects, not strings.
- CE's validation calls `len()` on all six host and CVM network fields, so the CVM ones must be present
  as `""` rather than omitted.
- The kernel command line is limited to 2048 bytes and this template uses about 1850, so there is little
  room for more fields.
- `vswitches` matters: without it, AHV bonds every NIC, and active-backup can pick an unwired port.

### Disk layout

Defaults: `sda` for AHV, `sdb` for the CVM boot disk, `sdc` for data, which matches a server with three
disks on one controller. For another layout, set custom variables on the **server instance group** (or
a server instance). Custom variables on an extension's instance array only reach Ansible, not this
template.

| Custom variable | Example | Meaning |
|---|---|---|
| `ce_hyp_boot_disk` | `sda` | AHV boot disk (at least 32 GB) |
| `ce_cvm_boot_disks` | `nvme0n1` | CVM boot SSD(s), comma-separated, 1 or 2 (at least 200 GB) |
| `ce_cvm_data_disks` | `sdb,sdc` | Data disks, comma-separated (at least 200 GB each) |

Values are kernel device names as the installer sees them. Check them with
`lsblk -d -o NAME,SIZE,ROTA,MODEL` from a live ISO with the virtual CD attached (virtual media can shift
`sdX` names). Always set the AHV disk explicitly: with equal-size disks, the installer's own pick may be a
CVM disk.

## Boot order

The installer only creates a UEFI boot entry for AHV on hardware layouts it recognises (Dell, iLO, Intel),
not in CE mode. The platform keeps the virtual CD attached until SSH answers, so without a fix the server
boots the installer again and reinstalls in a loop. Each pass also leaves a stale "Nutanix AHV" entry,
and enough of them (20 on one R440) push the valid entry behind "Virtual Optical Drive".

`post_phoenix.sh` handles this on any hardware:
1. It finds the AHV disk by its loader (`EFI/centos/shimx64.efi` on partition 1 of sd, nvme, vd or mmcblk
   devices).
2. It deletes every "Nutanix AHV" entry and creates a new one first in `BootOrder`.
3. It sets `BootNext` to the new entry.

It does nothing on non-UEFI servers. Its output is on the installer console.

## Requirements

- **Firmware:** UEFI boot, Secure Boot off, BIOS clock correct.
- **CPU and memory:** x86_64 with VT-x / AMD-V, at least 4 cores, at least 32 GB RAM (64 GB
  recommended). The installer stages its downloads in RAM, so servers with 8 GB fail.
- **Disks:** at least 3, presented raw (AHCI or HBA / IT mode, no RAID volumes; HPE Smart Array in HBA
  mode).
- **Network:**
  - untagged (native VLAN), because the installer can't tag;
  - not in `192.168.5.0/24`, which Nutanix uses internally;
  - outbound HTTPS to the hosted files, and to the internet for cluster creation and the first Prism login.
- **Platform:** a site config with `DNSServers`.

## Register

```bash
metalcloud-cli os-template create-from-repo Nutanix/CE-2.1/cluster-node --repo-url ~/mcli/os-templates
```

The `nutanix-ce` extension finds the template by its label, so keep `nutanix-ce-2-1-cluster-node` (or
pick the template explicitly in the extension's `node_os_template` input).

## Tested

Dell PowerEdge R440, 3 disks, through the `nutanix-ce` extension:
- 1-, 3- and 4-node clusters built

## Using it without the extension

Deploying the template alone gives AHV hosts with a running CVM that has only a link-local address and no
cluster. To finish by hand:
1. On each AHV host, log in to the CVM (`ssh -i /root/firstboot/ssh_keys/nutanix nutanix@192.168.5.254`).
2. Give it a static IP in `/etc/sysconfig/network-scripts/ifcfg-eth0`, then run `ifdown eth0; ifup eth0`
   and `genesis restart`.
3. From one CVM, run `cluster -s <cvm ips> create`.

## Troubleshooting

| Where | What to check |
|---|---|
| Installer console | The installer runs in a `screen` session. A Python traceback means an answer-file problem. A fresh "Copying squashfs.img" after an install means the boot loop described under "Boot order". |
| AHV host | `systemctl status ahv-define-cvm ahv-install-cvm ahv-configure-cvm ahv-status-cvm` and `virsh list --all`. `ahv_first_boot.service` failing with `python: No such file` is expected on AHV 20230302 and harmless. |
| CVM | `cluster status`, `ncli cluster info`, logs in `~/data/logs/` (`genesis.out`). |
| Boot loop on a node | Pick the local disk in the one-time boot menu (F11 on Dell) after the install. To clean up, delete the stale "Nutanix AHV" / "Unavailable" entries (Dell: F11 → One-Shot UEFI Boot Menu → Delete Boot Option). |
