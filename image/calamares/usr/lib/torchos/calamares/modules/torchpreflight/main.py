"""TorchOS install gate: the first job of the exec phase, before `partition` writes to any disk.

Only one installation path has been tested end to end: UEFI firmware, "Erase disk" on one whole disk,
Btrfs, no encryption, no swap partition. Everything else is rejected here, before anything is written.

Why a job and not just configuration: partition.conf hides most unsupported choices, but Calamares still
offers "Install alongside" / "Replace a partition" on disks that already hold an OS (there is no setting
to hide them), and it runs on BIOS machines too. Why this job cannot inspect the planned partitions:
Calamares fills GlobalStorage["partitions"] in FillGlobalStorageJob, which runs *after* the destructive
partition jobs. The show phase does store the choices below beforehand, and a failed job makes the job
queue skip every later non-emergency job, so a rejection here leaves every disk untouched.

The actual result is re-checked after partitioning by torch-target-setup (check_layout).
"""
import os

try:
    import libcalamares
except ImportError:  # unit tests (image/tests/test_torchpreflight.py)
    libcalamares = None

SUPPORTED = ("UEFI firmware, \"Erase disk\" on one whole disk, Btrfs, no encryption, no swap partition")


def pretty_name():
    return "Checking that this installation is supported"


def problems(get, efi_firmware):
    """Reasons this installation must not start. `get(key)` returns a GlobalStorage value or None.

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
    if fs != "btrfs":
        found.append(f"File system {fs!r} is not supported: snapshots and rollback need Btrfs.")
    return found


def run():
    gs = libcalamares.globalstorage

    def get(key):
        return gs.value(key) if gs.contains(key) else None

    efi = os.path.isdir("/sys/firmware/efi")
    # Never log the passphrase itself, only whether one was set.
    libcalamares.utils.debug(
        f"torchpreflight: /sys/firmware/efi={efi} firmwareType={get('firmwareType')!r} "
        f"partitionChoices={get('partitionChoices')!r} defaultFileSystemType={get('defaultFileSystemType')!r} "
        f"encryption={'yes' if get('luksPassphrase') else 'no'}")
    found = problems(get, efi)
    if not found:
        libcalamares.utils.debug("torchpreflight: supported configuration")
        return None
    for p in found:
        libcalamares.utils.warning(f"torchpreflight: {p}")
    return ("TorchOS cannot install this configuration",
            "\n\n".join(found) + f"\n\nNothing on any disk has been changed. Supported: {SUPPORTED}.")
