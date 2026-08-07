# Managed-install catalog signing

Kod's managed language-server installer (`ManagedLanguageServers`,
`ManagedInstallController`) never installs anything without first
verifying a detached Ed25519 (Curve25519 signing) signature over the
catalog's canonical bytes (`CatalogVerifier.verify`). This directory
documents the reproducible process for producing that signature and for
generating/refreshing the catalog and artifact set it describes, and
states plainly what remains before that process can produce a real,
shippable release artifact from this environment.

## The tool

`Packages/KodCore/Sources/ManagedCatalogTool` (built via
`swift build --product ManagedCatalogTool` inside `Packages/KodCore`) is
the only code in this repository that ever holds or accepts a *private*
signing key, and only ever as a command-line argument/local file the
release engineer supplies — never a literal embedded in source. It has
three subcommands:

```sh
# 1. Generate a new Ed25519 key pair. Run this exactly once per key,
#    offline, on a machine you control — never in CI, never committed.
ManagedCatalogTool generate-key
#   seed-base64: <32 random bytes, base64 — THE PRIVATE KEY, keep this secret>
#   public-key-base64: <32 bytes, base64 — safe to publish/pin>

# 2. Sign a catalog JSON file (see "Catalog JSON shape" below) into the
#    distributable signed envelope Kod's app fetches/caches.
ManagedCatalogTool sign \
  --catalog catalog.json \
  --key-seed-base64 "$SEED_FROM_STEP_1" \
  --key-id "2026-08" \
  --output signed-catalog.json

# 3. Verify a signed envelope against a given public key/ID (useful for
#    a release engineer to double-check a signed artifact before
#    publishing it, exactly the same check `CatalogVerifier` performs).
ManagedCatalogTool verify \
  --signed signed-catalog.json \
  --public-key-base64 "$PUBLIC_KEY_FROM_STEP_1" \
  --key-id "2026-08"
```

## Catalog JSON shape

The tool decodes/encodes `ManagedServerCatalog` exactly as
`ManagedLanguageServers` defines it (see
`Packages/KodCore/Sources/ManagedLanguageServers/Catalog/ManagedServerCatalog.swift`).
Fields with a sensible default (`revoked`, `revocationReason`,
`adapterArguments`, `adapterEnvironment`, `privateRuntime`) may be
omitted from a hand-authored catalog; every other field
(`serverID`, `language`, `version`, `minimumKodVersion`, `artifacts`,
and every field of each artifact) is required. See
`Packages/KodCore/Tests/ManagedLanguageServersTests/FixtureCatalog.swift`
for a complete worked example (test-only, signed with the fixture key
below, never the production key).

Every artifact's `sha256Hex` must be the exact SHA-256 of the bytes at
its `url` — compute it with `shasum -a 256 <file>` (or
`Digest.sha256Hex(ofFileAt:)` from a small Swift script) against the
*exact* archive you are about to publish, not a previous build.

## Key rotation

`CatalogTrustRoot.pinned` (in the shipped Kod app) is a list of
`TrustedSigningKey`s, each with a `validFrom`/`validUntil` window keyed
off the *catalog's own* `generatedAt` timestamp, not "now" — this is
what makes rotation explicit and safe:

1. Generate a new key pair (`generate-key`) well before the old key's
   planned retirement.
2. Ship a Kod release that adds the *new* key to `CatalogTrustRoot.pinned`
   (with `validFrom` set to when it starts signing) **while keeping the
   old key pinned** with its own `validUntil` set to the same cutover
   instant. Both keys are simultaneously valid for their respective
   catalog-generation windows.
3. Switch the release-signing process (step 2 above) to the new key's
   seed once every actively-supported Kod build has that new pin.
4. Only after every supported Kod version recognizes the new key does
   the old key ever need to be removed from `CatalogTrustRoot.pinned`
   entirely — and even then, only remove it, never reuse its ID for a
   different key.

A key must never be reused across an unrelated purpose, and the private
seed must never be pasted into a chat, ticket, CI log, or committed file
at any point in this process.

## Revocation

Two independent, finer-grained mechanisms exist for withdrawing trust
without a full key rotation:

- **Per-entry `revoked`/`revocationReason`** (catalog-author-controlled):
  set on a specific `ManagedServerCatalogEntry` in a newly-signed
  catalog to withdraw one server version after publication (a
  vulnerability, a bad build). `ManagedInstallController` refuses to
  install a revoked entry and reports it distinctly
  (`ManagedInstallError.revokedEntry`).
- **`CatalogTrustRoot.revokedArtifactDigestsHex`** (app-build-controlled):
  a set of SHA-256 hex digests Kod itself refuses to ever install again,
  even from an otherwise-validly-signed catalog — for the rare case
  where a specific artifact byte sequence must never run again
  regardless of what any catalog says. Shipped as part of a Kod update,
  not fetched at runtime.

## Reproducible artifact generation

Each managed server's artifact should be produced the same way every
time from its own upstream release, never hand-modified:

- **`typescript-language-server` / `vscode-html-language-server` /
  `vscode-css-language-server`**: fetch the pinned upstream npm
  tarball(s), install with the pinned private Node runtime (never the
  user's own `npm`/`node`, and never running any `npm` lifecycle
  script — extract the package tarball directly and reference its
  entry-point `.js` file plus the private Node runtime as the
  executable), then re-archive the resulting directory tree as this
  catalog entry's `tar.gz` artifact with `SecureArchiveExtractor`'s
  exact expected-layout list.
- **`rust-analyzer`**: use the official pre-built standalone release
  tarball for each architecture directly from
  <https://github.com/rust-lang/rust-analyzer/releases> — already a
  single static executable, requiring no repackaging beyond computing
  its digest and expected layout.
- **`pyright`**: same approach as the Node-based servers above (it also
  ships as an npm package and needs the private Node runtime).
- **SourceKit-LSP**: intentionally **not** a managed-install artifact —
  SPEC 6.5 keeps this guided Xcode/toolchain install only.

`Packages/KodCore/Tests/ManagedLanguageServersTests/FixtureCatalog.swift`
demonstrates the equivalent process for tests: it builds a `tar.gz`
archive containing the repository's own `FakeLanguageServer` fixture
executable (not a real server, but a real, launchable, LSP-speaking
binary), computes its digest, and signs the resulting catalog with the
fixture key below — entirely offline, reproducible on every test run.

## Fixture keys (test-only, not secret)

`ManagedLanguageServersTests.FixtureSigningKey`,
`LanguageAdaptersTests.ManagedInstallDiscoverySourceTests`, and
`KodAppTests.ManagedInstallCoordinatorTests` each use a **fixed,
deterministic, intentionally non-secret** Ed25519 seed baked directly
into test source, so fixture catalogs are byte-for-byte reproducible
across test runs without any generation step. These keys:

- Sign nothing outside this repository's own test fixtures.
- Must never appear in `CatalogTrustRoot.production`.
- Are safe to be fully public (they are, in this very file's git
  history) precisely because nothing trusts them outside test code.

## Release provisioning gap (explicit)

**No real, notarized production Ed25519 signing key exists in this
environment**, and none should ever be generated inside an agent
session, CI runner, or any other environment that isn't the release
engineer's own controlled, offline key-generation step described above.
Concretely, what remains before Phase 8's mechanism can produce a real
shipping release is:

1. A release engineer runs `ManagedCatalogTool generate-key` on an
   offline, controlled machine and stores the resulting seed in a
   hardware key or secrets manager — never in this repository, never in
   any CI log or agent session transcript.
2. The resulting public key is pinned into `CatalogTrustRoot.production`
   (currently empty — see that type's doc comment) in a reviewed Kod
   release.
3. Real upstream artifacts (Node runtime, `typescript-language-server`,
   `vscode-langservers-extracted`, `pyright`, `rust-analyzer`) are fetched
   from their official release channels for both `arm64` and `x86_64`,
   digested, and assembled into a real catalog using the process above.
4. That catalog is signed with the real private key via
   `ManagedCatalogTool sign` and published over HTTPS at a URL Kod's
   release build is configured to fetch.
5. The vendoring/signing steps above are wired into a reproducible,
   attested release pipeline (mirroring whatever process
   `Scripts/vendor-ripgrep`/`Scripts/vendor-tree-sitter` eventually adopt
   for 1.0) rather than a developer-run script.

Until all five steps above happen outside this repository, Phase 8's
mechanism is fully implemented and fully tested against fixture
keys/artifacts (see `Scripts/verify-phase 8`), but `CatalogTrustRoot.production`
being empty means the shipped app correctly refuses to install
anything managed until a real key exists — which is the intended,
fail-closed behavior, not a bug.
