# VMware ESXi 9.1.0-0.25370933 Cluster Node Template

OS template for a VMware Cloud Foundation (VCF) **9.1.0.0** cluster node, based on
`VMware-VMvisor-Installer-9.1.0.0.25370933.x86_64.iso` (ESX 9.1.0.0 build 25370933, the VCF 9.1.0.0 BOM build).
Label: `esxi-9-25370933-cluster-node` — referenced by the `vmware-cloud-foundation9` extension
(`dependencies.osTemplates`) for `vcf_version=9.1.0.0`.

Derived from `../../9.0/esxi-9.0-24957456-cluster-node` (same kickstart, boot flow and credentials).

## Provenance

- ISO: `https://repo.metalsoft.io/.vmware/VMware-VMvisor-Installer-9.1.0.0.25370933.x86_64.iso` (692 MB, mirrored 2026-08-27).
- `BOOT.CFG` / `EFI-BOOT.CFG`: `modules=` and `build=` taken verbatim from the ISO's `EFI/BOOT/BOOT.CFG`
  (volume `ESXI-9.1.0-25370933-STANDARD`); only `kernelopt=ks=cdrom:/KS.CFG` differs from the stock file.
  The 9.1 module list is not the 9.0.1 one (`procfs` gone; `qat`, `nsx_head`, `nsx_scx` added) — do not copy
  boot configs between builds.
