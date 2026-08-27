#!/usr/bin/env python3
"""Safe unit checks for the dependency-free Sparkle Ed25519 verifier."""

from __future__ import annotations

import base64
import importlib.util
import tempfile
import unittest
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
VERIFIER_PATH = REPO_ROOT / "Scripts" / "release" / "verify-sparkle-signature.py"
SPEC = importlib.util.spec_from_file_location("verify_sparkle_signature", VERIFIER_PATH)
assert SPEC and SPEC.loader
VERIFIER = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(VERIFIER)

PUBLIC_KEY = bytes.fromhex("d75a980182b10ab7d54bfed3c964073a0ee172f3daa62325af021a68f707511a")
SIGNATURE = bytes.fromhex(
    "e5564300c360ac729086e2cc806e828a"
    "84877f1eb8e5d974d873e06522490155"
    "5fb8821590a33bacc61e39701cf9b46b"
    "d25bf5f0595bbe24655141438e7a100b"
)
URL = "https://github.com/friggeri/kod/releases/download/v0.1.0/Kod-0.1.0-arm64.zip"


def write_appcast(root: Path, archive: Path, signature: bytes, url: str = URL) -> Path:
    appcast = root / "appcast.xml"
    appcast.write_text(
        "<rss xmlns:sparkle='http://www.andymatuschak.org/xml-namespaces/sparkle'>"
        f"<channel><item><enclosure url='{url}' length='{archive.stat().st_size}' "
        f"sparkle:edSignature='{base64.b64encode(signature).decode()}' /></item></channel></rss>"
    )
    return appcast


class SparkleSignatureTests(unittest.TestCase):
    def test_rfc8032_empty_message_vector_verifies(self) -> None:
        VERIFIER.verify_signature(PUBLIC_KEY, b"", SIGNATURE)

    def test_rejects_altered_signature(self) -> None:
        altered_signature = bytearray(SIGNATURE)
        altered_signature[-1] ^= 1
        with self.assertRaises(VERIFIER.VerificationError):
            VERIFIER.verify_signature(PUBLIC_KEY, b"", bytes(altered_signature))

    def test_verifies_the_exact_appcast_enclosure(self) -> None:
        with tempfile.TemporaryDirectory(dir=REPO_ROOT / "Scripts" / "release") as temporary_dir:
            root = Path(temporary_dir)
            archive = root / "Kod-0.1.0-arm64.zip"
            archive.write_bytes(b"")
            appcast = write_appcast(root, archive, SIGNATURE)
            VERIFIER.verify_appcast(PUBLIC_KEY, appcast, archive, URL)

    def test_rejects_tampered_archive_bytes(self) -> None:
        with tempfile.TemporaryDirectory(dir=REPO_ROOT / "Scripts" / "release") as temporary_dir:
            root = Path(temporary_dir)
            archive = root / "Kod-0.1.0-arm64.zip"
            archive.write_bytes(b"tampered")
            appcast = write_appcast(root, archive, SIGNATURE)
            with self.assertRaises(VERIFIER.VerificationError):
                VERIFIER.verify_appcast(PUBLIC_KEY, appcast, archive, URL)

    def test_rejects_mismatched_enclosure_signature(self) -> None:
        with tempfile.TemporaryDirectory(dir=REPO_ROOT / "Scripts" / "release") as temporary_dir:
            root = Path(temporary_dir)
            archive = root / "Kod-0.1.0-arm64.zip"
            archive.write_bytes(b"")
            altered_signature = bytearray(SIGNATURE)
            altered_signature[0] ^= 1
            appcast = write_appcast(root, archive, bytes(altered_signature))
            with self.assertRaises(VERIFIER.VerificationError):
                VERIFIER.verify_appcast(PUBLIC_KEY, appcast, archive, URL)


if __name__ == "__main__":
    unittest.main()
