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
| Tagged / untagged | tagged only | both: `vlan` interface → `--vlanid` on its `links[0]` parent (physical or bond); `physical` / `bond` interface → no VLAN |
| No IP allocated | no `network` line | DHCP |
| Uplinks | first physical NIC only | redundancy on (the platform sends a `bond`): every bond member, teamed by `bondMode` (below); no bond: only the management interface's own NIC, other NICs stay off `vSwitch0` |
| vSwitch0 MTU | forced 9000 | left at default (1500) — jumbo frames need matching switch config |
| `VM Network` VLAN | management VLAN | management VLAN (tagged case only) |
| Hostname | `label.dnsZoneName` | `serverInstance.fqdn`, else `label.dnsZoneName` |
| SSH key | `customVariables[pub_ssh_key]` (undefined variable — never matches), else `managementSSHKey` | `customVariables.pub_ssh_key`, else `managementSSHKey` |
| Root password | initial credentials, else a hard-coded fallback | initial credentials only |
| NTP | `/scratch/ntp.conf`, first server | `esxcli system ntp set`, all servers |
| DNS search domain | — | `dnsZoneName` |
| Host certificate | install-time (`localhost`) | regenerated for the FQDN at firstboot (`/sbin/generate-certificates`) |

## Redundancy

The kickstart follows the server's network connection. A connection with redundancy that the platform renders as a
`bond` interface (`members[].id` = physical `typeInterfaceId`s, as in the RHEL/SUSE templates) puts every member
on `vSwitch0`; the installer brings up the first member, firstboot adds the rest and sets the teaming:

| Bond `bondMode` (or `parameters.mode`) | ESXi |
| --- | --- |
| `802.3ad` (`link-aggregation` / `distributed-link-aggregation`) | only the first member on `vSwitch0`; the other members are link-down (`esxcli network nic down`) |
| `active-backup` (`server-only-bond`) | all members on `vSwitch0`, first active, the rest standby, route by originating port ID |
| `balance-xor` | all active, IP hash (static LAG) |
| anything else / none | all active, route by originating port ID |

Why LACP keeps one link: a standard vSwitch has no LACP. MetalSoft's port-channel has `fallback`, but on an MCLAG pair
the fallback forwards on **one** member and may pick either (after a link flap it can move to the second switch, and a
host with both NICs active on `vSwitch0` becomes unreachable while its console shows ESXi up).
Keeping one link up is only best effort: on the X710 (i40en) `esxcli network nic down` takes the NIC down in ESXi
but the switch still sees the port up, so the fallback can still move
to it. Full LACP needs a vSphere Distributed Switch LAG (vCenter).

**Use `server-only-bond` for ESXi** (standalone or vCenter-managed): MetalSoft sends `bondMode: "active-backup"` and
configures both switch ports as plain trunks of the VLAN, no port-channel, so ESXi alone decides which NIC carries
traffic.

Without a bond only the NIC under the management interface is used. A connection with `redundancy.mode` but no
`implementation` (e.g. `{"mode": "active-active"}`) is **not** rendered as a bond: the platform sends one VLAN
interface per NIC, each with its own IP, so the second NIC's IP stays allocated but unused.

With `{"mode": "active-active", "implementation": {"implementationType": "distributed-link-aggregation"}}` the
platform sends `{"interfaceType": "bond", "bondMode": "802.3ad", "members": [...]}` and builds an MCLAG
port-channel with `fallback` on the leaf pair. ESXi's standard vSwitch has no LACP, so the
host forwards on one member at a time (active/standby) and relies on that fallback.

Disk handling is unchanged: `clearpart --alldrives --overwritevmfs`, install to the first disk — **every local
disk is wiped**.

## Testing

- Kickstart rendered with Nunjucks and with the controller's renderer
  (`POST /device-configuration-templates/config/actions/render`, identical output) against the
  `os-installation-data` of a tagged two-uplink node, an untagged two-NIC fixture, a no-network fixture, and bond
  fixtures (`active-backup` tagged, `802.3ad` untagged, no mode tagged).
- Installed on hardware, tagged and untagged, without a bond and with each redundancy type:
  - `server-only-bond`: bond `active-backup`, both ports on `vSwitch0`, vmnic0 active / vmnic1 standby, one IP.
    Failover: `esxcli network nic down -n vmnic0` moves vmk0 to vmnic1 and `nic up` moves it back, with no pings
    lost.
  - `distributed-link-aggregation`: reachable while the MCLAG fallback stays on the first switch; see above for why
    it is not recommended.
- Post-install checks on each host: FQDN hostname, static `vmk0` with the default route, `Management Network` and
  `VM Network` on the management VLAN (VLAN 0 when untagged), DNS servers and search domain, NTP synchronised, host
  certificate CN/SAN = FQDN (reissued at first boot). The controller renders the SSH-key variables empty, so key
  login is not provisioned; password login works.
