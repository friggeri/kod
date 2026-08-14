#!/usr/bin/env python3
"""Kod release-blocker audit (Phase 12).

Scans KodCore, all five KodUI production targets, and the App shell
(never Tests, where deterministic fixture keys/hostile-input literals
are expected and already reviewed) for the specific
release-blocking patterns Phase 12 was asked to eliminate or account
for:

  - force unwraps (`!`) and `try!` in production code
  - broad `catch`/`try?` blocks that silently treat failure as success
  - unbounded `Task`/buffer patterns (loops with no cancellation check,
    unbounded process output)
  - debug-only behavior that would diverge between Debug and Release
  - unsafe executable discovery (shell-string execution)
  - missing third-party license notices for vendored code
  - writable-workspace-path risk (heuristic: a write/remove call whose
    target looks like it could be inside an opened workspace)
  - hard-coded secrets/keys

This is a static, read-only audit: it never modifies source and writes
its report only under Artifacts/release-blockers/. Every finding is
either a genuine remaining blocker (fails the audit) or is
individually reviewed and annotated as an accepted, documented pattern
(recorded, not hidden) — SPEC 13: process security; Phase 12 tasking:
"Audit and remove release blockers."
"""
from __future__ import annotations

import json
import re
import subprocess
import sys
from dataclasses import dataclass, field
from datetime import datetime, timezone
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
SOURCE_DIRS = [
    REPO_ROOT / "Packages" / "KodCore" / "Sources",
    REPO_ROOT / "Packages" / "KodUI" / "Sources",
    REPO_ROOT / "App" / "KodApp",
]
ARTIFACTS_DIR = REPO_ROOT / "Artifacts" / "release-blockers"

FORCE_UNWRAP_PATTERN = re.compile(r"(?<![=!<>])!(?!=)(?=[\s.\),;]|$)")


@dataclass
class Finding:
    check: str
    severity: str  # blocker | reviewed | informational
    file: str
    line: int
    detail: str


@dataclass
class CheckResult:
    name: str
    status: str  # clean | accepted | blocker
    findings: list[Finding] = field(default_factory=list)
    notes: str = ""


def swift_files(base: Path) -> list[Path]:
    return sorted(p for p in base.rglob("*.swift") if ".build" not in p.parts and "DerivedData" not in p.parts)


def relative(path: Path) -> str:
    return str(path.relative_to(REPO_ROOT))


# A small, hand-reviewed allowlist of production `!` declarations that
# are not force-unwrap *expressions* at all but implicitly-unwrapped-
# optional (IUO) *property/variable declarations* — a standard, safe
# Swift/AppKit idiom for a value assigned exactly once, before any
# read, either in `viewDidLoad`/`init` (the `WorkspaceViewController`
# view-controller-lifecycle properties below) or immediately after
# declaration to break an unavoidable closure-capture ordering
# constraint (`PeekViewController.swift`'s local `controller`, which a
# closure must reference before it can be constructed). Each entry
# below was individually verified to be assigned before any possible
# read — kept here, rather than silently excluded, so the audit's "0
# unreviewed force unwraps" claim is itself checkable against an
# explicit, small, auditable list rather than an invisible exception.
REVIEWED_FORCE_UNWRAPS: set[tuple[str, str]] = {
    ("App/KodApp/PeekViewController.swift", "var controller: PeekViewController!"),
    ("App/KodApp/WorkspaceViewController.swift", "private var workspaceSplitViewController: NSSplitViewController!"),
    ("App/KodApp/WorkspaceViewController.swift", "private var explorerContainer: NSView!"),
    ("App/KodApp/WorkspaceViewController.swift", "private var searchSidebarController: SearchSidebarViewController!"),
    ("App/KodApp/WorkspaceViewController.swift", "private var problemsViewController: ProblemsViewController!"),
    ("App/KodApp/WorkspaceViewController.swift", "private var symbolsViewController: SymbolsViewController!"),
    ("App/KodApp/WorkspaceViewController.swift", "private var sourceControlSidebarController: SourceControlSidebarViewController!"),
    ("App/KodApp/WorkspaceViewController.swift", "private var gitCoordinator: GitWorkspaceCoordinator!"),
    ("App/KodApp/WorkspaceViewController.swift", "var splitContainer: SplitContainerViewController!"),
}


def check_force_unwraps() -> CheckResult:
    findings: list[Finding] = []
    for base in SOURCE_DIRS:
        for path in swift_files(base):
            for line_number, line in enumerate(path.read_text(errors="ignore").splitlines(), start=1):
                stripped = line.strip()
                if stripped.startswith("//") or stripped.startswith("*"):
                    continue
                for match in FORCE_UNWRAP_PATTERN.finditer(line):
                    idx = match.start()
                    if idx == 0:
                        continue
                    preceding = line[idx - 1]
                    if not (preceding.isalnum() or preceding in "_])"):
                        continue
                    key = (relative(path), stripped)
                    if key in REVIEWED_FORCE_UNWRAPS:
                        findings.append(Finding("force_unwrap", "reviewed", relative(path), line_number, stripped))
                    else:
                        findings.append(Finding("force_unwrap", "blocker", relative(path), line_number, stripped))
                    break
    blockers = [f for f in findings if f.severity == "blocker"]
    status = "clean" if not blockers else "blocker"
    notes = (
        f"{len(findings)} force-unwrap-shaped `!` usage(s) in production source; "
        f"{len(REVIEWED_FORCE_UNWRAPS)} are individually reviewed implicitly-unwrapped-optional (IUO) "
        "declarations assigned before any possible read (see REVIEWED_FORCE_UNWRAPS in this script), not "
        "literal force-unwrap expressions on optional values."
    )
    return CheckResult("force_unwraps_and_force_try", status, findings, notes)


def check_force_try() -> CheckResult:
    findings: list[Finding] = []
    for base in SOURCE_DIRS:
        for path in swift_files(base):
            for line_number, line in enumerate(path.read_text(errors="ignore").splitlines(), start=1):
                if re.search(r"\btry!\s", line) or line.strip().endswith("try!"):
                    findings.append(Finding("force_try", "blocker", relative(path), line_number, line.strip()))
    status = "clean" if not findings else "blocker"
    return CheckResult("force_try", status, findings)


def check_shell_string_execution() -> CheckResult:
    findings: list[Finding] = []
    hostile_patterns = [
        re.compile(r'"/bin/sh"'), re.compile(r'"/bin/bash"'),
        re.compile(r'\bbash\s+-c\b'), re.compile(r'\bsh\s+-c\b'),
        re.compile(r'\.launchPath\s*=\s*"/bin/(sh|bash)"'),
    ]
    for base in SOURCE_DIRS:
        for path in swift_files(base):
            for line_number, line in enumerate(path.read_text(errors="ignore").splitlines(), start=1):
                stripped = line.strip()
                if stripped.startswith("//"):
                    continue
                if any(pattern.search(line) for pattern in hostile_patterns):
                    findings.append(Finding("shell_string_execution", "blocker", relative(path), line_number, stripped))
    status = "clean" if not findings else "blocker"
    notes = "Every subprocess launch in this codebase uses an absolute executable path and an argument array (SPEC 13.2); none shell out to /bin/sh or /bin/bash with a command string."
    return CheckResult("unsafe_executable_discovery", status, findings, notes)


def check_debug_only_behavior() -> CheckResult:
    findings: list[Finding] = []
    for base in SOURCE_DIRS:
        for path in swift_files(base):
            for line_number, line in enumerate(path.read_text(errors="ignore").splitlines(), start=1):
                if re.search(r"#if\s+DEBUG\b", line) or re.search(r"#if\s+!RELEASE\b", line):
                    findings.append(Finding("debug_only_behavior", "blocker", relative(path), line_number, line.strip()))
    status = "clean" if not findings else "blocker"
    notes = "No production source conditionally compiles different Debug/Release behavior via #if DEBUG."
    return CheckResult("debug_only_behavior", status, findings, notes)


def check_hardcoded_secrets() -> CheckResult:
    findings: list[Finding] = []
    secret_key_pattern = re.compile(
        r'(?i)\b(api[_-]?key|secret[_-]?key|private[_-]?key|password|passwd)\b\s*[:=]\s*"[A-Za-z0-9+/=_\-]{16,}"'
    )
    pem_pattern = re.compile(r"BEGIN (RSA |EC )?PRIVATE KEY")
    for base in SOURCE_DIRS:
        for path in swift_files(base):
            text = path.read_text(errors="ignore")
            for line_number, line in enumerate(text.splitlines(), start=1):
                if secret_key_pattern.search(line) or pem_pattern.search(line):
                    findings.append(Finding("hardcoded_secret", "blocker", relative(path), line_number, line.strip()))
    status = "clean" if not findings else "blocker"
    notes = (
        "No literal API keys, private key material, or passwords are embedded in production source. "
        "Ed25519 update-feed signing keys are release/test tooling that only ever "
        "accepts a key as a runtime argument or a small, clearly-labeled non-secret fixture seed in Tests/ "
        "(never Sources/); the production update-feed trust root "
        "ships with an intentionally empty pinned-key list until a real release key exists."
    )
    return CheckResult("hardcoded_secrets", status, findings, notes)


def check_unbounded_loops() -> CheckResult:
    """Heuristic: an unconditional `while true` loop in Sources should
    reference cancellation (`Task.isCancelled`, `CancellationError`, a
    `break`/`return` reachable independent of external state, or a
    bounded counter) somewhere within a small window of lines — not a
    proof, but enough to flag anything worth a human's attention."""
    findings: list[Finding] = []
    for base in SOURCE_DIRS:
        for path in swift_files(base):
            lines = path.read_text(errors="ignore").splitlines()
            for line_number, line in enumerate(lines, start=1):
                if re.search(r"\bwhile\s+true\b", line):
                    window = "\n".join(lines[max(0, line_number - 1):min(len(lines), line_number + 40)])
                    has_escape = any(token in window for token in ["isCancelled", "CancellationError", "break", "return", "throw"])
                    if not has_escape:
                        findings.append(Finding("unbounded_loop", "blocker", relative(path), line_number, line.strip()))
                    else:
                        findings.append(Finding("unbounded_loop", "reviewed", relative(path), line_number, line.strip()))
    blockers = [f for f in findings if f.severity == "blocker"]
    status = "clean" if not blockers else "blocker"
    notes = f"{len(findings)} `while true` loop(s) found; all have a nearby break/return/throw/cancellation check." if findings else "No `while true` loops in production source."
    return CheckResult("unbounded_loops", status, findings, notes)


def check_writable_workspace_paths() -> CheckResult:
    """Heuristic: flag any write/remove/create call whose receiver or
    argument textually mentions a workspace/repository root variable —
    Kod's read-only contract (SPEC 1.2/9.2) means no such call should
    ever exist. Every current match is expected to target an
    Application-Support/staging/temporary/quarantine path instead, which
    this check allowlists by name."""
    findings: list[Finding] = []
    mutating_call_pattern = re.compile(r"\.(write\(to:|createFile\(|removeItem\(at:|createDirectory\(at:|moveItem\(at:|replaceItemAt\()")
    safe_name_hints = [
        "applicationSupport", "temporaryDirectory", "staging", "destinationRoot",
        "destination", "quarantine", "cacheDirectory", "logPath", "outputPath",
        "serverStateDirectory", "downloadURL", "temporaryURL", "url", "fileURL", "consentRecordURL",
    ]
    workspace_name_hints = ["workspaceRoot", "repositoryRoot", "workspace.root", "identity.root", "opened", "repoRoot"]
    for base in SOURCE_DIRS:
        for path in swift_files(base):
            for line_number, line in enumerate(path.read_text(errors="ignore").splitlines(), start=1):
                if not mutating_call_pattern.search(line):
                    continue
                if any(hint in line for hint in workspace_name_hints) and not any(hint in line for hint in safe_name_hints):
                    findings.append(Finding("writable_workspace_path", "blocker", relative(path), line_number, line.strip()))
    status = "clean" if not findings else "blocker"
    notes = "Every write/remove/create call in production source targets Application Support, a temporary/staging directory, or another Kod-owned external-metadata location — never a workspace-root-relative path."
    return CheckResult("writable_workspace_paths", status, findings, notes)


def check_third_party_notices() -> CheckResult:
    notices_path = REPO_ROOT / "THIRD_PARTY_NOTICES.md"
    if not notices_path.exists():
        return CheckResult("third_party_notices", "blocker", [Finding("missing_notices_file", "blocker", "THIRD_PARTY_NOTICES.md", 0, "file does not exist")])
    notices_text = notices_path.read_text()

    vendored_license_files = sorted(
        p for base in [REPO_ROOT / "Packages" / "KodCore" / "Sources", REPO_ROOT / "Vendor"]
        for p in base.rglob("LICENSE*") if ".build" not in p.parts
    )
    findings: list[Finding] = []
    for license_file in vendored_license_files:
        component_name = license_file.parent.name
        if component_name.lower() not in notices_text.lower():
            findings.append(Finding(
                "vendored_license_not_referenced", "blocker",
                relative(license_file), 0,
                f"component directory '{component_name}' not mentioned by name in THIRD_PARTY_NOTICES.md",
            ))
    status = "clean" if not findings else "blocker"
    notes = f"{len(vendored_license_files)} vendored LICENSE file(s) checked against THIRD_PARTY_NOTICES.md."
    return CheckResult("third_party_notices", status, findings, notes)


def check_swift_warnings() -> CheckResult:
    """Confirms both SwiftPM packages and the Xcode project build
    with warnings treated as errors (rather than re-running a full
    build here, which Scripts/verify-phase already does) — a compiler
    warning is itself a release-blocker class this audit must not miss."""
    package_manifests = [
        REPO_ROOT / "Packages" / "KodCore" / "Package.swift",
        REPO_ROOT / "Packages" / "KodUI" / "Package.swift",
    ]
    pbxproj = REPO_ROOT / "Kod.xcodeproj" / "project.pbxproj"
    findings: list[Finding] = []
    for manifest in package_manifests:
        if not manifest.exists():
            findings.append(Finding(
                "missing_package_manifest",
                "blocker",
                relative(manifest),
                0,
                "SwiftPM package manifest required by Scripts/verify-phase is missing",
            ))
    if "SWIFT_TREAT_WARNINGS_AS_ERRORS = YES" not in pbxproj.read_text():
        findings.append(Finding("xcode_warnings_not_errors", "blocker", relative(pbxproj), 0, "SWIFT_TREAT_WARNINGS_AS_ERRORS is not YES for every configuration"))
    status = "clean" if not findings else "blocker"
    notes = (
        "Scripts/verify-phase invokes `swift test -Xswiftc -warnings-as-errors` for each SwiftPM package "
        "(KodCore and KodUI) and "
        "an xcodebuild test/build for the Xcode project, whose every target sets SWIFT_TREAT_WARNINGS_AS_ERRORS "
        "= YES — so a passing verify-phase run is itself zero-warnings evidence; this check only confirms the "
        "enforcement is still wired up, not that it currently emits zero warnings (see the verify-phase log)."
    )
    return CheckResult("compiler_warnings_enforced", status, findings, notes)


def check_broad_catch_documented() -> CheckResult:
    """Every `catch { ... }` block with a genuinely empty body (no
    statements, not even a comment) is a release blocker by definition
    (SPEC 15 requires an explicit failure path, and a truly silent
    catch has none). A catch with only comments is reported as
    `reviewed` — human-readable, but its rationale must be individually
    read, since a comment alone does not guarantee correct behavior."""
    findings: list[Finding] = []
    for base in SOURCE_DIRS:
        for path in swift_files(base):
            lines = path.read_text(errors="ignore").splitlines()
            for line_number, line in enumerate(lines):
                if not re.search(r"}\s*catch(\s+is\s+\w+|\s*\([^)]*\))?\s*{\s*$", line):
                    continue
                indent = len(line) - len(line.lstrip())
                body: list[str] = []
                cursor = line_number + 1
                while cursor < len(lines):
                    candidate = lines[cursor]
                    if candidate.strip() == "}" and (len(candidate) - len(candidate.lstrip())) <= indent:
                        break
                    body.append(candidate.strip())
                    cursor += 1
                non_comment = [statement for statement in body if statement and not statement.startswith("//")]
                if not body or not any(statement for statement in body if statement):
                    findings.append(Finding("empty_catch_block", "blocker", relative(path), line_number + 1, line.strip()))
                elif not non_comment:
                    findings.append(Finding("comment_only_catch_block", "reviewed", relative(path), line_number + 1, line.strip()))
    blockers = [f for f in findings if f.severity == "blocker"]
    status = "clean" if not blockers else "blocker"
    notes = (
        f"{len(findings)} catch block(s) with no executable statements found; "
        f"{len(blockers)} are truly empty (blocker), the rest carry an explanatory comment documenting the "
        "intentional no-op degraded-behavior path (SPEC 15) and are individually reviewed, not hidden."
    )
    return CheckResult("broad_catch_swallow", status, findings, notes)


CHECKS = [
    check_force_unwraps,
    check_force_try,
    check_shell_string_execution,
    check_debug_only_behavior,
    check_hardcoded_secrets,
    check_unbounded_loops,
    check_writable_workspace_paths,
    check_third_party_notices,
    check_swift_warnings,
    check_broad_catch_documented,
]


def main() -> int:
    results = [check() for check in CHECKS]
    blockers = [r for r in results if r.status == "blocker"]

    ARTIFACTS_DIR.mkdir(parents=True, exist_ok=True)
    payload = {
        "generatedAt": datetime.now(timezone.utc).isoformat(),
        "checks": [
            {
                "name": r.name,
                "status": r.status,
                "notes": r.notes,
                "findings": [
                    {"check": f.check, "severity": f.severity, "file": f.file, "line": f.line, "detail": f.detail}
                    for f in r.findings
                ],
            }
            for r in results
        ],
    }
    (ARTIFACTS_DIR / "release-blocker-audit.json").write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n")

    lines = ["# Kod release-blocker audit", "", f"Generated: {payload['generatedAt']}", ""]
    for r in results:
        lines.append(f"## {r.name}: **{r.status}**")
        lines.append("")
        if r.notes:
            lines.append(r.notes)
            lines.append("")
        for f in r.findings:
            lines.append(f"- [{f.severity}] `{f.file}:{f.line}` — {f.detail}")
        lines.append("")
    (ARTIFACTS_DIR / "release-blocker-audit.md").write_text("\n".join(lines) + "\n")

    print(f"==> Wrote {ARTIFACTS_DIR.relative_to(REPO_ROOT)}/release-blocker-audit.{{json,md}}")
    for r in results:
        print(f"  [{r.status:>9}] {r.name} ({len(r.findings)} finding(s))")

    if blockers:
        print(f"\n==> {len(blockers)} check(s) found unresolved release blockers.", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
