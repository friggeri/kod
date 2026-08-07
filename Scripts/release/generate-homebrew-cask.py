#!/usr/bin/env python3
"""Generates a Homebrew Cask template for Kod (SPEC 17 M4: release
documentation / distribution). This produces a *template*: the
`sha256` and `url` fields are placeholders until a real, signed,
notarized DMG exists at a public URL, since Homebrew requires a
publicly reachable download and this environment has no notarized
artifact and no place to publish one. The generated file is written
under Artifacts/release/, never committed to a live homebrew-cask tap
by this script.

Usage: Scripts/release/generate-homebrew-cask.py [version] [dmg-sha256] [output-path]
"""
from __future__ import annotations

import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]

CASK_TEMPLATE = """cask "kod" do
  version "{version}"
  sha256 "{sha256}"

  url "https://github.com/kodapp/kod/releases/download/v#{{version}}/Kod-#{{version}}-arm64.dmg"
  name "Kod"
  desc "Native macOS viewer for reading and understanding local codebases (read-only)"
  homepage "https://github.com/kodapp/kod"

  # Kod is Apple-silicon-first with Intel best-effort (SPEC "Architecture
  # priority"); if/when a universal or separate x86_64 DMG is published,
  # add a second `sha256`/`url` pair guarded by `on_intel`/`on_arm`
  # blocks here, matching Homebrew's standard multi-architecture cask
  # shape, rather than shipping only one architecture's artifact.
  depends_on macos: ">= :sonoma"

  app "Kod.app"

  zap trash: [
    "~/Library/Application Support/com.kodapp.Kod",
    "~/Library/Caches/com.kodapp.Kod",
    "~/Library/Preferences/com.kodapp.Kod.plist",
    "~/Library/Saved Application State/com.kodapp.Kod.savedState",
  ]
end
"""


def main() -> int:
    version = sys.argv[1] if len(sys.argv) > 1 else "REPLACE_WITH_RELEASE_VERSION"
    sha256 = sys.argv[2] if len(sys.argv) > 2 else "REPLACE_WITH_REAL_DMG_SHA256"
    output_path = Path(sys.argv[3]) if len(sys.argv) > 3 else REPO_ROOT / "Artifacts" / "release" / "kod.rb"

    output_path.parent.mkdir(parents=True, exist_ok=True)
    output_path.write_text(CASK_TEMPLATE.format(version=version, sha256=sha256))
    print(f"==> Wrote Homebrew Cask template to {output_path}")
    if version.startswith("REPLACE") or sha256.startswith("REPLACE"):
        print("==> NOTE: this is a template with placeholder version/sha256 — fill in real values from a published, notarized DMG before submitting to homebrew-cask.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
