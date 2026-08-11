# Phase 7 pinned real-server compatibility matrix

This records, for each pinned real language server
`Scripts/vendor-test-language-servers/setup.sh` installs, which of SPEC
6.1's read-only capabilities it actually advertises during `initialize`
against `LanguageAdaptersTests`' fixtures (`Fixtures/*`) — checked by hand
once per pin bump. Kod's own capability gating (`ServerCapabilities.*`,
`LanguageWorkspaceService`'s `capabilityUnavailable` errors) means an
absent capability here is simply hidden/disabled in Kod's UI, never an
error; this matrix exists so a maintainer bumping a pin can see at a
glance what changed, and so real-server integration tests avoid asserting
against a capability a given server has never actually claimed.

`✅` = advertised (real integration test exercises it). `—` = not
advertised by this server/version (Kod capability-gates the feature off;
no test asserts it for this adapter).

| Capability | Swift (SourceKit-LSP, Xcode 26.5 toolchain) | TypeScript (`typescript-language-server` 4.3.4) | HTML/CSS (`vscode-langservers-extracted` 4.10.0) | Python (`pyright` 1.1.407) | Rust (`rust-analyzer`, rustc 1.95.0) |
| --- | --- | --- | --- | --- | --- |
| Hover | ✅ | ✅ | ✅ | ✅ | ✅ |
| Definition | ✅ | ✅ | ✅ | ✅ | ✅ |
| Declaration | — | — | — | ✅ | ✅ |
| Type definition | — (not checked; capability-gated) | ✅ | — | ✅ | ✅ |
| Implementation | — (not checked; capability-gated) | ✅ | — | — | ✅ |
| References | ✅ | ✅ (implicit via server) | ✅ | ✅ (implicit via server) | ✅ (implicit via server) |
| Document highlight | — (not checked; capability-gated) | ✅ | ✅ | ✅ | ✅ |
| Document/workspace symbols | ✅ | ✅ | ✅ (document only) | ✅ | ✅ |
| Publish diagnostics | ✅ | ✅ (implicit) | ✅ (implicit) | ✅ (implicit) | ✅ (implicit) |
| Pull diagnostics | — (not advertised; documented Phase 6 finding) | — (not checked) | ✅ | — (not checked) | — (not checked) |
| Semantic tokens (full) | ✅ | — (not checked) | — (not checked) | — (not checked) | — (not checked) |
| Folding ranges | — (not checked; capability-gated) | ✅ | ✅ | — | ✅ |
| Selection ranges | — (not checked; capability-gated) | ✅ | ✅ | — | ✅ |
| Document links | — (not checked; capability-gated) | — | ✅ | — | — |
| Inlay hints | — (not checked; capability-gated) | ✅ | — | — | ✅ |
| Signature help (explicit) | — (not checked; capability-gated) | ✅ | — | ✅ | ✅ |
| Call hierarchy | — (not checked; capability-gated) | ✅ | — | ✅ | ✅ |
| Type hierarchy | — (not checked; capability-gated) | — | — | — | — |

## First-wave language servers

`FirstWaveLanguageAdapterIntegrationTests` initializes each pinned server,
opens a real fixture, validates document symbols, and invokes every read-only
capability below that the server advertises. The JSON integration pin uses
Microsoft's extracted test distribution only as a test fixture; Kod does not
ship or install that server.

| Capability | Shell (`bash-language-server` 5.6.0) | Markdown (Marksman 2026-02-08) | JSON (`vscode-langservers-extracted` 4.10.0) | YAML (`yaml-language-server` 1.24.0) | TOML (Tombi 1.2.10) |
| --- | --- | --- | --- | --- | --- |
| Hover | ✅ | ✅ | ✅ | ✅ | ✅ |
| Definition | ✅ | ✅ | — | ✅ | ✅ |
| Declaration | — | — | — | — | ✅ |
| Type definition | — | — | — | — | ✅ |
| Implementation | — | — | — | — | — |
| References | ✅ | ✅ | — | — | ✅ |
| Document highlight | ✅ | — | — | — | — |
| Document/workspace symbols | ✅ / ✅ | ✅ / ✅ | ✅ / — | ✅ / — | ✅ / — |
| Pull diagnostics | — | — | ✅ | — | — |
| Semantic tokens (full) | — | ✅ | — | — | ✅ |
| Folding ranges | — | — | ✅ | ✅ | ✅ |
| Selection ranges | — | — | ✅ | ✅ | — |
| Document links | — | — | ✅ | ✅ | ✅ |
| Inlay hints | — | — | — | — | ✅ |
| Signature help | — | — | — | — | — |
| Call hierarchy | — | — | — | — | — |
| Type hierarchy | — | — | — | — | — |

## Known interop findings from this pin set

- **`vscode-css-language-server`'s `documentSymbol` omits the optional
  `children` field for leaf symbols entirely** (rather than sending
  `[]`), which is valid per LSP 3.17 §3.17.0.20 but was rejected by Kod's
  original `DocumentSymbol` decoder (it required the key). Fixed in
  `Packages/KodCore/Sources/LanguageClient/LSPTypes/LSPFeatureTypes.swift`
  by giving `DocumentSymbol` a custom `init(from:)` that defaults a
  missing `children` to `[]` — this is a real, general LSP-interop
  correctness fix, not specific to CSS.
- **None of `vscode-html-language-server`, `vscode-css-language-server`,
  or `pyright-langserver` respond to `--version`** (or any invocation
  without a transport flag) — they error out immediately with "Connection
  input stream is not set." `HTMLLanguageAdapter`/`CSSLanguageAdapter`/
  `PythonLanguageAdapter` therefore pass `versionArguments: nil` and rely
  on this compatibility matrix (plus the `initialize` handshake itself)
  rather than a standalone version probe for those three adapters.
- **No adapter in this pin set advertises `typeHierarchyProvider`.** Kod's
  type hierarchy surface (`HierarchyViewController` with "Supertypes"/
  "Subtypes" modes) is implemented and protocol/capability-tested against
  `FakeLanguageServer`, but has no currently-pinned real server to
  exercise it against end-to-end; it is capability-gated off for every
  adapter here exactly as the no-silent-fallback design requires.
- **`rust-analyzer` in this environment is only reachable via a rustup
  component** (`rustup component add rust-analyzer`), not the
  `~/.cargo/bin/rust-analyzer` shim some environments use to reach a
  standalone binary directly — `RustLanguageAdapter`'s language-specific
  discovery probe (`rustup which rust-analyzer`) reflects this.
- **Tombi returns JSON `null` for valid empty `textDocument/references` and
  `textDocument/documentLink` responses.** Both methods permit `null` in LSP
  3.17. Kod now decodes those responses as empty result sets rather than
  treating them as a broken connection.

Re-run this check (temporarily add an ad hoc test that logs
`await service.capabilities()` for the adapter in question — see how
each `*LanguageAdapterIntegrationTests` file already asserts on specific
capability fields) after bumping any pin in
`Scripts/vendor-test-language-servers/manifest.json`, and update this
table if a server starts/stops advertising a capability.
