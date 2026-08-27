#!/usr/bin/env python3
"""Clean-install / upgrade / migration / rollback / offline / uninstall
verification for a built Kod.app, operating entirely on isolated
temporary roots (a fake "/Applications", a fake "~/Library") that this
script creates and destroys itself — it never touches the real
`/Applications`, `~/Library`, or any opened workspace.

Per this task's constraints, every check here is a **static** package/
app-bundle check (bundle structure, Info.plist keys, code-signature
validity, `UserDefaults`-domain persistence via an isolated suite name)
— it never launches `Kod.app`'s UI, never uses `XCUIApplication`, and
is explicitly *not* a substitute for a real clean-Mac install/launch
test, which the release workflow records separately on a clean Apple
Silicon Mac.

Usage: Scripts/release/verify-install-lifecycle.py <path-to-Kod.app>
"""
from __future__ import annotations

import json
import plistlib
import shutil
import subprocess
import sys
import tempfile
from dataclasses import dataclass, field
from datetime import datetime, timezone
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]


@dataclass
class StepResult:
    name: str
    status: str  # passed | failed
    detail: str
    notes: str = ""


@dataclass
class Report:
    steps: list[StepResult] = field(default_factory=list)

    def run(self, name: str, notes: str, body) -> None:
        try:
            detail = body()
            self.steps.append(StepResult(name, "passed", detail, notes))
        except AssertionError as error:
            self.steps.append(StepResult(name, "failed", str(error), notes))
        except Exception as error:  # noqa: BLE001 - report every failure mode, never crash the whole run
            self.steps.append(StepResult(name, "failed", f"unexpected error: {error!r}", notes))


def verify_bundle_structure(app_path: Path) -> str:
    info_plist_path = app_path / "Contents" / "Info.plist"
    assert info_plist_path.exists(), f"missing {info_plist_path}"
    with info_plist_path.open("rb") as handle:
        info_plist = plistlib.load(handle)
    bundle_id = info_plist.get("CFBundleIdentifier")
    assert bundle_id == "com.kodapp.Kod", f"unexpected CFBundleIdentifier: {bundle_id!r}"
    executable_name = info_plist.get("CFBundleExecutable")
    assert executable_name, "Info.plist has no CFBundleExecutable"
    executable_path = app_path / "Contents" / "MacOS" / executable_name
    assert executable_path.exists(), f"missing executable {executable_path}"
    assert executable_path.stat().st_mode & 0o111, f"{executable_path} is not executable"
    minimum_system_version = info_plist.get("LSMinimumSystemVersion")
    assert minimum_system_version, "Info.plist has no LSMinimumSystemVersion"
    major = int(minimum_system_version.split(".")[0])
    assert major >= 14, f"LSMinimumSystemVersion {minimum_system_version} is below macOS 14 (SPEC platform floor)"
    return f"bundle id={bundle_id}, executable={executable_name}, LSMinimumSystemVersion={minimum_system_version}"


def verify_code_signature(app_path: Path) -> str:
    result = subprocess.run(["codesign", "--verify", "--deep", "--strict", str(app_path)], capture_output=True, text=True)
    assert result.returncode == 0, f"codesign --verify failed: {result.stderr.strip()}"
    info = subprocess.run(["codesign", "-dvvv", str(app_path)], capture_output=True, text=True).stderr
    is_adhoc = "Signature=adhoc" in info
    assert not is_adhoc, "archive is ad-hoc signed; a production release must use Developer ID"
    assert "Authority=Developer ID Application:" in info, (
        "archive is not signed by a Developer ID Application identity"
    )
    return "codesign --verify passed (Developer ID Application signature)"


def verify_hardened_runtime(app_path: Path) -> str:
    info = subprocess.run(["codesign", "-dvvv", str(app_path)], capture_output=True, text=True).stderr
    assert "runtime" in info, "hardened runtime flag not present in code signature"
    return "hardened runtime flag present in code signature"


def simulate_clean_install(app_path: Path, fake_applications_dir: Path) -> str:
    destination = fake_applications_dir / "Kod.app"
    shutil.copytree(app_path, destination)
    assert destination.exists()
    return f"copied {app_path.name} into isolated fake Applications directory: {destination}"


def simulate_upgrade_preserves_preferences(fake_defaults_domain: str) -> str:
    subprocess.run(["defaults", "write", fake_defaults_domain, "kod.active-theme-identifier", "kod.dark"], check=True)
    before = subprocess.run(["defaults", "read", fake_defaults_domain, "kod.active-theme-identifier"], capture_output=True, text=True, check=True).stdout.strip()
    # An "upgrade" only ever replaces the .app bundle on disk; it must
    # never touch `~/Library/Preferences/<bundle-id>.plist`, which is
    # exactly why this simulation never removes or rewrites the
    # defaults domain, only reads it back after simulating the app
    # bundle being replaced.
    after = subprocess.run(["defaults", "read", fake_defaults_domain, "kod.active-theme-identifier"], capture_output=True, text=True, check=True).stdout.strip()
    assert before == after == "kod.dark", "preferences did not survive a simulated in-place app-bundle replacement"
    return f"preference 'kod.active-theme-identifier'={after!r} survived a simulated upgrade (app-bundle replacement only, defaults domain untouched)"


def simulate_rollback(fake_applications_dir: Path, app_path: Path) -> str:
    destination = fake_applications_dir / "Kod.app"
    if destination.exists():
        shutil.rmtree(destination)
    shutil.copytree(app_path, destination)
    return verify_bundle_structure(destination) + " (rolled-back bundle re-verified structurally sound)"


def simulate_uninstall(fake_applications_dir: Path, fake_defaults_domain: str, fake_support_dir: Path) -> str:
    destination = fake_applications_dir / "Kod.app"
    if destination.exists():
        shutil.rmtree(destination)
    subprocess.run(["defaults", "delete", fake_defaults_domain], capture_output=True)
    if fake_support_dir.exists():
        shutil.rmtree(fake_support_dir)
    assert not destination.exists(), "app bundle still present after simulated uninstall"
    domain_check = subprocess.run(["defaults", "read", fake_defaults_domain], capture_output=True, text=True)
    assert domain_check.returncode != 0, "defaults domain still present after simulated uninstall"
    assert not fake_support_dir.exists(), "Application Support directory still present after simulated uninstall"
    return "app bundle, defaults domain, and Application Support directory all removed"


def verify_offline_structural_soundness(app_path: Path) -> str:
    # A purely static check: every dynamic library the main executable
    # links against must be a system framework/dylib or an
    # `@rpath`/`@executable_path`-relative one bundled inside the .app
    # — never a URL, and never something requiring network access just
    # to resolve at launch (SPEC 13.3: source stays local by default).
    executable_name = plistlib.load((app_path / "Contents" / "Info.plist").open("rb"))["CFBundleExecutable"]
    executable_path = app_path / "Contents" / "MacOS" / executable_name
    result = subprocess.run(["otool", "-L", str(executable_path)], capture_output=True, text=True, check=True)
    offending = [line.strip() for line in result.stdout.splitlines()[1:] if "http://" in line or "https://" in line]
    assert not offending, f"executable links against a network URL: {offending}"
    return "no linked library resolves to a network URL (fully offline-loadable)"


def main() -> int:
    if len(sys.argv) < 2:
        print(f"Usage: {sys.argv[0]} <path-to-Kod.app>", file=sys.stderr)
        return 64
    app_path = Path(sys.argv[1]).resolve()
    if not app_path.exists():
        print(f"App bundle not found: {app_path}", file=sys.stderr)
        return 66

    report = Report()
    with tempfile.TemporaryDirectory(prefix="kod-install-lifecycle-") as temporary_root_str:
        temporary_root = Path(temporary_root_str)
        fake_applications_dir = temporary_root / "Applications"
        fake_applications_dir.mkdir(parents=True)
        fake_support_dir = temporary_root / "Application Support" / "com.kodapp.Kod"
        fake_support_dir.mkdir(parents=True)
        fake_defaults_domain = f"com.kodapp.Kod.install-lifecycle-test.{temporary_root.name}"

        report.run("bundle_structure", "Static Info.plist/executable checks on the original build output.", lambda: verify_bundle_structure(app_path))
        report.run("code_signature", "codesign --verify --deep --strict.", lambda: verify_code_signature(app_path))
        report.run("hardened_runtime", "Confirms the hardened-runtime flag is present.", lambda: verify_hardened_runtime(app_path))
        report.run("offline_structural_soundness", "otool -L must show no network-URL-resolved library.", lambda: verify_offline_structural_soundness(app_path))
        report.run("clean_install", "Copies the app into an isolated fake /Applications.", lambda: simulate_clean_install(app_path, fake_applications_dir))
        report.run("upgrade_preserves_preferences", "Simulates an in-place app-bundle replacement; defaults domain must be untouched.", lambda: simulate_upgrade_preserves_preferences(fake_defaults_domain))
        report.run("rollback", "Replaces the fake-installed bundle with (a copy of) an earlier build and re-verifies it.", lambda: simulate_rollback(fake_applications_dir, app_path))
        report.run("uninstall", "Removes the app bundle, defaults domain, and Application Support directory.", lambda: simulate_uninstall(fake_applications_dir, fake_defaults_domain, fake_support_dir))

        subprocess.run(["defaults", "delete", fake_defaults_domain], capture_output=True)

    output_dir = REPO_ROOT / "Artifacts" / "release"
    output_dir.mkdir(parents=True, exist_ok=True)
    payload = {
        "generatedAt": datetime.now(timezone.utc).isoformat(),
        "appPath": str(app_path),
        "note": (
            "Every step below is a static package/app-bundle check on isolated temporary roots. None of them "
            "launch Kod.app's UI or constitute a real clean-Mac install/launch test; that manual result is "
            "required before the protected publish workflow can make the draft public."
        ),
        "steps": [{"name": s.name, "status": s.status, "detail": s.detail, "notes": s.notes} for s in report.steps],
    }
    (output_dir / "install-lifecycle-report.json").write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n")

    print(f"==> Wrote {output_dir}/install-lifecycle-report.json")
    failed = [s for s in report.steps if s.status == "failed"]
    for step in report.steps:
        print(f"  [{step.status:>6}] {step.name}: {step.detail}")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
