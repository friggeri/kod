# Agent Guidelines

Automated tools and AI agents must follow these invariants when working on the Kod repository:

1. **Read-Only App**: Kod is a strictly read-only macOS application. Agents
   must never introduce code that edits, compiles, executes, or deletes
   workspace files.
2. **Build/Test**: Use `Scripts/verify` to run the cumulative test suite. Do
   not introduce new test runners.
3. **Dependencies**: Do not add remote package dependencies. Sparkle 2.9.6 is
   the sole approved exception and must stay exactly pinned.
4. **Platform**: Kod is for Apple Silicon and macOS 14+ only. Do not add Intel/x86_64 specific code or fallbacks.
5. **No Telemetry**: Do not introduce analytics, crash reporting platforms, or other telemetry code.
6. **Processes**: Launch only reviewed absolute executable paths with argument
   arrays, never shell command strings or repository-provided executables.
7. **Scripts**: Do not modify release scripts or GitHub workflows without
   explicit user instruction.
