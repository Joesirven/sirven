"""house style for the contract and everything under connectors/ride: no em or en dashes, and
terms spelled out. the same rule tests/unit/test_language.sh applies to the package, plus the
short forms this contract would be most tempted to use."""

import os
import re
import unittest

from helpers import HERE

RIDE_DIR = os.path.dirname(HERE)
REPO_DIR = os.path.dirname(os.path.dirname(RIDE_DIR))
ACRONYMS = re.compile(
    r"\b(ACLs?|OS|CLI|UID|GID|PID|TODO|FIXME|IP|DNS|UTC|ISO|PIN|OTP|VM|VPN|TCP|UDP|EOF|TTY|CPU|YAML|CI|UI|IDs?|OK"
    r"|MCP|RPC|RFC|ETA|PA|PII|PCI|SLA|MoR|KB|PR|SDK)\b|\be\.g\.|\bi\.e\."
)
DASHES = re.compile("[–—]")


def checked_files():
    yield os.path.join(REPO_DIR, "docs", "ride-connector-contract.md")
    for root, folders, files in os.walk(RIDE_DIR):
        folders[:] = [folder for folder in folders if folder != "__pycache__"]
        for name in files:
            if name.endswith((".py", ".json", ".md")) and name != "test_language.py":
                yield os.path.join(root, name)


class LanguageTests(unittest.TestCase):
    def scan(self, pattern):
        hits = []
        for path in checked_files():
            with open(path, encoding="utf-8") as handle:
                for number, line in enumerate(handle, start=1):
                    if pattern.search(line):
                        hits.append("%s:%d: %s" % (os.path.relpath(path, REPO_DIR), number, line.strip()))
        return hits

    def test_the_contract_document_exists(self):
        self.assertTrue(os.path.exists(os.path.join(REPO_DIR, "docs", "ride-connector-contract.md")))

    def test_no_em_or_en_dashes(self):
        self.assertEqual([], self.scan(DASHES))

    def test_no_acronyms(self):
        self.assertEqual([], self.scan(ACRONYMS))


if __name__ == "__main__":
    unittest.main()
