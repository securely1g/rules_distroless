"""Ensure the pre-build audit rejects DEB producers, including renamed output."""

import unittest

from validate import audit_graph


class ActionAuditTest(unittest.TestCase):
    def test_reading_existing_archive_is_allowed(self):
        audit_graph({"actions": [{"arguments": ["dpkg-deb", "--field", "hello.deb"]}]})

    def test_packaging_commands_are_rejected_without_deb_output(self):
        for command in (
            ["dpkg-deb", "--build", "root", "renamed.tar"],
            ["/bin/sh", "-c", "/usr/bin/dpkg-deb -Zxz -b root renamed.tar"],
            ["dpkg-buildpackage", "-b"],
            ["python3", "tools/package_deb.py", "--output=renamed.tar"],
        ):
            with self.subTest(command=command), self.assertRaises(ValueError):
                audit_graph({"actions": [{"arguments": command}]})

    def test_package_output_rejected_without_recognized_command(self):
        document = {
            "pathFragments": [{"id": 1, "label": "result.deb"}],
            "artifacts": [{"id": 2, "pathFragmentId": 1}],
            "actions": [{"arguments": ["custom_builder"], "outputIds": [2]}],
        }
        with self.assertRaises(ValueError):
            audit_graph(document)


if __name__ == "__main__":
    unittest.main()
