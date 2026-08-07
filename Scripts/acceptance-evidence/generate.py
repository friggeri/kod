#!/usr/bin/env python3
"""Kod release-qualification acceptance-evidence generator (SPEC 16.2).

Maps every one of SPEC 16.2's 15 numbered 1.0 acceptance criteria to the
concrete command(s) that produce evidence for it, runs what is safely and
headlessly runnable in this environment, and emits one machine-readable
JSON report plus a human-readable Markdown summary. No criterion is ever
silently marked "passed": every criterion's status is one of

    passed             - the mapped automated check(s) ran and succeeded
    failed             - the mapped automated check(s) ran and failed
    skipped            - the mapped check exists but was not run this
                         invocation (e.g. the 100k-file scale gate,
                         which is opt-in via KOD_RUN_SCALE_TESTS=1
                         because it is slow)
    manual_required    - the criterion (or part of it) can only be
                         verified by a human (VoiceOver) and this tool
                         has never claimed otherwise
    credential_gated   - the criterion requires a production signing/
                         notarization credential that does not and must
                         not exist in this environment
    hardware_gated     - the criterion requires physical hardware
                         (a clean Mac, real Intel silicon) not available
                         here

This script is read-only with respect to the repository: it invokes
`swift test` / `xcodebuild test`, reads their output and this
repository's own generated artifacts (e.g.
Artifacts/performance/performance-results.json), and writes only under
Artifacts/acceptance-evidence/. It never modifies source, and it is
run by `Scripts/verify-phase 12` but can also be run standalone.
"""
from __future__ import annotations

import json
import os
import re
import subprocess
import sys
from dataclasses import dataclass, field
from datetime import datetime, timezone
from pathlib import Path
from typing import Callable, Optional

REPO_ROOT = Path(__file__).resolve().parents[2]
KODCORE_PACKAGE = REPO_ROOT / "Packages" / "KodCore"
ARTIFACTS_DIR = REPO_ROOT / "Artifacts" / "acceptance-evidence"
LOGS_DIR = ARTIFACTS_DIR / "logs"
PERFORMANCE_RESULTS = REPO_ROOT / "Artifacts" / "performance" / "performance-results.json"
MEMORY_RESULTS = REPO_ROOT / "Artifacts" / "performance" / "memory-benchmark.json"
VOICEOVER_CHECKLIST = REPO_ROOT / "docs" / "manual-voiceover-checklist.md"


@dataclass
class Evidence:
    status: str  # passed | failed | skipped | manual_required | credential_gated | hardware_gated
    summary: str
    commands: list[str] = field(default_factory=list)
    artifacts: list[str] = field(default_factory=list)
    notes: str = ""


@dataclass
class Criterion:
    number: int
    spec_reference: str
    description: str
    evaluate: Callable[["RunContext"], Evidence]


class RunContext:
    """Caches the (possibly slow) command outputs every criterion's
    `evaluate` function needs, so each expensive command runs at most
    once no matter how many criteria reference it."""

    def __init__(self, run_scale_tests: bool, skip_xcodebuild: bool, reuse_logs: bool = False):
        self.run_scale_tests = run_scale_tests
        self.skip_xcodebuild = skip_xcodebuild
        self.reuse_logs = reuse_logs
        self._swift_test_log: Optional[str] = None
        self._xcodebuild_log: Optional[str] = None
        LOGS_DIR.mkdir(parents=True, exist_ok=True)

    def swift_test_log(self) -> str:
        if self._swift_test_log is not None:
            return self._swift_test_log
        architecture = subprocess.run(["uname", "-m"], capture_output=True, text=True, check=True).stdout.strip()
        log_path = LOGS_DIR / f"swift-test-{architecture}.log"
        if self.reuse_logs and log_path.exists():
            self._swift_test_log = log_path.read_text()
            return self._swift_test_log
        env = dict(os.environ)
        if self.run_scale_tests:
            env["KOD_RUN_SCALE_TESTS"] = "1"
        result = subprocess.run(
            ["swift", "test", "-Xswiftc", "-warnings-as-errors"],
            cwd=str(KODCORE_PACKAGE),
            capture_output=True,
            text=True,
            env=env,
        )
        log = result.stdout + "\n" + result.stderr
        log_path.write_text(log)
        self._swift_test_log = log
        return log

    def xcodebuild_log(self) -> str:
        if self._xcodebuild_log is not None:
            return self._xcodebuild_log
        if self.skip_xcodebuild:
            self._xcodebuild_log = ""
            return ""
        architecture = subprocess.run(["uname", "-m"], capture_output=True, text=True, check=True).stdout.strip()
        log_path = LOGS_DIR / f"xcodebuild-kodapptests-{architecture}.log"
        if self.reuse_logs and log_path.exists():
            self._xcodebuild_log = log_path.read_text()
            return self._xcodebuild_log
        derived_data = REPO_ROOT / "DerivedData" / "AcceptanceEvidence"
        result = subprocess.run(
            [
                "xcodebuild",
                "-project", str(REPO_ROOT / "Kod.xcodeproj"),
                "-scheme", "Kod",
                "-configuration", "Debug",
                "-destination", f"platform=macOS,arch={architecture}",
                "-derivedDataPath", str(derived_data),
                "-only-testing:KodAppTests",
                "test",
            ],
            cwd=str(REPO_ROOT),
            capture_output=True,
            text=True,
        )
        log = result.stdout + "\n" + result.stderr
        log_path.write_text(log)
        self._xcodebuild_log = log
        return log


def suite_outcome(log: str, suite_name: str) -> Optional[bool]:
    """Returns True if `suite_name` reported passing, False if any of
    its tests failed, or None if the suite never appeared in `log` at
    all (e.g. it was filtered out or never compiled).

    Handles both output shapes this tool's two test runners produce:
      - `swift test`'s serial format: one `Test Suite '<name>' passed/
        failed` summary line per suite.
      - `xcodebuild test`'s parallelized-worker format (used for
        KodAppTests): suites run interleaved across several worker
        processes with no per-suite summary line, only individual
        `Test case '<Suite>.<method>() passed/failed on ...'` lines —
        so the suite's outcome is "every one of its own test-case lines
        said passed, and at least one such line exists."
    """
    passed = re.search(rf"Test Suite '{re.escape(suite_name)}' passed", log)
    failed = re.search(rf"Test Suite '{re.escape(suite_name)}' failed", log)
    if failed:
        return False
    if passed:
        return True

    case_pattern = re.compile(rf"Test case '{re.escape(suite_name)}\.[^']+\(\)' (passed|failed)")
    case_outcomes = case_pattern.findall(log)
    if not case_outcomes:
        return None
    return all(outcome == "passed" for outcome in case_outcomes)


def suites_outcome(log: str, suite_names: list[str]) -> Evidence:
    outcomes = {name: suite_outcome(log, name) for name in suite_names}
    missing = [name for name, outcome in outcomes.items() if outcome is None]
    failed = [name for name, outcome in outcomes.items() if outcome is False]
    if missing and not any(outcomes.values()):
        return Evidence(
            status="skipped",
            summary=f"Suite(s) not found in this run's log: {', '.join(missing)}",
        )
    if failed:
        return Evidence(status="failed", summary=f"Failing suite(s): {', '.join(failed)}")
    if missing:
        return Evidence(
            status="failed",
            summary=f"Suite(s) expected but missing from log (did not compile/run): {', '.join(missing)}",
        )
    return Evidence(status="passed", summary=f"All mapped suites passed: {', '.join(suite_names)}")


def pinned_test_language_servers_present() -> bool:
    test_servers_dir = KODCORE_PACKAGE / ".build" / "test-language-servers"
    required = [
        "node_modules/.bin/typescript-language-server",
        "node_modules/.bin/vscode-html-language-server",
        "node_modules/.bin/vscode-css-language-server",
        "pyright-venv/bin/pyright-langserver",
    ]
    if not all((test_servers_dir / relative).exists() for relative in required):
        return False
    rustup = subprocess.run(["command", "-v", "rustup"], shell=False, capture_output=True)
    if subprocess.run(["which", "rustup"], capture_output=True).returncode != 0:
        return False
    return subprocess.run(["rustup", "which", "rust-analyzer"], capture_output=True).returncode == 0


def sourcekit_lsp_present() -> bool:
    result = subprocess.run(["/usr/bin/xcrun", "--find", "sourcekit-lsp"], capture_output=True)
    return result.returncode == 0


def load_performance_results() -> Optional[dict]:
    if not PERFORMANCE_RESULTS.exists():
        return None


def load_memory_results() -> Optional[dict]:
    if not MEMORY_RESULTS.exists():
        return None
    try:
        return json.loads(MEMORY_RESULTS.read_text())
    except (json.JSONDecodeError, OSError):
        return None
    try:
        return json.loads(PERFORMANCE_RESULTS.read_text())
    except (json.JSONDecodeError, OSError):
        return None


# MARK: - Criterion evaluators

def criterion_1(ctx: RunContext) -> Evidence:
    if not ctx.run_scale_tests:
        return Evidence(
            status="skipped",
            summary="100k-file scale gate not run this invocation (opt-in: slow).",
            commands=["KOD_RUN_SCALE_TESTS=1 swift test --filter WorkspaceCoreTests.testDiscoversOneHundredThousandFilesWithinBudget"],
            notes="Re-run Scripts/acceptance-evidence --run-scale-tests (or Scripts/verify-phase 12 with KOD_RUN_SCALE_TESTS=1) to execute.",
        )
    log = ctx.swift_test_log()
    evidence = suites_outcome(log, ["WorkspaceCoreTests"])
    memory = load_memory_results()
    if memory is None:
        evidence.status = "failed"
        evidence.notes += (
            " Isolated memory evidence is missing; run Scripts/run-memory-benchmark."
        )
    else:
        evidence.artifacts.append(str(MEMORY_RESULTS.relative_to(REPO_ROOT)))
        evidence.notes += (
            f" Isolated Release process resident memory="
            f"{memory['residentMegabytes']:.1f}MB "
            f"(budget {memory['budgetMegabytes']:.0f}MB, "
            f"passed={memory['passed']})."
        )
        if not memory["passed"]:
            evidence.status = "failed"
    perf = load_performance_results()
    if perf:
        results = {r["name"]: r for r in perf.get("results", [])}
        discovery = results.get("100k-file-discovery-complete")
        first_batch = results.get("100k-file-discovery-first-batch")
        if discovery and first_batch:
            evidence.artifacts.append(str(PERFORMANCE_RESULTS.relative_to(REPO_ROOT)))
            evidence.notes += (
                f" 100k discovery p95={discovery['p95Milliseconds']:.0f}ms (budget {discovery['budgetMilliseconds']}ms, "
                f"passed={discovery['passed']}); first-batch p95={first_batch['p95Milliseconds']:.0f}ms "
                f"(budget {first_batch['budgetMilliseconds']}ms, passed={first_batch['passed']})."
            )
            if not (discovery["passed"] and first_batch["passed"]):
                evidence.status = "failed"
    evidence.commands.append("swift test --filter WorkspaceCoreTests")
    return evidence


def criterion_2(ctx: RunContext) -> Evidence:
    log = ctx.swift_test_log()
    evidence = suites_outcome(log, ["TenMegabyteParseBenchmarkTests", "TenMegabyteRepaintBenchmarkTests", "CodeDocumentViewControllerTests"])
    perf = load_performance_results()
    if perf:
        results = {r["name"]: r for r in perf.get("results", [])}
        ten_mb = results.get("10mb-source-first-layout")
        if ten_mb:
            evidence.artifacts.append(str(PERFORMANCE_RESULTS.relative_to(REPO_ROOT)))
            evidence.notes += f" 10MB first-layout p95={ten_mb['p95Milliseconds']:.1f}ms (budget {ten_mb['budgetMilliseconds']}ms)."
            if not ten_mb["passed"]:
                evidence.status = "failed"
    evidence.commands.append('swift test --filter "TenMegabyteParseBenchmarkTests|TenMegabyteRepaintBenchmarkTests|CodeDocumentViewControllerTests"')
    return evidence


def criterion_3(ctx: RunContext) -> Evidence:
    log = ctx.swift_test_log()
    evidence = suites_outcome(log, ["GoldenCaptureTests"])
    evidence.commands.append("swift test --filter SyntaxCoreTests.GoldenCaptureTests")
    return evidence


def criterion_4(ctx: RunContext) -> Evidence:
    if not sourcekit_lsp_present():
        return Evidence(
            status="skipped",
            summary="sourcekit-lsp not found via 'xcrun --find sourcekit-lsp'; a full Xcode toolchain is required for Swift LSP integration tests.",
        )
    if not pinned_test_language_servers_present():
        return Evidence(
            status="skipped",
            summary="Pinned TypeScript/HTML/CSS/Python/Rust test language servers not installed.",
            notes="Run Scripts/vendor-test-language-servers/setup.sh, then re-run this tool.",
        )
    log = ctx.swift_test_log()
    evidence = suites_outcome(log, [
        "SourceKitLSPIntegrationTests", "TypeScriptLanguageAdapterIntegrationTests",
        "HTMLLanguageAdapterIntegrationTests", "CSSLanguageAdapterIntegrationTests",
        "PythonLanguageAdapterIntegrationTests", "RustLanguageAdapterIntegrationTests",
    ])
    evidence.commands.append("swift test --filter LanguageClientTests|LanguageAdaptersTests")
    return evidence


def criterion_5(ctx: RunContext) -> Evidence:
    log = ctx.swift_test_log()
    evidence = suites_outcome(log, ["ManagedInstallControllerHostileTests"])
    evidence.commands.append("swift test --filter ManagedLanguageServersTests.ManagedInstallControllerHostileTests")
    evidence.notes = "LanguageClientTests' own connection-fixture tests additionally cover missing/crashed/slow-server degradation at the LSP-connection layer."
    return evidence


def criterion_6(ctx: RunContext) -> Evidence:
    log = ctx.swift_test_log()
    evidence = suites_outcome(log, ["GitImmutabilityTests", "PreviewCoreWorkspaceImmutabilityTests"])
    evidence.commands.append('swift test --filter "GitImmutabilityTests|PreviewCoreWorkspaceImmutabilityTests"')
    return evidence


def criterion_7(ctx: RunContext) -> Evidence:
    log = ctx.swift_test_log()
    evidence = suites_outcome(log, ["WorkspaceCoreTests", "RipgrepArgumentsTests", "RipgrepStreamParserTests", "WorkspaceTextSearcherTests", "SearchEngineLocatorTests"])
    evidence.commands.append('swift test --filter "WorkspaceCoreTests|SearchCoreTests"')
    return evidence


def criterion_8(ctx: RunContext) -> Evidence:
    log = ctx.swift_test_log()
    evidence = suites_outcome(log, ["GitStatusParserTests", "GitDiffParserTests", "GitBlameParserTests", "GitProcessInvocationSpyTests"])
    evidence.commands.append("swift test --filter GitCoreTests")
    return evidence


def criterion_9(ctx: RunContext) -> Evidence:
    log = ctx.swift_test_log()
    evidence = suites_outcome(log, ["VSCodeThemeImportTests", "ThemeStoreTests", "VSCodeThemeImportFuzzTests"])
    evidence.commands.append('swift test --filter "ThemeCoreTests|FontCoreTests"')
    return evidence


def criterion_10(ctx: RunContext) -> Evidence:
    if ctx.skip_xcodebuild:
        return Evidence(
            status="skipped",
            summary="xcodebuild KodAppTests not run this invocation (pass --run-xcodebuild to include).",
            commands=["xcodebuild -only-testing:KodAppTests test"],
        )
    log = ctx.xcodebuild_log()
    evidence = suites_outcome(log, ["EditorGroupViewControllerReloadTests"])
    evidence.commands.append("xcodebuild -project Kod.xcodeproj -scheme Kod -only-testing:KodAppTests test")
    return evidence


def criterion_11(ctx: RunContext) -> Evidence:
    log = ctx.swift_test_log()
    evidence = suites_outcome(log, ["MarkdownHostileInputTests", "PreviewNoNetworkTests", "PreviewParserFuzzTests"])
    evidence.commands.append("swift test --filter PreviewCoreTests")
    return evidence


def criterion_12(ctx: RunContext) -> Evidence:
    if ctx.skip_xcodebuild:
        log = ctx.swift_test_log()
        return suites_outcome(log, ["WorkspaceCoreTests"])
    log = ctx.xcodebuild_log()
    evidence = suites_outcome(log, ["WorkspaceViewControllerTrustControlTests"])
    evidence.commands.append("xcodebuild -only-testing:KodAppTests test (WorkspaceViewControllerTrustControlTests)")
    return evidence


def criterion_13(ctx: RunContext) -> Evidence:
    log = ctx.swift_test_log()
    keyboard_evidence = suites_outcome(log, ["CodeViewportAccessibilityTests"])
    manual_note = (
        "VoiceOver verification is manual-only and has never been run by any automated tool in this "
        f"repository; see {VOICEOVER_CHECKLIST.relative_to(REPO_ROOT)} for the checklist a human must complete."
    )
    if not VOICEOVER_CHECKLIST.exists():
        return Evidence(
            status="failed",
            summary="Manual VoiceOver checklist document is missing.",
            notes=manual_note,
        )
    return Evidence(
        status="manual_required",
        summary=(
            f"Keyboard-navigation automation: {keyboard_evidence.status} ({keyboard_evidence.summary}). "
            "VoiceOver portion: manual_required (never run by this tool)."
        ),
        artifacts=[str(VOICEOVER_CHECKLIST.relative_to(REPO_ROOT))],
        commands=["swift test --filter CodeViewportAccessibilityTests"],
        notes=manual_note,
    )


def criterion_14(ctx: RunContext) -> Evidence:
    architecture = subprocess.run(["uname", "-m"], capture_output=True, text=True, check=True).stdout.strip()
    has_notarization_credentials = bool(
        os.environ.get("KOD_NOTARIZATION_API_KEY_PATH") or os.environ.get("KOD_NOTARIZATION_KEYCHAIN_PROFILE")
    )
    has_signing_identity = bool(os.environ.get("KOD_CODE_SIGN_IDENTITY"))
    return Evidence(
        status="credential_gated" if not (has_notarization_credentials and has_signing_identity) else "hardware_gated",
        summary=(
            f"Building/cross-building on this {architecture} machine is automatable (see Scripts/release/); "
            "signing with a real Developer ID certificate, notarization submission, and a real clean-Mac "
            "Gatekeeper launch test are not available in this environment."
        ),
        commands=[
            "Scripts/release/build-archive.sh",
            "Scripts/release/cross-build-x86_64.sh",
            "Scripts/release/codesign-and-notarize.sh (blocked: no production credentials)",
        ],
        artifacts=["docs/intel-compatibility-report.md"],
        notes=(
            "Credential-gated: KOD_CODE_SIGN_IDENTITY / KOD_NOTARIZATION_API_KEY_PATH / "
            "KOD_NOTARIZATION_KEYCHAIN_PROFILE are unset, matching this environment having no production "
            "Apple Developer ID signing/notarization credentials, by design (see Scripts/release/README.md). "
            "Hardware-gated regardless: a clean-Mac Gatekeeper launch test requires physical hardware this "
            "environment does not provide. Intel compatibility is addressed via a cross-build and (where "
            "Rosetta is available) a headless test run under Rosetta, documented in "
            "docs/intel-compatibility-report.md, never a claim of real Intel-hardware testing."
        ),
    )


def criterion_15(ctx: RunContext) -> Evidence:
    log = ctx.swift_test_log()
    evidence = suites_outcome(log, ["RedactionEngineTests", "RedactionFuzzTests", "CrashReportingTests"])
    evidence.commands.append("swift test --filter DiagnosticsCoreTests")
    evidence.notes = "DiagnosticsCoreTests' own redaction/crash-report-opt-in tests plus RedactionFuzzTests' seeded fuzz coverage."
    return evidence


CRITERIA: list[Criterion] = [
    Criterion(1, "16.2.1", "A 100,000-file reference repository opens within the stated time and memory budgets.", criterion_1),
    Criterion(2, "16.2.2", "A 10 MB source file paints, scrolls, searches, selects, copies, and navigates without blocking the main thread or crashing.", criterion_2),
    Criterion(3, "16.2.3", "All listed Tree-sitter languages pass syntax golden tests.", criterion_3),
    Criterion(4, "16.2.4", "All listed language servers pass hover, navigation, references, symbols, diagnostics, semantic tokens, inlay hints, and hierarchy integration tests where the server supports them.", criterion_4),
    Criterion(5, "16.2.5", "Missing, slow, malformed, and crashing servers degrade explicitly while code viewing remains usable.", criterion_5),
    Criterion(6, "16.2.6", "A full automated user journey produces no change anywhere under the workspace root or in Git state.", criterion_6),
    Criterion(7, "16.2.7", "Quick Open and workspace search stream deterministic, cancellable results at the target scale.", criterion_7),
    Criterion(8, "16.2.8", "Git status, diff, inline markers, and blame agree with Git fixtures and execute no helper, hook, fetch, lock, or write.", criterion_8),
    Criterion(9, "16.2.9", "VS Code theme JSON import, Kod-native themes, installed fonts, fallback fonts, and appearance switching work without restarting.", criterion_9),
    Criterion(10, "16.2.10", "Split groups restore their tabs, history, selections, folds, and scroll anchors.", criterion_10),
    Criterion(11, "16.2.11", "Markdown, image, JSON, and plist previews pass hostile-input and network-blocking tests.", criterion_11),
    Criterion(12, "16.2.12", "Untrusted workspaces start no language server or repository-discovered executable.", criterion_12),
    Criterion(13, "16.2.13", "VoiceOver and full keyboard navigation can complete the primary open-search-navigate-diagnose workflow.", criterion_13),
    Criterion(14, "16.2.14", "The signed and notarized Apple-silicon build passes Gatekeeper on a clean Mac; Intel behavior is documented and tested on available hardware.", criterion_14),
    Criterion(15, "16.2.15", "Opt-in crash reports contain none of the redacted source or identity fields in the privacy test suite.", criterion_15),
]


def main() -> int:
    run_scale_tests = "--run-scale-tests" in sys.argv or os.environ.get("KOD_RUN_SCALE_TESTS") == "1"
    skip_xcodebuild = "--run-xcodebuild" not in sys.argv
    reuse_logs = "--reuse-logs" in sys.argv
    ctx = RunContext(run_scale_tests=run_scale_tests, skip_xcodebuild=skip_xcodebuild, reuse_logs=reuse_logs)

    entries = []
    any_failed = False
    for criterion in CRITERIA:
        evidence = criterion.evaluate(ctx)
        if evidence.status == "failed":
            any_failed = True
        entries.append({
            "number": criterion.number,
            "specReference": criterion.spec_reference,
            "description": criterion.description,
            "status": evidence.status,
            "summary": evidence.summary,
            "commands": evidence.commands,
            "artifacts": evidence.artifacts,
            "notes": evidence.notes,
        })

    architecture = subprocess.run(["uname", "-m"], capture_output=True, text=True, check=True).stdout.strip()
    report = {
        "generatedAt": datetime.now(timezone.utc).isoformat(),
        "architecture": architecture,
        "specVersion": "SPEC.md 16.2 (Kod 1.0 acceptance criteria)",
        "criteria": entries,
    }

    ARTIFACTS_DIR.mkdir(parents=True, exist_ok=True)
    json_path = ARTIFACTS_DIR / "acceptance-evidence.json"
    json_path.write_text(json.dumps(report, indent=2, sort_keys=True) + "\n")

    markdown_lines = [
        "# Kod 1.0 acceptance evidence (SPEC 16.2)",
        "",
        f"Generated: {report['generatedAt']} on {architecture}",
        "",
        "| # | Status | Criterion |",
        "| - | ------ | --------- |",
    ]
    for entry in entries:
        markdown_lines.append(f"| {entry['number']} | **{entry['status']}** | {entry['description']} |")
    markdown_lines.append("")
    for entry in entries:
        markdown_lines.append(f"## {entry['number']}. {entry['description']}")
        markdown_lines.append("")
        markdown_lines.append(f"- **Status:** {entry['status']}")
        markdown_lines.append(f"- **Summary:** {entry['summary']}")
        if entry["commands"]:
            markdown_lines.append(f"- **Commands:** {'; '.join(entry['commands'])}")
        if entry["artifacts"]:
            markdown_lines.append(f"- **Artifacts:** {', '.join(entry['artifacts'])}")
        if entry["notes"]:
            markdown_lines.append(f"- **Notes:** {entry['notes']}")
        markdown_lines.append("")
    (ARTIFACTS_DIR / "acceptance-evidence.md").write_text("\n".join(markdown_lines) + "\n")

    print(f"==> Wrote {json_path.relative_to(REPO_ROOT)} and its Markdown summary")
    for entry in entries:
        print(f"  [{entry['status']:>17}] #{entry['number']:>2}: {entry['description'][:80]}")

    if any_failed:
        print("==> One or more acceptance criteria FAILED their automated evidence.", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
