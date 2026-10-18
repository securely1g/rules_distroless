"""Tests for declared package selection and interpreting real dpkg output."""

import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

from install import filesystem_paths, install, package_inventory, select_packages


class InstallTest(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)

    def manifest(self, content):
        path = self.root / "selection.json"
        path.write_text(json.dumps(content))
        return path

    def test_selection_can_preserve_base_packages(self):
        self.assertEqual(
            select_packages(["openssl.deb", "tcpdump.deb"], self.manifest(["tcpdump.deb"])),
            ["tcpdump.deb"],
        )

    def test_empty_selection(self):
        self.assertEqual(select_packages(["openssl.deb"], self.manifest([])), [])

    def test_rejects_undeclared_package(self):
        with self.assertRaisesRegex(ValueError, "undeclared"):
            select_packages(["hello.deb"], self.manifest(["/tmp/unreviewed.deb"]))

    def test_rejects_duplicate_package(self):
        with self.assertRaisesRegex(ValueError, "duplicate"):
            select_packages(["hello.deb"], self.manifest(["hello.deb", "hello.deb"]))

    def test_rejects_malformed_selection(self):
        for value in ({"packages": ["hello.deb"]}, [None], "hello.deb"):
            with self.subTest(value=value), self.assertRaisesRegex(ValueError, "JSON array"):
                select_packages(["hello.deb"], self.manifest(value))

    def test_inventory_preserves_multiarch_and_ignores_removed_packages(self):
        path = self.root / "packages.tsv"
        path.write_text("libc6:amd64\t2.41\tamd64\tinstalled\nhello\t2.10\tamd64\tconfig-files\n")
        self.assertEqual(package_inventory(path), {"libc6:amd64": {"version": "2.41", "architecture": "amd64"}})

    def test_inventory_rejects_unconfigured_packages(self):
        path = self.root / "packages.tsv"
        for status in ("unpacked", "half-configured", "triggers-pending", "triggers-awaited"):
            path.write_text(f"hello\t2.10\tamd64\t{status}\n")
            with self.subTest(status=status), self.assertRaisesRegex(ValueError, "was left"):
                package_inventory(path)

    def test_filesystem_walk_does_not_follow_absolute_symlinks(self):
        root = self.root / "root"
        root.mkdir()
        (root / "outside").symlink_to(self.root, target_is_directory=True)
        self.assertEqual(filesystem_paths(root), [root, root / "outside"])

    def test_rejects_unprivileged_worker_before_reading_inputs(self):
        with patch("install.os.geteuid", return_value=1000):
            with self.assertRaisesRegex(RuntimeError, "requires root"):
                install({})

    def test_rejects_foreign_architecture_before_reading_inputs(self):
        with patch("install.os.geteuid", return_value=0), patch("install.platform.machine", return_value="x86_64"):
            with self.assertRaisesRegex(RuntimeError, "native execution"):
                install({"architecture": "arm64"})

    def test_rejects_negative_timestamp_before_reading_inputs(self):
        with patch("install.os.geteuid", return_value=0), patch("install.platform.machine", return_value="x86_64"):
            with self.assertRaisesRegex(ValueError, "nonnegative"):
                install({"architecture": "amd64", "source_date_epoch": -1})


if __name__ == "__main__":
    unittest.main()
