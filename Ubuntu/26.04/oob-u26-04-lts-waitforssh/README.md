# Ubuntu 26.04 LTS - wait for SSH

Same as `oob-u26-04-lts-v7` (`ubuntu-26-04-lts`), except for the following:

- The autoinstall ends with `shutdown: "reboot"` instead of `poweroff`, so the server boots into the installed OS.
- `install.readymethod` is `wait_for_ssh` instead of `wait_for_power_off`, and `sshPort` is set to 22.

Use it for application extensions whose post-deploy Ansible tasks connect to the servers over SSH. Those tasks run before the platform powers the instance back on. With the power-off template, the servers are still off when the playbook starts, and it fails with `No route to host`.
