# Support

## Getting a support bundle

If you run into a problem with Kod and want to file an issue or ask for
help, the most useful thing you can attach is a support bundle:

1. Open **Kod → Settings… → Diagnostics**.
2. Review the bounded, redacted event log shown there — it lists recent
   background-subsystem events (language server, Git, search, managed
   install, preview) with severity, subsystem, and a redacted message.
   If more events occurred than the log's bounded capacity, a "N events
   dropped" indicator is shown so you know the log is not silently
   incomplete.
3. Click **Export Support Bundle…** and choose where to save it.

The resulting file is a single JSON document containing:

- An app/OS/architecture manifest.
- The redacted event log (see [privacy.md](privacy.md) for exactly what
  is redacted and how).
- A summary of any corrupted-and-rebuilt settings/theme/layout metadata
  (see "Corrupt settings recovery" below) — the fact that something was
  reset, and why, but never the corrupt bytes themselves.

It never contains source file contents, your repository's contents, or
anything from outside Kod's own external metadata.

## Corrupt settings recovery

Kod stores font settings, imported themes, and per-workspace window/tab
layout state outside your repository (never inside it). If any of that
stored metadata becomes corrupted (e.g. from an interrupted write or a
future Kod version's incompatible format), Kod does not silently ignore
it and does not keep failing to load it on every subsequent launch:
the corrupt data is removed so Kod can rebuild fresh defaults
immediately, and a record (which setting, when, why — never the corrupt
bytes) is kept for the support bundle above.

## Crash reports

Crash reporting is off by default and, in this build, has no real
upload destination configured — see [privacy.md](privacy.md) for the
full explanation. If you want to manually share a crash report with a
support request, the crash log is the standard macOS
`~/Library/Logs/DiagnosticReports/` crash report for the `Kod` process,
which you can attach yourself; Kod does not automatically collect or
transmit it.

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
- A support bundle (see above), if the issue is reproducible.
- Steps to reproduce.

Do not include actual source file contents from a private repository in
a public issue; the support bundle deliberately never contains any, so
there is no need to manually attach source snippets unless you choose to
for your own diagnostic purposes.
