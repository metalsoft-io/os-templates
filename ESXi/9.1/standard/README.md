# VMware ESXi 9.1.0-0.25370933 Standard Template

General-purpose ESXi **9.1.0.0** (build 25370933) for a bare-metal server, from
`VMware-VMvisor-Installer-9.1.0.0.25370933.x86_64.iso`. Label: `esxi-9-25370933-standard`.

Same ISO and `EFI-BOOT.CFG` (→ `/EFI/BOOT/BOOT.CFG`) as `../esxi-9.1-25370933-cluster-node`, copied verbatim —
the module list is build-specific. UEFI only: the legacy-BIOS `/BOOT.CFG` and `/ISOLINUX.CFG` of the
cluster-node template are deliberately not shipped. Only `KS.CFG` differs in content.

## Differences from the VCF cluster-node kickstart

| | cluster-node (VCF) | standard |
| --- | --- | --- |
| Management interface | only if the first physical NIC is on a logical network named `vcf-mgmt` **and** a VLAN interface exists; otherwise no IP and `wait_for_ssh` never completes | the interface with the default gateway (else the first with an IPv4 address), on any logical network |
| Tagged / untagged | tagged only | both: `vlan` interface → `--vlanid` on its `links[0]` physical parent; `physical` interface → no VLAN |
| No IP allocated | no `network` line | DHCP |
| Uplinks | first physical NIC only | every physical NIC on the management logical network, all active |
| vSwitch0 MTU | forced 9000 | left at default (1500) — jumbo frames need matching switch config |
| `VM Network` VLAN | management VLAN | management VLAN (tagged case only) |
| Hostname | `label.dnsZoneName` | `serverInstance.fqdn`, else `label.dnsZoneName` |
| SSH key | `customVariables[pub_ssh_key]` (undefined variable — never matches), else `managementSSHKey` | `customVariables.pub_ssh_key`, else `managementSSHKey` |
| Root password | initial credentials, else a hard-coded fallback | initial credentials only |
| NTP | `/scratch/ntp.conf`, first server | `esxcli system ntp set`, all servers |
| DNS search domain | — | `dnsZoneName` |
| Host certificate | install-time (`localhost`) | regenerated for the FQDN at firstboot (`/sbin/generate-certificates`) |

Disk handling is unchanged: `clearpart --alldrives --overwritevmfs`, install to the first disk — **every local
disk is wiped**.

## Testing

- Kickstart rendered with Nunjucks 3.2.4 and with the controller's renderer
  (`POST /device-configuration-templates/config/actions/render`, identical output) against the
  `os-installation-data` of a deployed VCF node (tagged, two uplinks), an untagged two-NIC fixture and a
  no-network fixture.
- **Installed on hardware 2026-10-13, us06 (OS template id 20, infrastructure 308)**: two Dell R440s on the
  shared `internet-secondary` network (VLAN 3217, 192.168.72.0/24) — one connection untagged (instance 957,
  192.168.72.4), one tagged (instance 958, 192.168.72.6 on VLAN 3217). Both booted ESXi 9.1.0.0-25370933 with the
  static IP, passed `wait_for_ssh`, deploy finished in 41 min. The BIOS assets were removed after this run.
- **Post-install checks** (read-only, from the site controller `agent-vcf`): both hosts have the FQDN hostname,
  static `vmk0` with default route via 192.168.72.1, both X710 ports active on `vSwitch0` (MTU 1500),
  `Management Network` + `VM Network` on VLAN 3217 on the tagged host and VLAN 0 on the untagged one, DNS
  172.18.38.62 + search `us06.metalsoft.io`, NTP synchronised, host certificate CN/SAN = FQDN (reissued at first
  boot). No root `authorized_keys`: the controller rendered both SSH-key variables empty (same for the VCF
  template), so key login is not provisioned — password login works.
