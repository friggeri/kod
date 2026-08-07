# Managed-install architecture matrix

Every catalog entry (`ManagedServerCatalogEntry`) declares its
per-architecture artifacts as a plain list of `ManagedServerArtifact`,
each tagged with exactly one `ManagedInstallArchitecture` (`arm64` or
`x86_64`; see `CatalogVerifier`'s `duplicateArtifactArchitecture` check,
which rejects more than one artifact per architecture in a single
entry). A missing artifact for the running Mac's architecture is a
normal, clearly-reported `ManagedInstallError.unsupportedArchitecture`
— never an install that silently downloads the wrong architecture's
binary.

This matrix records, for each managed server, what a real release
catalog is expected to offer per SPEC's "Apple silicon first; Intel
best-effort" priority (SPEC front matter, "Architecture priority"):

| Server | `arm64` (Apple silicon) | `x86_64` (Intel) | Notes |
| --- | --- | --- | --- |
| `typescript-language-server` | Required | Best-effort | Runs on the private Node runtime below; no native code of its own. |
| `vscode-html-language-server` | Required | Best-effort | Same private Node runtime. |
| `vscode-css-language-server` | Required | Best-effort | Same private Node runtime. |
| `pyright` | Required | Best-effort | Same private Node runtime (Pyright ships as an npm package). |
| `node-runtime` (private, shared by the four servers above) | Required | Best-effort | One catalog entry, `language: null`, referenced by each Node-based server's `privateRuntime.runtimeServerID`. |
| `rust-analyzer` | Required | Best-effort | Official standalone per-architecture release artifact; no shared runtime. |
| SourceKit-LSP | N/A (guided Xcode/toolchain install) | N/A (guided Xcode/toolchain install) | Never a managed-install catalog entry — SPEC 6.5 keeps this Xcode-guided only. |

"Best-effort" here means: the catalog **should** include an `x86_64`
artifact so Intel users are not left without a managed-install option,
but Apple silicon is the release-blocking, always-tested combination
(mirroring `Scripts/verify-phase`'s own `uname -m`-based architecture
selection for the bundled search engine and app build). If a given
release genuinely cannot produce a working `x86_64` artifact for one
server (e.g. an upstream project drops Intel binaries), that server's
catalog entry simply omits the `x86_64` artifact for that version, and
Intel users see the same `unsupportedArchitecture` state as any other
missing combination — clearly reported, never silently substituted with
the wrong binary.

## Test coverage of this matrix

- `ManagedInstallControllerHostileTests.testUnsupportedArchitectureRejected`
  builds a catalog entry with only the *other* architecture's artifact
  (using `ManagedInstallArchitecture.current` to determine which one is
  "other" on whatever machine runs the test) and asserts installation is
  refused with `ManagedInstallError.unsupportedArchitecture`.
- `CatalogVerifierTests.testDuplicateArtifactArchitectureRejected` proves
  a catalog cannot smuggle two artifacts for the same architecture past
  verification.
- Every offline fixture catalog (`FixtureCatalog`, and the smaller
  fixtures in `ManagedInstallControllerHostileTests`/
  `ManagedInstallDiscoverySourceTests`/`ManagedInstallCoordinatorTests`)
  only ever provides an artifact for `ManagedInstallArchitecture.current`
  — this repository cannot cross-compile a real second-architecture
  `FakeLanguageServer` binary in this environment, so the *other*
  architecture is exercised only via the deliberately-missing-artifact
  path above, never with a fabricated/fake binary pretending to be a
  real cross-architecture build.
