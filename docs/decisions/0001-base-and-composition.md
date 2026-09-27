# 0001 - ISO composes from Arch repos, CachyOS is a later opt-in layer

**Status:** accepted 2026-09-21 (deviates from the locked spec's "CachyOS base"; recorded, not silent).
**Update 2026-09-27:** the opt-in layer exists: `torch kernel add linux-cachyos` (see *CachyOS layer* below).

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

## CachyOS layer (2026-09-27)

`torch kernel add linux-cachyos` (torchd op `kernel.install`, always asks for confirmation):
1. `snapper create` checkpoint (the `pacman.conf` edit happens outside snap-pac's pre/post pair);
2. import and locally sign the CachyOS key `F3B607488DB35A47` (keyserver.ubuntu.com);
3. append only the generic `[cachyos]` repo, **after** the Arch repos;
4. `pacman -Syu linux-cachyos cachyos-keyring`, then `grub-mkconfig`.

Why after, and why only `[cachyos]`: pacman takes a package from the first repo that has it, so Arch keeps
supplying pacman, glibc, mesa and everything else; only CachyOS-only packages (the kernel, its keyring) come
from CachyOS. The `x86-64-v3`/`v4`/`znver4` repos rebuild the whole base and would replace Arch packages
wholesale (including CachyOS's own pacman build, which its wiki warns about). Not adopted.

Verified in QEMU: installed, GRUB entry generated, boots `7.2.7-1-cachyos`, doctor green; the installed pacman
stayed Arch's build. The default boot entry stays `linux` (`GRUB_TOP_LEVEL`).

Hosted repo update: `[torchos]` is configured on installed systems and served from the GitHub release `repo`
(`image/scripts/sign-repo.sh`, `publish-repo.sh`); it goes live when published.
