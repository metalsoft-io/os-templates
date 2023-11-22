{%- if (drive_arrays and (drive_arrays | length)) or (shared_drives and (shared_drives | length)) %}
#!/bin/bash
{%- for interface in network_configuration.interfaces %}
{%- if interface.interface_type == 'physical' and interface.network_type == 'san' %}
iscsiadm -m iface -I san{{ interface.network_id }}{{ interface.type_interface_id }} --op=new
{%- endif %}
{%- endfor %}
{%- set multipath_enabled = false %}
{%- if drive_arrays and (drive_arrays | length) %}
{%- for drive in drive_arrays %}
{%- if drive.multipath %}
{%- set multipath_enabled = true %}
{%- endif %}
{%- if drive.targets and (drive.targets | length) %}
{%- for target in drive.targets %}
{%- if target.portals and (target.portals | length) %}
{%- for portal in target.portals %}
{%- if portal.ip_type == 'ipv6'  %}
iscsiadm -m discovery --type sendtargets --portal [{{ portal.ip }}]:3260
iscsiadm -m node --op=update -n node.conn[0].startup -v automatic
iscsiadm -m node --op=update -n node.startup -v automatic
iscsiadm --mode node --targetname {{ target.name }} --portal [{{ portal.ip }}]:3260 --login
{%- else %}
iscsiadm -m discovery --type sendtargets --portal {{ portal.ip }}:3260
iscsiadm -m node --op=update -n node.conn[0].startup -v automatic
iscsiadm -m node --op=update -n node.startup -v automatic
iscsiadm --mode node --targetname {{ target.name }} --portal {{ portal.ip }}:3260 --login
{%- endif %}
{%- endfor %}
{%- endif %}
{%- endfor %}
{%- endif %}
{%- endfor %}
{%- endif %}
{%- if shared_drives and (shared_drives | length) %}
{%- for drive in shared_drives %}
{%- if drive.multipath %}
{%- set multipath_enabled = true %}
{%- endif %}
{%- if drive.targets and (drive.targets | length) %}
{%- for target in drive.targets %}
{%- if target.portals and (target.portals | length) %}
{%- for portal in target.portals %}
{%- if portal.ip_type == 'ipv6'  %}
iscsiadm -m discovery --type sendtargets --portal [{{ portal.ip }}]:3260
iscsiadm -m node --op=update -n node.conn[0].startup -v automatic
iscsiadm -m node --op=update -n node.startup -v automatic
iscsiadm --mode node --targetname {{ target.name }} --portal [{{ portal.ip }}]:3260 --login
{%- else %}
iscsiadm -m discovery --type sendtargets --portal {{ portal.ip }}:3260
iscsiadm -m node --op=update -n node.conn[0].startup -v automatic
iscsiadm -m node --op=update -n node.startup -v automatic
iscsiadm --mode node --targetname {{ target.name }} --portal {{ portal.ip }}:3260 --login
{%- endif %}
{%- endfor %}
{%- endif %}
{%- endfor %}
{%- endif %}
{%- endfor %}
{%- endif %}
{%- endif %}
systemctl restart iscsid
echo > /etc/rc.local
