# Contributing

Thank you for your interest in contributing to Kod!

## Getting Started

1. Ensure you are on an Apple Silicon Mac running macOS 14+ with Xcode 26.5.
2. Open `Kod.xcodeproj` and build the `Kod` scheme.
3. Run `Scripts/verify` to run the cumulative test gate.

## Guidelines

- Keep changes minimal and focused.
- Ensure all tests pass before submitting a pull request.
- Kod is strictly read-only. Do not add workspace mutation or execution
  capabilities.
- Kod relies on local Swift packages (`KodCore`, `KodUI`). Sparkle is the only
  remote application dependency and must remain exactly pinned.
- Please refer to `AGENTS.md` if you are using automated tools or AI agents to work on the codebase.

## Submitting changes

Open a pull request describing the changes, the problem solved, and how it was tested.
