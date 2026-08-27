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
  - The pinned Sparkle Swift package used for application updates.

KodCore and KodUI keep their dependencies in-tree. The application additionally
pins Sparkle 2.9.6 in the Xcode project's Package.resolved file. License texts
for every shipped component are collected into the release image.

Usage: Scripts/release/generate-sbom.py <output-path.json>
"""
from __future__ import annotations

import json
import re
import subprocess
import sys
import uuid
from datetime import datetime, timezone
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]


def kod_version() -> str:
    pbxproj = (REPO_ROOT / "Kod.xcodeproj" / "project.pbxproj").read_text()
    versions = sorted(set(re.findall(r"MARKETING_VERSION = ([^;]+);", pbxproj)))
    if len(versions) != 1 or not versions[0].strip():
        raise SystemExit("BLOCKED: MARKETING_VERSION is missing or inconsistent.")
    return versions[0].strip()


def git_commit() -> str:
    try:
        commit = subprocess.run(
            ["git", "rev-parse", "HEAD"], cwd=str(REPO_ROOT), capture_output=True, text=True, check=True
        ).stdout.strip()
    except subprocess.CalledProcessError as error:
        raise SystemExit("BLOCKED: unable to resolve the release git commit.") from error
    if not re.fullmatch(r"[0-9a-f]{40}", commit):
        raise SystemExit(f"BLOCKED: unexpected git commit: {commit}")
    return commit


def load_json(path: Path) -> dict:
    return json.loads(path.read_text())


def require_file(relative: str) -> Path:
    path = REPO_ROOT / relative
    if not path.is_file():
        raise SystemExit(f"BLOCKED: required SBOM source is missing: {relative}")
    return path


def vendored_components() -> list[dict]:
    components = []
    search_roots = [
        REPO_ROOT / "Packages" / "KodCore" / "Sources",
        REPO_ROOT / "Packages" / "KodUI" / "Sources",
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
                "license_path": str(license_file.relative_to(REPO_ROOT)),
                "purl": None,
            })

    cmark_license = require_file("Packages/KodCore/Sources/CCMarkGFM/LICENSE-cmark-gfm.txt")
    cmark_manifest = load_json(require_file("Scripts/vendor-cmark-gfm/manifest.json"))
    components = [
        component
        for component in components
        if component["license_path"] != str(cmark_license.relative_to(REPO_ROOT))
    ]
    components.append({
        "name": "cmark-gfm",
        "type": "library",
        "version": cmark_manifest["version"],
        "license_path": str(cmark_license.relative_to(REPO_ROOT)),
        "purl": f"pkg:github/github/cmark-gfm@{cmark_manifest['commit']}",
    })

    for relative, name, version, purl in (
        (
            "Vendor/Licenses/pvc-theme-LICENSE.txt",
            "PVC color themes",
            "1.0.8",
            "pkg:github/friggeri/pvc-theme@43592b1ff36944cff69f8de973f96dcb5a901d91",
        ),
        (
            "Vendor/Licenses/material-icon-theme-LICENSE.txt",
            "Material Icon Theme",
            "5.37.0",
            "pkg:github/material-extensions/vscode-material-icon-theme@957d82b494e5737ef7b3c63e4d01f756d73a9936",
        ),
    ):
        require_file(relative)
        components.append({
            "name": name,
            "type": "data",
            "version": version,
            "license_path": relative,
            "licenses": [{"license": {"id": "MIT"}}],
            "purl": purl,
        })

    markdown_css_license = "Vendor/Licenses/github-markdown-css-LICENSE.txt"
    require_file(markdown_css_license)
    components.append({
        "name": "github-markdown-css",
        "type": "data",
        "version": "e49401776c9d581ad42367fc4ea3d677d13e2e39",
        "license_path": markdown_css_license,
        "purl": "pkg:github/sindresorhus/github-markdown-css@e49401776c9d581ad42367fc4ea3d677d13e2e39",
        "scope": "excluded",
        "properties": [{"name": "kod:usage", "value": "design-reference-only; CSS is not shipped or executed"}],
    })

    ripgrep_manifest = load_json(require_file("Scripts/vendor-ripgrep/manifest.json"))["ripgrep"]
    ripgrep_binary = require_file(ripgrep_manifest["targets"]["aarch64-apple-darwin"]["vendoredAt"])
    if not (ripgrep_binary.stat().st_mode & 0o111):
        raise SystemExit("BLOCKED: vendored ripgrep is not executable.")
    components.append({
        "name": "ripgrep",
        "type": "application",
        "version": ripgrep_manifest["tag"],
        "license_path": "Vendor/Licenses/ripgrep-LICENSE-MIT.txt",
        "purl": f"pkg:github/BurntSushi/ripgrep@{ripgrep_manifest['commit']}",
    })
    require_file("Vendor/Licenses/sparkle-LICENSE.txt")
    components.append({
        "name": "Sparkle",
        "type": "framework",
        "version": "2.9.6",
        "license_path": "Vendor/Licenses/sparkle-LICENSE.txt",
        "licenses": [{"license": {"id": "MIT"}}],
        "purl": "pkg:github/sparkle-project/Sparkle@2.9.6",
    })
    normalized_components = []
    for component in components:
        license_path = component.pop("license_path", None)
        if license_path is not None:
            properties = component.setdefault("properties", [])
            properties.append({"name": "kod:license-path", "value": license_path})
        normalized_components.append(
            {key: value for key, value in component.items() if value is not None}
        )
    return normalized_components


def main() -> int:
    output_path = Path(sys.argv[1]) if len(sys.argv) > 1 else REPO_ROOT / "Artifacts" / "release" / "sbom.json"
    output_path.parent.mkdir(parents=True, exist_ok=True)

    commit = git_commit()
    version = kod_version()
    serial = uuid.uuid5(
        uuid.NAMESPACE_URL,
        f"https://github.com/friggeri/kod@{commit}",
    )
    components = vendored_components()
    names = {component["name"] for component in components}
    for required_name in ("Sparkle", "ripgrep", "cmark-gfm"):
        if required_name not in names:
            print(f"BLOCKED: SBOM is missing required component {required_name}.", file=sys.stderr)
            return 65
    sparkle = next(component for component in components if component["name"] == "Sparkle")
    ripgrep = next(component for component in components if component["name"] == "ripgrep")
    if sparkle.get("version") != "2.9.6":
        print("BLOCKED: SBOM Sparkle version is not the pinned 2.9.6 release.", file=sys.stderr)
        return 65
    if ripgrep.get("version") != "14.1.1":
        print("BLOCKED: SBOM ripgrep version is not the pinned 14.1.1 release.", file=sys.stderr)
        return 65
    sbom = {
        "$schema": "http://cyclonedx.org/schema/bom-1.5.schema.json",
        "bomFormat": "CycloneDX",
        "specVersion": "1.5",
        "serialNumber": f"urn:uuid:{serial}",
        "version": 1,
        "metadata": {
            "timestamp": datetime.now(timezone.utc).isoformat(),
            "component": {
                "type": "application",
                "name": "Kod",
                "version": version,
                "description": "A native macOS application for reading and understanding local codebases (read-only).",
                "licenses": [{"license": {"id": "MIT"}}],
                "purl": f"pkg:github/friggeri/kod@{commit}",
            },
        },
        "components": components,
    }
    if (
        sbom["bomFormat"] != "CycloneDX"
        or sbom["specVersion"] != "1.5"
        or not sbom["components"]
        or any("licenseFile" in component for component in sbom["components"])
    ):
        print("BLOCKED: generated SBOM is not a valid CycloneDX document.", file=sys.stderr)
        return 65
    output_path.write_text(json.dumps(sbom, indent=2, sort_keys=True) + "\n")
    print(f"==> Wrote SBOM with {len(sbom['components'])} component(s) to {output_path}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
