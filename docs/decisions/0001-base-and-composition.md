# 0001 - ISO composes from Arch repos, CachyOS is a later opt-in layer

**Status:** accepted 2026-09-21 (deviates from the locked spec's "CachyOS base"; recorded, not silent).

**Decision.** The live ISO and installed system take packages from official, signed Arch repos plus a
local `torchos` repo (our packages + reviewed AUR builds). Kernels: `linux` and `linux-lts`; the LTS
kernel is the built-in fallback.

**Why.** Bootstrapping CachyOS's keyring and its per-CPU-level repos inside an unattended container
build is the riskiest step in the chain and the least documented. Getting a bootable, installable
system first is worth more than kernel tuning. `os-release` says `ID_LIKE=arch` - honest lineage.

**Consequences.** No `linux-cachyos`, no sched-ext, no CachyOS-specific packages yet. Re-adding the
CachyOS repo is a `pacman.conf` + keyring change plus a rebuild, tracked in known-issues.
The local `torchos` repo is build-time only; installed systems get TorchOS package updates only once
a hosted repo exists (known limitation).
