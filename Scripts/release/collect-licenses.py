#!/usr/bin/env python3
"""Collect every shipped license into a release staging directory."""

from __future__ import annotations

import shutil
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
LICENSE_ROOTS = (
    REPO_ROOT / "Vendor" / "Licenses",
    REPO_ROOT / "Packages" / "KodCore" / "Sources",
    REPO_ROOT / "Packages" / "KodUI" / "Sources",
)


REQUIRED_LICENSES = (
    Path("Vendor/Licenses/sparkle-LICENSE.txt"),
    Path("Vendor/Licenses/ripgrep-LICENSE-MIT.txt"),
    Path("Vendor/Licenses/ripgrep-UNLICENSE.txt"),
    Path("Vendor/Licenses/ripgrep-COPYING.txt"),
    Path("Vendor/Licenses/pvc-theme-LICENSE.txt"),
    Path("Vendor/Licenses/material-icon-theme-LICENSE.txt"),
    Path("Packages/KodCore/Sources/CCMarkGFM/LICENSE-cmark-gfm.txt"),
    Path("Packages/KodCore/Sources/CTreeSitter/LICENSE-tree-sitter.txt"),
)


IGNORED_LICENSE_SUFFIXES = {".svg", ".png", ".jpg", ".jpeg", ".webp", ".gif", ".icns", ".pdf"}


def is_license(path: Path) -> bool:
    if not path.is_file() or path.suffix.lower() in IGNORED_LICENSE_SUFFIXES:
        return False
    name = path.name.lower()
    return "license" in name or "copying" in name


def main() -> int:
    if len(sys.argv) != 2:
        print(f"Usage: {sys.argv[0]} <destination>", file=sys.stderr)
        return 64

    destination = Path(sys.argv[1])
    destination.mkdir(parents=True, exist_ok=True)
    licenses = sorted(
        path
        for root in LICENSE_ROOTS
        if root.exists()
        for path in root.rglob("*")
        if is_license(path) and ".build" not in path.parts
    )
    if not licenses:
        print("No shipped third-party licenses were found.", file=sys.stderr)
        return 65

    collected = {source.relative_to(REPO_ROOT) for source in licenses}
    missing_required = [path for path in REQUIRED_LICENSES if path not in collected]
    if missing_required:
        print(
            "Required license files were not collected: "
            + ", ".join(str(path) for path in missing_required),
            file=sys.stderr,
        )
        return 65

    for source in licenses:
        relative = source.relative_to(REPO_ROOT)
        target = destination / relative
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(source, target)

    print(f"==> Collected {len(licenses)} third-party license files")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
