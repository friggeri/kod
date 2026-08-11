#!/usr/bin/env python3
"""Generates a build-provenance statement for a Kod release artifact —
a SLSA-inspired (but not a certified SLSA attestation) record of what
was built, from what source, on what machine/toolchain, and how,
alongside its SHA-256 digest.

This is a *record*, not a cryptographic attestation: it is not signed
by this script, because no production signing key exists in this
environment (the same constraint documented in Scripts/release/README.md).
A real release process would sign this JSON document (e.g. with the
same Ed25519 release key used for the update feed, or via Apple's own
notarization ticket, which already attests the binary was submitted by
a specific Developer ID account) before publishing it; this script
only produces the plaintext statement that process would sign.

Usage: Scripts/release/generate-provenance.py <artifact-path> [output-path.json]
"""
from __future__ import annotations

import hashlib
import json
import platform
import subprocess
import sys
from datetime import datetime, timezone
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]


def sha256_of(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1 << 20), b""):
            digest.update(chunk)
    return digest.hexdigest()


def git_info() -> dict:
    def run(*args: str) -> str:
        try:
            return subprocess.run(
                ["git", *args], cwd=str(REPO_ROOT), capture_output=True, text=True, check=True
            ).stdout.strip()
        except subprocess.CalledProcessError:
            return "unknown"

    return {
        "commit": run("rev-parse", "HEAD"),
        "branch": run("rev-parse", "--abbrev-ref", "HEAD"),
        "isDirty": run("status", "--porcelain") != "",
    }


def swift_version() -> str:
    try:
        return subprocess.run(["swift", "--version"], capture_output=True, text=True, check=True).stdout.strip()
    except (subprocess.CalledProcessError, FileNotFoundError):
        return "unknown"


def xcode_version() -> str:
    try:
        return subprocess.run(["xcodebuild", "-version"], capture_output=True, text=True, check=True).stdout.strip()
    except (subprocess.CalledProcessError, FileNotFoundError):
        return "unknown"


def main() -> int:
    if len(sys.argv) < 2:
        print(f"Usage: {sys.argv[0]} <artifact-path> [output-path.json]", file=sys.stderr)
        return 64
    artifact_path = Path(sys.argv[1]).resolve()
    if not artifact_path.exists():
        print(f"Artifact not found: {artifact_path}", file=sys.stderr)
        return 66
    output_path = Path(sys.argv[2]) if len(sys.argv) > 2 else artifact_path.with_suffix(artifact_path.suffix + ".provenance.json")

    provenance = {
        "_type": "https://in-toto.io/Statement/v1 (unsigned; see this script's module docstring)",
        "subject": [{"name": artifact_path.name, "digest": {"sha256": sha256_of(artifact_path)}}],
        "predicateType": "https://slsa.dev/provenance/v1 (best-effort shape, not a certified SLSA attestation)",
        "predicate": {
            "buildDefinition": {
                "buildType": "https://github.com/actions/kod-release (manual/Scripts/release invocation)",
                "resolvedDependencies": {"git": git_info()},
            },
            "runDetails": {
                "builder": {"id": "Scripts/release (local/CI invocation, unattested)"},
                "metadata": {
                    "invocationId": datetime.now(timezone.utc).isoformat(),
                    "startedOn": datetime.now(timezone.utc).isoformat(),
                },
                "environment": {
                    "host": platform.node(),
                    "machineArchitecture": platform.machine(),
                    "operatingSystem": platform.platform(),
                    "swiftVersion": swift_version(),
                    "xcodeVersion": xcode_version(),
                },
            },
        },
        "signed": False,
        "signingNote": (
            "This provenance statement is not signed: no production signing key exists in this environment. "
            "A real release process signs this JSON (e.g. with the Ed25519 update-feed release key, "
            "or by relying on Apple notarization's own "
            "attestation of the submitting Developer ID account) before publishing it."
        ),
    }
    output_path.write_text(json.dumps(provenance, indent=2, sort_keys=True) + "\n")
    print(f"==> Wrote unsigned provenance statement to {output_path}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
