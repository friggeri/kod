# Intel (x86_64) compatibility report

**Status: partial, automated evidence only. No real Intel hardware was used. No claim of a real Intel-Mac
launch, clean-install, or Gatekeeper test is made anywhere in this document.**

SPEC's architecture priority is explicit: *"Apple silicon first; Intel best-effort."* SPEC 16.2 #14 requires
that "Intel behavior is documented and tested on available hardware." This environment has no Intel Mac
available. This report states plainly what was and was not verified, using only this Apple-silicon host plus
Rosetta 2 (Apple's own x86_64 translation layer, already installed on this machine) and cross-compilation —
never a simulation of real Intel hardware, and never a substitute for it.

## What this report is evidence of

1. **The Xcode project and SwiftPM package both build cleanly for x86_64** on this Apple-silicon host, via
   Xcode's standard cross-compilation (`ARCHS=x86_64` / `swift build --arch x86_64`). This proves the source
   itself is architecture-portable (no arm64-only APIs, no accidental arm64-only conditional compilation) —
   see `Scripts/release/cross-build-x86_64.sh`.
2. **All 636 KodCore package tests pass when actually executed as real x86_64 machine code**, translated by
   Rosetta 2 (`arch -x86_64 swift test --arch x86_64`), not merely cross-compiled and left unexecuted. This is
   a real, headless functional-correctness signal for the x86_64 code path — including every fuzz/property
   suite, every Git/managed-install/preview parser, and the full performance-suite battery (though the
   *performance numbers themselves* are not meaningful under Rosetta translation overhead; only pass/fail
   functional correctness is asserted here — see "What this report is *not* evidence of" below).
3. **Both `.xcarchive` outputs contain real, correctly-tagged Mach-O binaries** for their respective
   architecture (verified with `file`), confirming the cross-build produces genuinely different, valid
   binaries rather than silently reusing the arm64 one.

## Evidence captured in this run

- Build machine: `arm64` (Apple silicon), macOS 26.5.2 (Darwin 25.5.0).
- `Scripts/release/build-archive.sh arm64` → `** ARCHIVE SUCCEEDED **`.
- `Scripts/release/cross-build-x86_64.sh` → `** ARCHIVE SUCCEEDED **`.
- `file Kod.app/Contents/MacOS/Kod` (arm64 archive) → `Mach-O 64-bit executable arm64`.
- `file Kod.app/Contents/MacOS/Kod` (x86_64 archive) → `Mach-O 64-bit executable x86_64`.
- `arch -x86_64 swift test --arch x86_64 -Xswiftc -warnings-as-errors` (full `KodCore` package suite, executed
  under Rosetta 2): **636 tests, 2 skipped (the opt-in 100k-file scale gate and one other), 0 failures**, in
  ~114s (vs. ~72s natively on arm64 — the difference is Rosetta translation overhead, not a functional
  regression).
- Raw log: `Artifacts/phase12-logs/rosetta-x86_64-full-test.log` (not committed; regenerate with the command
  above).

## What this report is *not* evidence of

- **Not a real Intel Mac launch.** `Kod.app`'s actual `NSApplication`/window was never launched under Rosetta
  or on real Intel hardware by this report — per this task's absolute constraint, no UI launch of any kind was
  performed. `KodAppTests` (the Xcode-project-level, AppKit-touching test target) was likewise only ever run
  natively on arm64 in this environment, never cross-built/executed for x86_64 — Xcode-project (as opposed to
  SwiftPM-package) cross-architecture test execution requires additional toolchain/simulator setup this
  environment does not have configured, and was out of scope to newly wire up safely within this pass.
- **Not a real Gatekeeper/notarization test on Intel.** SPEC 16.2 #14's actual acceptance bar — a signed,
  notarized build passing Gatekeeper and launching successfully on a clean Intel Mac — requires real hardware,
  a real Apple Developer ID signing identity, and real notarization credentials, none of which exist in this
  environment (see `Scripts/release/README.md`).
- **Not a performance signal.** Rosetta 2 translation overhead makes any timing measured under it meaningless
  as a *performance* number (SPEC 12's budgets are defined against native execution on the reference machine);
  this report only uses the Rosetta run for pass/fail functional correctness, never timing.
- **Not evidence for language-server or Git-executable behavior on real Intel silicon.** `GitCoreTests` and
  `LanguageAdaptersTests`/`LanguageClientTests`'s real, pinned-toolchain integration tests ran under Rosetta
  exactly as configured for arm64 (same fixed candidate paths, same pinned server versions) and passed, but a
  real Intel Mac may have different Homebrew prefix conventions or installed toolchain versions this
  environment cannot exercise.

## Recommendation for a real release

Before shipping an Intel-labeled or universal build as "tested," a release engineer with access to an actual
Intel Mac (or an Apple Silicon Mac dual-booted/never — Intel Macs cannot be emulated for a true hardware
test) should, at minimum:

1. Install the signed, notarized `x86_64` (or universal) DMG on a clean Intel Mac running both the oldest
   supported macOS major version and the current one (SPEC 12.1's reference workloads).
2. Confirm Gatekeeper accepts the app on first launch with no prior `xattr` removal.
3. Manually exercise the primary open → browse → search → navigate → diagnose workflow (the same journey
   SPEC 16.2 #13 requires a human complete for VoiceOver) to catch any Intel-only runtime behavior automated
   tests here cannot reach.
