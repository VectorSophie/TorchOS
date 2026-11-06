"""Regression tests for the installer configuration: only the tested path may be offered, the install
gate must run before anything touches a disk, and the boot-chain check must run after the bootloader.
The files are flat YAML; plain text parsing keeps these tests dependency-free."""
import os
import re
import unittest

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..")
CAL = os.path.join(ROOT, "image", "calamares", "etc", "calamares")


def read(*parts):
    with open(os.path.join(ROOT, *parts), encoding="utf-8") as f:
        return f.read()


def key(text, name):
    m = re.search(rf"^{name}:\s*(.+?)\s*$", text, re.M)
    return m.group(1) if m else None


def exec_sequence(settings):
    """Module instance names in the `- exec:` block, in order."""
    seq, inside = [], False
    for line in settings.splitlines():
        if re.match(r"^- (show|exec):", line):
            inside = line.startswith("- exec:")
            continue
        m = re.match(r"^  - (\S+)\s*$", line)
        if inside and m:
            seq.append(m.group(1))
        elif inside and line and not line.startswith(" "):
            inside = False
    return seq


class Partition(unittest.TestCase):
    conf = read("image", "calamares", "etc", "calamares", "modules", "partition.conf")

    def test_manual_partitioning_disabled(self):
        self.assertEqual(key(self.conf, "allowManualPartitioning"), "false")

    def test_encryption_disabled(self):
        self.assertEqual(key(self.conf, "enableLuksAutomatedPartitioning"), "false")

    def test_btrfs_only(self):
        self.assertEqual(key(self.conf, "defaultFileSystemType"), '"btrfs"')
        self.assertEqual(key(self.conf, "availableFileSystemTypes"), '[ "btrfs" ]')

    def test_erase_and_no_swap_partition(self):
        self.assertEqual(key(self.conf, "initialPartitioningChoice"), "erase")
        self.assertEqual(key(self.conf, "userSwapChoices"), "[ none ]")
        self.assertEqual(key(self.conf, "initialSwapChoice"), "none")


class Sequence(unittest.TestCase):
    settings = read("image", "calamares", "etc", "calamares", "settings.conf")

    def test_gate_runs_first_before_partition(self):
        seq = exec_sequence(self.settings)
        self.assertEqual(seq[0], "torchpreflight", seq)
        self.assertLess(seq.index("torchpreflight"), seq.index("partition"))

    def test_target_setup_before_boot_config(self):
        seq = exec_sequence(self.settings)
        self.assertLess(seq.index("shellprocess@setup"), seq.index("grubcfg"))
        self.assertLess(seq.index("grubcfg"), seq.index("bootloader"))

    def test_boot_chain_verified_after_bootloader_before_umount(self):
        seq = exec_sequence(self.settings)
        self.assertLess(seq.index("bootloader"), seq.index("shellprocess@verify"))
        self.assertLess(seq.index("shellprocess@verify"), seq.index("umount"))

    def test_gate_module_is_findable(self):
        self.assertIn("/usr/lib/torchos/calamares/modules", key(self.settings, "modules-search") or "")
        desc = read("image", "calamares", "usr", "lib", "torchos", "calamares", "modules", "torchpreflight",
                    "module.desc")
        self.assertRegex(desc, r'name:\s+"torchpreflight"')
        self.assertRegex(desc, r'interface:\s+"python"')

    def test_verify_instance(self):
        self.assertRegex(self.settings, r"- id: verify\n  module: shellprocess\n  config: shellprocess_verify.conf")
        conf = read("image", "calamares", "etc", "calamares", "modules", "shellprocess_verify.conf")
        self.assertEqual(key(conf, "dontChroot"), "true")
        self.assertIn("/usr/lib/torchos/torch-target-verify ${ROOT}", conf)


class Packaging(unittest.TestCase):
    pkgbuild = read("pkg", "torchos", "PKGBUILD")

    def test_installer_package_ships_gate_and_verifier(self):
        self.assertIn("/usr/lib/torchos/torch-target-verify", self.pkgbuild)
        self.assertIn("calamares/modules/torchpreflight/$f", self.pkgbuild)
        self.assertIn("for f in module.desc main.py", self.pkgbuild)


if __name__ == "__main__":
    unittest.main()
