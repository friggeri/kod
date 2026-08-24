# Support

## Collecting support information

The current Settings window does not expose the internal diagnostics log or
support-bundle export. When filing an issue, include the Kod version/build,
macOS version, workspace trust state, steps to reproduce, and any visible
status or error text. For a crash, attach the standard macOS crash report
described below.

Kod still keeps its bounded, redacted runtime event log internally, and
`DiagnosticsCore` retains the support-bundle generator and redaction rules
documented in [privacy.md](privacy.md). Removing the Settings screen does not
weaken those runtime privacy boundaries or delete previously persisted
crash-reporting preferences.

## Corrupt settings recovery

Kod stores font settings, imported themes, and per-workspace window/tab
layout state outside your repository (never inside it). If any of that
stored metadata becomes corrupted (e.g. from an interrupted write or a
future Kod version's incompatible format), Kod does not silently ignore
it and does not keep failing to load it on every subsequent launch:
the corrupt data is removed so Kod can rebuild fresh defaults immediately,
and a diagnostic record (which setting, when, why — never the corrupt bytes)
is retained outside the workspace.

## Crash reports

Crash reporting is off by default and, in this build, has no real
upload destination configured — see [privacy.md](privacy.md) for the
full explanation. If you want to manually share a crash report with a
support request, the crash log is the standard macOS
`~/Library/Logs/DiagnosticReports/` crash report for the `Kod` process,
which you can attach yourself; Kod does not automatically collect or
transmit it.

## Language support

Open **Kod → Settings…**, browse the Languages section in the permanent
sidebar, and select a language to inspect its server status and Command.

Syntax highlighting is bundled independently. Language-server executables are
not bundled in current builds, so an `LSP missing` status does not mean that
syntax highlighting is missing.

If a server is missing:

1. Trust the workspace if you want language intelligence; syntax highlighting
   remains available without trust.
2. Select the affected language and enter the executable plus arguments in its
   **Command** field. The executable must be an absolute local executable path.
   Clear the field to return to automatic discovery.
3. Use the selected language's **Installation** section to copy a supported
   install command or open the official guide. Clicking an unavailable
   language-server icon in the status bar opens Settings on that language.
   Kod never runs a package manager, shell command, update, or removal on your
   behalf.
4. If launch still fails, include the displayed server state and error text
   in the issue.

Shell intelligence works without ShellCheck, but lint diagnostics are more
limited when ShellCheck is absent. Kod does not silently install ShellCheck.
JSON, YAML, and TOML servers may resolve remote schemas only in a trusted
workspace.

## Updating and rolling back

Kod checks for updates via a single signed feed (see
[privacy.md](privacy.md)'s "The update mechanism" section) and never
installs anything whose signature or downloaded-artifact digest fails
verification. If a newly-installed update misbehaves, Kod can only ever
offer to roll back to a version the release process explicitly marked
safe for that purpose — never an arbitrary older version — so you are
never silently downgraded past a security fix. If rollback is not
offered for your situation, reinstalling the previous DMG/ZIP you
already downloaded (or via Homebrew: `brew reinstall --cask
kod@<previous-version>`, once a versioned cask exists) works exactly as
a normal reinstall.

## Filing an issue

Please include:

- Your macOS version and Kod version/build.
- Whether the workspace involved was trusted or untrusted.
- Any visible status or error text relevant to the failure.
- Steps to reproduce.

Do not include actual source file contents from a private repository in a
public issue unless you deliberately choose to share a minimal reproducer.
