#!/usr/bin/env python3
"""Re-vendor or byte-verify Kod's pinned cmark-gfm source subset."""
from __future__ import annotations

import argparse
import hashlib
import json
import shutil
import tarfile
import tempfile
import urllib.request
from pathlib import Path

SCRIPT_DIR = Path(__file__).resolve().parent
REPO_ROOT = SCRIPT_DIR.parents[1]
MANIFEST = json.loads((SCRIPT_DIR / "manifest.json").read_text())
CORE = REPO_ROOT / "Packages/KodCore/Sources/CCMarkGFM"
EXTENSIONS = REPO_ROOT / "Packages/KodCore/Sources/CCMarkGFMExtensions"


def download_archive(destination: Path) -> None:
    commit = MANIFEST["commit"]
    url = f"https://github.com/github/cmark-gfm/archive/{commit}.tar.gz"
    with urllib.request.urlopen(url) as response, destination.open("wb") as output:
        shutil.copyfileobj(response, output)
    digest = hashlib.sha256(destination.read_bytes()).hexdigest()
    if digest != MANIFEST["archiveSHA256"]:
        raise SystemExit(f"archive SHA-256 mismatch: expected {MANIFEST['archiveSHA256']}, got {digest}")


def compare_or_copy(source: Path, destination: Path, verify: bool) -> None:
    if verify:
        if not destination.exists() or source.read_bytes() != destination.read_bytes():
            raise SystemExit(f"vendored file differs from pinned upstream: {destination.relative_to(REPO_ROOT)}")
        return
    destination.parent.mkdir(parents=True, exist_ok=True)
    shutil.copyfile(source, destination)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--verify", action="store_true", help="compare every vendored upstream byte without modifying the tree")
    args = parser.parse_args()

    with tempfile.TemporaryDirectory(prefix="kod-cmark-gfm-") as temporary:
        archive = Path(temporary) / "source.tar.gz"
        download_archive(archive)
        with tarfile.open(archive, "r:gz") as tar:
            tar.extractall(temporary, filter="data")
        upstream = Path(temporary) / f"cmark-gfm-{MANIFEST['commit']}"

        for name in MANIFEST["coreSources"]:
            compare_or_copy(upstream / "src" / name, CORE / name, args.verify)
        for name in MANIFEST["coreHeaders"] + MANIFEST["coreIncludes"]:
            compare_or_copy(upstream / "src" / name, CORE / "include" / name, args.verify)
        for name in MANIFEST["extensionSources"]:
            compare_or_copy(upstream / "extensions" / name, EXTENSIONS / name, args.verify)
        for name in MANIFEST["extensionHeaders"]:
            compare_or_copy(upstream / "extensions" / name, EXTENSIONS / "include" / name, args.verify)
        compare_or_copy(upstream / "COPYING", CORE / "LICENSE-cmark-gfm.txt", args.verify)

    action = "Verified" if args.verify else "Vendored"
    print(f"{action} cmark-gfm {MANIFEST['version']} at {MANIFEST['commit']}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
