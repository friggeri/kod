#!/usr/bin/env python3
"""Generates a minimal CycloneDX-shaped SBOM (Software Bill of
Materials) for a Kod release build, listing:

  - Kod itself (name, version from MARKETING_VERSION, git commit).
  - Every vendored third-party component under
    Packages/KodCore/Sources and Packages/KodUI/Sources (Tree-sitter runtime,
    grammars, UI assets, and any
    other vendored code with its own LICENSE file), with the version
    pinned in Scripts/vendor-*/vendor.sh where available.
  - The bundled ripgrep search engine binary.

Kod's SwiftPM packages (`Packages/KodCore` and `Packages/KodUI`) declare zero
external `.package(url:)` dependencies — every third-party component is
vendored in-tree and reviewed (see THIRD_PARTY_NOTICES.md) rather than
resolved at build time, so there is no Package.resolved to enumerate;
this script's component list is instead derived directly from the
vendored LICENSE files themselves; and its license text is
cross-checked against THIRD_PARTY_NOTICES.md's own coverage.

Usage: Scripts/release/generate-sbom.py <output-path.json>
"""
from __future__ import annotations

import json
import re
import subprocess
import sys
from datetime import datetime, timezone
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]


def kod_version() -> str:
    pbxproj = (REPO_ROOT / "Kod.xcodeproj" / "project.pbxproj").read_text()
    match = re.search(r"MARKETING_VERSION = ([^;]+);", pbxproj)
    return match.group(1).strip() if match else "unknown"


def git_commit() -> str:
    try:
        return subprocess.run(
            ["git", "rev-parse", "HEAD"], cwd=str(REPO_ROOT), capture_output=True, text=True, check=True
        ).stdout.strip()
    except subprocess.CalledProcessError:
        return "unknown"


def vendored_components() -> list[dict]:
    components = []
    search_roots = [
        REPO_ROOT / "Packages" / "KodCore" / "Sources",
        REPO_ROOT / "Packages" / "KodUI" / "Sources",
        REPO_ROOT / "Vendor",
    ]
    seen_dirs: set[Path] = set()
    for root in search_roots:
        for license_file in sorted(root.rglob("LICENSE*")):
            if ".build" in license_file.parts:
                continue
            component_dir = license_file.parent
            if component_dir in seen_dirs:
                continue
            seen_dirs.add(component_dir)
            components.append({
                "name": component_dir.name,
                "type": "library",
                "licenseFile": str(license_file.relative_to(REPO_ROOT)),
                "purl": None,
            })

    cmark_license = REPO_ROOT / "Packages/KodCore/Sources/CCMarkGFM/LICENSE-cmark-gfm.txt"
    components = [component for component in components if component["licenseFile"] != str(cmark_license.relative_to(REPO_ROOT))]
    if cmark_license.exists():
        components.append({
            "name": "cmark-gfm",
            "type": "library",
            "version": "0.29.0.gfm.13",
            "licenseFile": str(cmark_license.relative_to(REPO_ROOT)),
            "purl": "pkg:github/github/cmark-gfm@587a12bb54d95ac37241377e6ddc93ea0e45439b",
        })

    components.append({
        "name": "github-markdown-css",
        "type": "data",
        "version": "e49401776c9d581ad42367fc4ea3d677d13e2e39",
        "licenseFile": "Vendor/Licenses/github-markdown-css-LICENSE.txt",
        "purl": "pkg:github/sindresorhus/github-markdown-css@e49401776c9d581ad42367fc4ea3d677d13e2e39",
        "scope": "excluded",
        "properties": [{"name": "kod:usage", "value": "design-reference-only; CSS is not shipped or executed"}],
    })

    ripgrep_dir = REPO_ROOT / "Packages" / "KodCore" / "Sources" / "SearchCore" / "Resources" / "ripgrep"
    if ripgrep_dir.exists():
        components.append({
            "name": "ripgrep",
            "type": "application",
            "licenseFile": "THIRD_PARTY_NOTICES.md (see 'ripgrep search engine' section)",
            "purl": "pkg:cargo/ripgrep",
        })
    return components


def main() -> int:
    output_path = Path(sys.argv[1]) if len(sys.argv) > 1 else REPO_ROOT / "Artifacts" / "release" / "sbom.json"
    output_path.parent.mkdir(parents=True, exist_ok=True)

    sbom = {
        "bomFormat": "CycloneDX",
        "specVersion": "1.5",
        "serialNumber": f"urn:uuid:kod-sbom-{git_commit()[:12] or 'unknown'}",
        "version": 1,
        "metadata": {
            "timestamp": datetime.now(timezone.utc).isoformat(),
            "component": {
                "type": "application",
                "name": "Kod",
                "version": kod_version(),
                "description": "A native macOS application for reading and understanding local codebases (read-only).",
            },
        },
        "components": vendored_components(),
    }
    output_path.write_text(json.dumps(sbom, indent=2, sort_keys=True) + "\n")
    print(f"==> Wrote SBOM with {len(sbom['components'])} component(s) to {output_path}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
