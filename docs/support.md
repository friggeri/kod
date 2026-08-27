# Support

## Collecting support information

Choose **Help > Export Support Bundle...** to write a human-readable JSON file
to a location you select. The bundle contains bounded, redacted diagnostic
metadata and corrupt-settings records; it contains no source files or
repository contents and is never uploaded automatically. Inspect it before
attaching it to an issue.

When filing an issue, include the Kod version/build, macOS version, workspace
trust state, steps to reproduce, and any visible status or error text. For a
crash, attach the standard macOS crash report described below only if you
choose to share it.

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

Crash reporting is handled entirely by macOS. Kod does not include a custom crash reporter. If you want to manually share a crash report with a
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

Kod uses Sparkle for automatic updates. Checks are enabled by default but can be disabled in Settings. Updates are never installed without user confirmation. If you need to roll back to a previous version, download the older DMG from the [releases page](https://github.com/friggeri/kod/releases) and reinstall it. Kod is not distributed via Homebrew.

## Filing an issue

Please file issues at: https://github.com/friggeri/kod/issues

Please include:

- Your macOS version and Kod version/build.
- Whether the workspace involved was trusted or untrusted.
- Any visible status or error text relevant to the failure.
- Steps to reproduce.

Do not include actual source file contents from a private repository in a
public issue unless you deliberately choose to share a minimal reproducer.
