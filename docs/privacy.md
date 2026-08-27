# Privacy

Kod is a local, strictly read-only macOS code viewer. This document
summarizes what Kod does and does not do with your data, mirroring
[SPEC.md](../SPEC.md) section 13 ("Security, trust, and privacy").

## What never leaves your Mac

Kod never sends workspace content or usage telemetry over the network.
Automatic update checks are the one default network request and are described
below. Specifically:

- Source code, file paths, symbols, diagnostics, themes, fonts, search
  terms, and repository data never leave your Mac.
- Kod collects **no usage telemetry** of any kind — no analytics SDK,
  no "phone home" on launch, no anonymous usage counters.
- Kod has no crash-report transport. Standard macOS crash reports remain under
  the user's control.

## The only network activity Kod ever performs

Every network call attributable to Kod is limited to these purposes:

| Purpose | When it happens | Default |
| --- | --- | --- |
| App update check | Sparkle checks `https://github.com/friggeri/kod/releases/latest/download/appcast.xml` over HTTPS | Enabled by default and configurable in Settings; installation always requires confirmation |
| JSON/YAML/TOML schema lookup | A trusted workspace's language server resolves a remote schema referenced by an open document | Disabled until you trust the workspace |
| Remote Markdown image | A Markdown file you're viewing references a remote image | Off; requires a per-document opt-in click, and is blocked entirely in untrusted workspaces |
| Crash report upload | Not exposed; relies entirely on native macOS crash reporting | Unavailable in Kod itself |

Third-party language-server processes may have behavior outside Kod's direct
control after a workspace is trusted. Kod's built-in JSON, YAML, and TOML
profiles enable remote schema resolution only after trust and report that
behavior in Languages settings. If you see Kod itself attempt a network
connection for a purpose not listed above, that is a bug — please report it.

## The update mechanism

Kod uses Sparkle 2.9.6 to provide automatic update checks. Sparkle checks the
appcast at
`https://github.com/friggeri/kod/releases/latest/download/appcast.xml` once per
day and when you choose **Check for Updates...**. GitHub receives the ordinary
connection metadata needed to serve that request, such as your IP address and
HTTP headers; it receives no workspace content. Checks can be disabled in
Settings. Sparkle verifies the appcast and archive with Kod's pinned EdDSA
public key, and the app is Developer-ID signed and notarized. Kod always asks
before downloading or installing an update.

## Redaction

Any diagnostic payload produced through `DiagnosticsCore`, including its
support-bundle generator, deterministically redacts the
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
