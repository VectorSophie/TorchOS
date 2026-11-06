"""TorchOS install gate: the first job of the exec phase, before `partition` writes to any disk.

Only one installation path has been tested end to end: UEFI firmware, "Erase disk" on one whole disk,
Btrfs, no encryption, no swap partition. Everything else is rejected here, before anything is written.

Why a job and not just configuration: partition.conf hides most unsupported choices, but Calamares still
offers "Install alongside" / "Replace a partition" on disks that already hold an OS (there is no setting
to hide them), and it runs on BIOS machines too. Why this job cannot inspect the planned partitions:
Calamares fills GlobalStorage["partitions"] in FillGlobalStorageJob, which runs *after* the destructive
partition jobs. The show phase does store the choices below beforehand, and a failed job makes the job
queue skip every later non-emergency job, so a rejection here leaves every disk untouched.

GlobalStorage has no key for the file system picked on the "Erase disk" page (Config::setEraseFsTypeChoice keeps
it inside the partition module), and defaultFileSystemType is only the configured default. Calamares shows that
picker whenever partition.conf offers more than one type, so the gate also requires the offer itself to be Btrfs only.

The actual result is re-checked after partitioning by torch-target-setup (check_layout).
"""
import os
import re

try:
    import libcalamares
except ImportError:  # unit tests (image/tests/test_torchpreflight.py)
    libcalamares = None

PARTITION_CONF = "/etc/calamares/modules/partition.conf"
SUPPORTED = ("UEFI firmware, \"Erase disk\" on one whole disk, Btrfs, no encryption, no swap partition")


def pretty_name():
    return "Checking that this installation is supported"


def offered_filesystems(path=None):
    """availableFileSystemTypes from partition.conf as a list, or None if it cannot be read (flow-style list only)."""
    try:
        with open(path or PARTITION_CONF, encoding="utf-8") as f:
            m = re.search(r"^availableFileSystemTypes:\s*\[(.*)\]\s*$", f.read(), re.M)
    except OSError:
        return None
    return [t.strip().strip("\"'") for t in m.group(1).split(",") if t.strip()] if m else None


def problems(get, efi_firmware, offered_fs):
    """Reasons this installation must not start. `get(key)` returns a GlobalStorage value or None; `offered_fs` is
    what the "Erase disk" page lets the user pick (offered_filesystems()).

    Fails closed: a missing or unexpected value is a problem, not a pass."""
    found = []
    if not efi_firmware or get("firmwareType") != "efi":
        found.append("The installer was started in BIOS/legacy mode. TorchOS installs only in UEFI mode: "
                     "restart and pick the UEFI entry for the USB stick in the firmware boot menu.")
    choices = get("partitionChoices")
    if not isinstance(choices, dict):
        choices = {}
    install = choices.get("install")
    if install != "erase":
        found.append(f"Partitioning choice {install!r} is not supported yet: only \"Erase disk\" has been "
                     "tested. Alongside, replace and manual partitioning are disabled until they have tests.")
    swap = choices.get("swap")
    if swap != "none":
        found.append(f"Swap choice {swap!r} is not supported: TorchOS uses zram instead of a swap partition.")
    if get("luksPassphrase"):
        found.append("Disk encryption is not supported yet: no encrypted installation has been tested to "
                     "boot. Install without encryption.")
    fs = get("defaultFileSystemType")
    if fs != "btrfs" or offered_fs != ["btrfs"]:
        found.append(f"File system {fs!r} (offered: {offered_fs!r}) is not supported: snapshots and rollback need "
                     "Btrfs, and only Btrfs may be offered.")
    return found


def run():
    gs = libcalamares.globalstorage

    def get(key):
        return gs.value(key) if gs.contains(key) else None

    efi = os.path.isdir("/sys/firmware/efi")
    offered = offered_filesystems()
    # Never log the passphrase itself, only whether one was set.
    libcalamares.utils.debug(
        f"torchpreflight: /sys/firmware/efi={efi} firmwareType={get('firmwareType')!r} "
        f"partitionChoices={get('partitionChoices')!r} defaultFileSystemType={get('defaultFileSystemType')!r} "
        f"offered={offered!r} encryption={'yes' if get('luksPassphrase') else 'no'}")
    found = problems(get, efi, offered)
    if not found:
        libcalamares.utils.debug("torchpreflight: supported configuration")
        return None
    for p in found:
        libcalamares.utils.warning(f"torchpreflight: {p}")
    return ("TorchOS cannot install this configuration",
            "\n\n".join(found) + f"\n\nNothing on any disk has been changed. Supported: {SUPPORTED}.")
