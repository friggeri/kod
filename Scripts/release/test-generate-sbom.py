#!/usr/bin/env python3
"""Safe structural checks for the generated CycloneDX 1.5 SBOM."""

from __future__ import annotations

import json
import subprocess
import tempfile
import unittest
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
GENERATOR = REPO_ROOT / "Scripts" / "release" / "generate-sbom.py"


class GenerateSbomTests(unittest.TestCase):
    def test_license_paths_use_cyclonedx_properties(self) -> None:
        with tempfile.TemporaryDirectory(dir=REPO_ROOT / "Scripts" / "release") as temporary_dir:
            output = Path(temporary_dir) / "sbom.cdx.json"
            subprocess.run(["python3", str(GENERATOR), str(output)], check=True)
            sbom = json.loads(output.read_text())

        self.assertEqual(sbom["$schema"], "http://cyclonedx.org/schema/bom-1.5.schema.json")
        self.assertEqual(sbom["bomFormat"], "CycloneDX")
        self.assertEqual(sbom["specVersion"], "1.5")
        self.assertTrue(sbom["components"])
        self.assertTrue(all("licenseFile" not in component for component in sbom["components"]))
        self.assertTrue(
            all(
                any(property_["name"] == "kod:license-path" for property_ in component["properties"])
                for component in sbom["components"]
            )
        )


if __name__ == "__main__":
    unittest.main()
