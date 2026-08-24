# Privacy

Kod is a local, strictly read-only macOS code viewer. This document
summarizes what Kod does and does not do with your data, mirroring
[SPEC.md](../SPEC.md) section 13 ("Security, trust, and privacy").

## What never leaves your Mac

By default, Kod sends nothing over the network. Specifically:

- Source code, file paths, symbols, diagnostics, themes, fonts, search
  terms, and repository data never leave your Mac.
- Kod collects **no usage telemetry** of any kind — no analytics SDK,
  no "phone home" on launch, no anonymous usage counters.
- Kod does not expose crash-reporting controls in Settings and, in this
  build, has no real upload destination configured at all. The only shipped
  crash-report transport is a permanent no-op (`NoopCrashReportTransport`
  in `DiagnosticsCore`) that does nothing when a report is "sent." This
  remains true even if an earlier build persisted an enabled preference.

## The only network activity Kod ever performs

Every network call Kod can make is attributable to exactly one of these
purposes, and each is either off by default or requires an explicit,
per-instance opt-in:

| Purpose | When it happens | Default |
| --- | --- | --- |
| App update check | Kod's own signed update-feed check (`UpdaterCore`), verified with a pinned Ed25519 key before any entry is ever considered — see below | Depends on distribution channel |
| JSON/YAML/TOML schema lookup | A trusted workspace's language server resolves a remote schema referenced by an open document | Disabled until you trust the workspace |
| Remote Markdown image | A Markdown file you're viewing references a remote image | Off; requires a per-document opt-in click, and is blocked entirely in untrusted workspaces |
| Crash report upload | Not exposed by the current UI; the shared `DiagnosticsCore` path still requires a persisted opt-in | Unavailable; no real transport is configured in this build |

Third-party language-server processes may have behavior outside Kod's direct
control after a workspace is trusted. Kod's built-in JSON, YAML, and TOML
profiles enable remote schema resolution only after trust and report that
behavior in Languages settings. If you see Kod itself attempt a network
connection for a purpose not listed above, that is a bug — please report it.

## The update mechanism

Kod's update check (`UpdaterCore`) fetches a single signed JSON feed and
verifies its Ed25519 signature against a small, pinned set of trusted
keys **before** any entry in it is ever decoded or considered — an
unsigned, tampered, or unknown-key feed is rejected outright, never
silently trusted. A downloaded update archive's SHA-256 digest is
verified against the feed's declared digest before it is ever
installed. Rolling back to a previous version is only ever offered for
a release the signing process explicitly marked as a safe rollback
target — never "any older signed version" — so a version pulled for a
security issue can never be reintroduced through rollback. No update
check, download, or install happens without being attributable to
this mechanism; see `Packages/KodCore/Sources/UpdaterCore` and
`Scripts/release/README.md` for the full signing/verification design.

## Redaction

Any diagnostic payload produced through `DiagnosticsCore`, including its
support-bundle generator or crash-report path, deterministically redacts the
following categories before they can be written anywhere or considered for
upload (`DiagnosticsCore.RedactionEngine`):

- Source text
- Search terms
- Usernames and home-directory paths
- Full file paths
- Repository remote URLs
- Symbol names
- Diagnostic messages
- Environment-variable-shaped secrets/tokens/API keys

Redaction is deterministic (the same input always redacts to the same
output) so it is exhaustively unit-tested
(`Packages/KodCore/Tests/DiagnosticsCoreTests/RedactionEngineTests.swift`)
rather than a best-effort heuristic. A support bundle's contents are a
single, human-readable JSON document — never source file contents,
never a copy of any part of your repository.

## Workspace trust

Opening a workspace does not implicitly trust it. Untrusted workspaces
may be browsed, searched, and previewed, but Kod will not start a
language server or any repository-discovered executable until you
explicitly trust that workspace. Trust can be revoked at any time from
the trust indicator at the bottom-right of the status bar, which
describes the current state in its tooltip and immediately stops any running
language servers after revocation.

Trust also gates remote schema resolution by the built-in JSON, YAML, and TOML
language-server profiles. Revoking trust stops those servers immediately.

## User-owned language servers

Kod does not download, install, update, or remove language servers. In
Settings, selecting a shipped language shows its server status, effective
Command, and curated installation guidance when missing. The Command is parsed
into an absolute local executable path and fixed arguments without shell
expansion or execution. Installation commands are display/copy-only; Kod never
executes package-manager commands or shell installation strings.

Kod stores the last known Ready/Not Installed result and resolved executable
metadata so Settings can render status immediately after restart. This cache
contains no source text or repository content, does not bypass workspace trust,
and is refreshed asynchronously when Kod launches.
