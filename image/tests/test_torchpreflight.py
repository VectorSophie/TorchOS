"""Unit tests for the Calamares install gate (torchpreflight). Pure Python, no Calamares needed.

GlobalStorage shapes come from Calamares 3.4.2: partitionChoices is {"install": <installChoiceNames>,
"swap": <swapChoiceNames>} (partition/Config.cpp updateGlobalStorage), luksPassphrase is "" unless
encryption was confirmed on the partition page (ChoicePage::onLeave), firmwareType is "efi"/"bios".
"""
import importlib.util
import os
import tempfile
import unittest
from unittest import mock

HERE = os.path.dirname(os.path.abspath(__file__))
MAIN = os.path.join(HERE, "..", "calamares", "usr", "lib", "torchos", "calamares", "modules",
                    "torchpreflight", "main.py")
spec = importlib.util.spec_from_file_location("torchpreflight", MAIN)
assert spec and spec.loader
pf = importlib.util.module_from_spec(spec)
spec.loader.exec_module(pf)

SUPPORTED = {
    "firmwareType": "efi",
    "partitionChoices": {"install": "erase", "swap": "none"},
    "luksPassphrase": "",
    "defaultFileSystemType": "btrfs",
}


BTRFS_ONLY = ["btrfs"]
SHIPPED_PARTITION_CONF = os.path.join(HERE, "..", "calamares", "etc", "calamares", "modules", "partition.conf")


def with_(**changes):
    gs = dict(SUPPORTED)
    for k, v in changes.items():
        if v is None:
            gs.pop(k, None)
        else:
            gs[k] = v
    return gs


class Accepted(unittest.TestCase):
    def test_supported_configuration_passes(self):
        self.assertEqual(pf.problems(SUPPORTED.get, True, BTRFS_ONLY), [])


class Rejected(unittest.TestCase):
    def assertRejected(self, gs, efi=True, mentions="", offered=BTRFS_ONLY):
        found = pf.problems(gs.get, efi, offered)
        self.assertTrue(found, f"expected a rejection for {gs} efi={efi}")
        if mentions:
            self.assertTrue(any(mentions in p for p in found), found)

    def test_bios_firmware(self):
        self.assertRejected(with_(firmwareType="bios"), efi=False, mentions="UEFI")

    def test_bios_even_if_globalstorage_claims_efi(self):
        self.assertRejected(SUPPORTED, efi=False, mentions="UEFI")

    def test_missing_firmware_type(self):
        self.assertRejected(with_(firmwareType=None), mentions="UEFI")

    def test_non_erase_partitioning(self):
        for choice in ("alongside", "replace", "manual", "none", "nochoice"):
            with self.subTest(choice=choice):
                self.assertRejected(with_(partitionChoices={"install": choice, "swap": "none"}), mentions=choice)

    def test_missing_partition_choices_fails_closed(self):
        self.assertRejected(with_(partitionChoices=None))
        self.assertRejected(with_(partitionChoices="erase"))   # wrong type

    def test_swap_partition(self):
        for swap in ("small", "suspend", "file", "reuse"):
            with self.subTest(swap=swap):
                self.assertRejected(with_(partitionChoices={"install": "erase", "swap": swap}), mentions="zram")

    def test_encryption(self):
        self.assertRejected(with_(luksPassphrase="obscured-secret"), mentions="encryption")

    def test_non_btrfs(self):
        for fs in ("ext4", "xfs", "f2fs", "zfs"):
            with self.subTest(fs=fs):
                self.assertRejected(with_(defaultFileSystemType=fs), mentions="Btrfs")
        self.assertRejected(with_(defaultFileSystemType=None), mentions="Btrfs")

    def test_non_btrfs_offered_with_btrfs_default(self):
        # The user's pick on the "Erase disk" page never reaches GlobalStorage: defaultFileSystemType stays "btrfs"
        # even when ext4 is chosen, so offering anything else must be refused by itself.
        for offered in (["btrfs", "ext4"], ["ext4", "btrfs"], ["ext4"], [], None):
            with self.subTest(offered=offered):
                self.assertRejected(SUPPORTED, mentions="Btrfs", offered=offered)

    def test_every_problem_is_reported(self):
        gs = {"firmwareType": "bios", "partitionChoices": {"install": "manual", "swap": "small"},
              "luksPassphrase": "x", "defaultFileSystemType": "ext4"}
        self.assertEqual(len(pf.problems(gs.get, False, ["ext4"])), 5)


class OfferedFilesystems(unittest.TestCase):
    def parse(self, text):
        with tempfile.NamedTemporaryFile("w", suffix=".conf", delete=False) as f:
            f.write(text)
        try:
            return pf.offered_filesystems(f.name)
        finally:
            os.unlink(f.name)

    def test_shipped_partition_conf_offers_btrfs_only(self):
        self.assertEqual(pf.offered_filesystems(SHIPPED_PARTITION_CONF), ["btrfs"])

    def test_flow_lists(self):
        self.assertEqual(self.parse('availableFileSystemTypes: [ "btrfs", "ext4" ]\n'), ["btrfs", "ext4"])
        self.assertEqual(self.parse("availableFileSystemTypes: [btrfs]\n"), ["btrfs"])

    def test_unreadable_or_unparsed_fails_closed(self):
        self.assertIsNone(pf.offered_filesystems("/nonexistent/partition.conf"))
        self.assertIsNone(self.parse("defaultFileSystemType: btrfs\n"))
        self.assertIsNone(self.parse("availableFileSystemTypes:\n  - btrfs\n"))   # block list: not parsed, refused


class FakeStorage:
    def __init__(self, d):
        self.d = d

    def contains(self, k):
        return k in self.d

    def value(self, k):
        return self.d[k]


class FakeCalamares:
    def __init__(self, gs):
        self.globalstorage = FakeStorage(gs)
        self.log = []
        outer = self

        class utils:
            @staticmethod
            def debug(s):
                outer.log.append(s)

            @staticmethod
            def warning(s):
                outer.log.append(s)

        self.utils = utils


class Run(unittest.TestCase):
    def run_job(self, gs, efi):
        fake = FakeCalamares(gs)
        with mock.patch.object(pf, "libcalamares", fake), mock.patch.object(pf.os.path, "isdir", return_value=efi), \
                mock.patch.object(pf, "PARTITION_CONF", SHIPPED_PARTITION_CONF):
            return pf.run(), fake.log

    def test_supported_returns_none(self):
        result, _ = self.run_job(SUPPORTED, True)
        self.assertIsNone(result)

    def test_rejection_is_a_title_description_tuple(self):
        result, _ = self.run_job(with_(partitionChoices={"install": "alongside", "swap": "none"}), True)
        self.assertIsInstance(result, tuple)
        self.assertEqual(len(result), 2)
        self.assertIn("Nothing on any disk has been changed", result[1])

    def test_passphrase_is_never_logged(self):
        result, log = self.run_job(with_(luksPassphrase="hunter2-obscured"), True)
        self.assertIsNotNone(result)
        self.assertFalse(any("hunter2" in line for line in log), log)
        self.assertNotIn("hunter2", result[0] + result[1])


if __name__ == "__main__":
    unittest.main()
