# Known issues / verification status

Legend: VERIFIED = observed working in a VM this session; UNVERIFIED = written, not yet observed.

| area | status |
|---|---|
| `torchd` + `torch` CLI (snapshot/update/service via socket, systemd unit) | VERIFIED (Phase 1 VM) |
| `torch doctor/diagnose/gpu` typed output + exit codes | VERIFIED (host, unit tests) |
| Package manifests resolve against Arch repos | VERIFIED |
| TorchOS packages + wlogout + calamares build in Arch container | VERIFIED |
| Live ISO builds | see below |
| ISO boots (UEFI/OVMF) and renders the live desktop | UNVERIFIED |
| Calamares erase-disk install on blank disk | UNVERIFIED |
| Installed system boots without ISO | UNVERIFIED |
| Snapshot rollback across reboot; grub-btrfs menu; LTS fallback boot | UNVERIFIED |
| CachyOS kernel/repo | not included (decision 0001) |
| Secure Boot, LUKS, BIOS install, dual boot | unsupported / untested |
| Hosted package repo (installed systems can't update `torch-*` yet) | not built |
