# Third-party notices

Kod vendors the following third-party source code. Each dependency is
pinned to an exact upstream commit, vendored in full (not fetched at build
or run time), and compiled directly into the app — there is no runtime
grammar-extension or plug-in mechanism. `Scripts/vendor-tree-sitter/fetch.py`
and `Scripts/vendor-tree-sitter/manifest.json` record the exact commits and
can be re-run to refresh a pin.

## Tree-sitter runtime

- **Project:** [tree-sitter/tree-sitter](https://github.com/tree-sitter/tree-sitter)
- **Pinned commit:** `64402de2857cc197ecc4ca3bc144ea91fda7e72e` (tag `v0.26.11`)
- **Vendored at:** `Packages/KodCore/Sources/CTreeSitter`
- **License:** MIT (Copyright © 2018 Max Brunsfeld) — full text at
  `Packages/KodCore/Sources/CTreeSitter/LICENSE-tree-sitter.txt`
- Also includes small UTF-8/UTF-16 conversion headers derived from ICU,
  under `Packages/KodCore/Sources/CTreeSitter/unicode`, licensed under the
  Unicode, Inc. license at
  `Packages/KodCore/Sources/CTreeSitter/unicode/LICENSE`.
- WebAssembly-based grammar loading (`TREE_SITTER_FEATURE_WASM`) is compiled
  out; Kod does not link or ship `wasmtime`.

## Tree-sitter grammars

Every grammar below is a generated parser (`parser.c`, plus an external
scanner where the grammar has one) committed by the upstream project itself
and vendored unmodified except for the internal include-path fix noted for
TypeScript.

| Language | Project | Pinned commit | Tag | Vendored at |
| --- | --- | --- | --- | --- |
| Swift | [alex-pinkus/tree-sitter-swift](https://github.com/alex-pinkus/tree-sitter-swift) | `31d17fe7e818a2048c808b5c6fdc2dc792f4f5b5` | `0.7.3-with-generated-files` | `Packages/KodCore/Sources/CTreeSitterSwift` |
| TypeScript | [tree-sitter/tree-sitter-typescript](https://github.com/tree-sitter/tree-sitter-typescript) | `f975a621f4e7f532fe322e13c4f79495e0a7b2e7` | `v0.23.2` | `Packages/KodCore/Sources/CTreeSitterTypeScript` |
| JavaScript | [tree-sitter/tree-sitter-javascript](https://github.com/tree-sitter/tree-sitter-javascript) | `44c892e0be055ac465d5eeddae6d3e194424e7de` | `v0.25.0` | `Packages/KodCore/Sources/CTreeSitterJavaScript` |
| HTML | [tree-sitter/tree-sitter-html](https://github.com/tree-sitter/tree-sitter-html) | `5a5ca8551a179998360b4a4ca2c0f366a35acc03` | `v0.23.2` | `Packages/KodCore/Sources/CTreeSitterHTML` |
| CSS | [tree-sitter/tree-sitter-css](https://github.com/tree-sitter/tree-sitter-css) | `dda5cfc5722c429eaba1c910ca32c2c0c5bb1a3f` | `v0.25.0` | `Packages/KodCore/Sources/CTreeSitterCSS` |
| Python | [tree-sitter/tree-sitter-python](https://github.com/tree-sitter/tree-sitter-python) | `293fdc02038ee2bf0e2e206711b69c90ac0d413f` | `v0.25.0` | `Packages/KodCore/Sources/CTreeSitterPython` |
| Rust | [tree-sitter/tree-sitter-rust](https://github.com/tree-sitter/tree-sitter-rust) | `77a3747266f4d621d0757825e6b11edcbf991ca5` | `v0.24.2` | `Packages/KodCore/Sources/CTreeSitterRust` |

All seven grammars are licensed under the MIT License. Each vendored
directory carries its own upstream `LICENSE-upstream.txt` copy.

The bundled `highlights.scm` (and, for Swift, `locals.scm`/`injections.scm`)
queries under `Packages/KodCore/Sources/SyntaxCore/Resources/Queries` are
vendored from the same pinned commits and carry the same MIT license as
their grammar.

## Kod-authored code that adapts third-party formats

- `ThemeCore`'s VS Code color-theme JSON import
  (`Packages/KodCore/Sources/ThemeCore/VSCodeThemeImport.swift`) reads the
  public, documented `colors`/`tokenColors`/`semanticTokenColors` JSON
  schema Visual Studio Code themes use, but contains no code copied from
  VS Code; it is original Kod code implementing an open, documented file
  format.

## ripgrep search engine

- **Project:** [BurntSushi/ripgrep](https://github.com/BurntSushi/ripgrep)
- **Pinned tag:** `14.1.1`
- **Pinned commit:** `4649aa9700619f94cf9c66876e9549d83420e16c`
- **License:** Unlicense OR MIT (dual-licensed) — full texts vendored at
  `Vendor/Licenses/ripgrep-UNLICENSE.txt`,
  `Vendor/Licenses/ripgrep-LICENSE-MIT.txt`, and
  `Vendor/Licenses/ripgrep-COPYING.txt`.
- **Vendored at:** `Packages/KodCore/Sources/SearchCore/Resources/ripgrep/`,
  as a prebuilt, stripped, ad-hoc-signed `rg` executable for each supported
  architecture (`aarch64-apple-darwin`, `x86_64-apple-darwin`), copied as an
  `SearchCore` package resource so it ships inside the app bundle with no
  runtime download, `PATH` lookup, or shell invocation. Kod always launches
  it via an absolute executable `URL` with a fixed argument array (see
  `Packages/KodCore/Sources/SearchCore/RipgrepArguments.swift`).
- Built from the vendored source with Cargo's default (non-PCRE2) feature
  set, so the binary has no dependency on a system `libpcre2`.
- `Scripts/vendor-ripgrep/manifest.json` records the pinned commit and the
  exact source-tarball SHA-256; `Scripts/vendor-ripgrep/vendor.sh` is the
  reproducible script that re-downloads that exact source, verifies the
  checksum, rebuilds both architectures with Cargo, strips debug symbols,
  ad-hoc code-signs the result, and re-vendors it — the same process used
  to produce the binaries currently checked in. Re-run it to refresh the
  pin after review.
- **Release-packaging note:** the binaries here are genuine, working
  builds for both architectures (each verified to run and report `ripgrep
  14.1.1`, including running the Intel build under Rosetta 2 on this
  Apple-silicon host) — this is not a placeholder. What remains for a
  shipping release is the standard supply-chain hardening any vendored
  binary needs before distribution: notarization/hardened-runtime
  entitlement review for the embedded executable, and wiring the
  vendoring script into a reproducible/attested CI build rather than a
  developer-run script, matching whatever process the Tree-sitter
  vendoring adopts for 1.0.

## Test-only external language servers (never bundled or shipped)

Phase 7's real-server integration tests (`Packages/KodCore/Tests/LanguageAdaptersTests`)
exercise Kod's TypeScript/JavaScript, HTML, CSS, Python, and Rust language
adapters against genuine, pinned third-party language servers. None of
these are vendored into the repository, linked into Kod, or shipped with
any build — they are installed locally, on demand, purely so the test
suite can run real protocol round trips instead of only the deterministic
`FakeLanguageServer` fixture. `Scripts/vendor-test-language-servers/setup.sh`
and its `manifest.json` record the exact pinned versions and reproduce the
installation; everything it installs lives under
`Packages/KodCore/.build/test-language-servers/`, which the repository-wide
`.build/` `.gitignore` rule already excludes. Kod-managed installation for
end users (a signed, versioned, hash-verified catalog with consent,
rollback, and no vendored third-party server binaries in this repository
either) is implemented separately — see the "Kod-managed language-server
installs (Phase 8)" section below.

| Server | Project | Pinned version | License |
| --- | --- | --- | --- |
| `typescript-language-server` | [typescript-language-server/typescript-language-server](https://github.com/typescript-language-server/typescript-language-server) | `4.3.4` (with `typescript` `5.9.3`) | Apache-2.0 |
| `vscode-html-language-server` / `vscode-css-language-server` | [microsoft/vscode-langservers-extracted](https://github.com/microsoft/vscode-langservers-extracted) | `4.10.0` | MIT |
| `pyright-langserver` | [microsoft/pyright](https://github.com/microsoft/pyright) | `1.1.407` | MIT |
| `rust-analyzer` | [rust-lang/rust-analyzer](https://github.com/rust-lang/rust-analyzer) | rustup `rust-analyzer` component for the pinned `stable-aarch64-apple-darwin` toolchain (rustc `1.95.0`) | MIT OR Apache-2.0 (dual-licensed) |

Swift's SourceKit-LSP continues to be discovered exclusively through the
active Xcode/toolchain (unchanged from Phase 6) and needs no setup here.

## Kod-managed language-server installs (Phase 8)

`ManagedLanguageServers`/`ManagedInstallController` can, with explicit
user consent, download and install a language server or its private
runtime under `~/Library/Application Support/Kod/LanguageServers` after
verifying a signed catalog and a per-artifact SHA-256 digest (SPEC 6.5).
As with the test-only servers above, **no third-party server binary,
private Node runtime, or `rust-analyzer` build is vendored into this
repository** — a real release's catalog would reference each project's
own official release artifacts, fetched and digested at release-signing
time (`Scripts/managed-install-signing/README.md`), never bundled here:

| Server | Project | License |
| --- | --- | --- |
| `typescript-language-server` | [typescript-language-server/typescript-language-server](https://github.com/typescript-language-server/typescript-language-server) | Apache-2.0 |
| `vscode-html-language-server` / `vscode-css-language-server` | [microsoft/vscode-langservers-extracted](https://github.com/microsoft/vscode-langservers-extracted) | MIT |
| `pyright-langserver` | [microsoft/pyright](https://github.com/microsoft/pyright) | MIT |
| `rust-analyzer` (standalone release artifact) | [rust-lang/rust-analyzer](https://github.com/rust-lang/rust-analyzer) | MIT OR Apache-2.0 (dual-licensed) |
| Private Node.js runtime (for the three Node-based servers above) | [nodejs/node](https://github.com/nodejs/node) | MIT (with third-party components under their own licenses, per Node's own `LICENSE`) |

`ManagedLanguageServers`'s own code — the catalog model, Ed25519
signature verification (via Apple's `CryptoKit`), the pure-Swift gzip
(`GzipCodec`, built on Apple's `Compression` framework) and USTAR tar
(`TarReader`/`TarWriter`) codecs, and `SecureArchiveExtractor`'s hostile-
archive defenses — is 100% original Kod code; no third-party archive,
compression, or signing library is vendored or linked for this. The
`FakeLanguageServer` executable this repository already builds and uses
for `LanguageClientTests`/`LanguageAdaptersTests` is reused as the
fixture "server" in `ManagedLanguageServersTests`'s offline install/
launch/upgrade/rollback/remove tests — it is Kod's own code, not a
vendored dependency.

See `Scripts/managed-install-signing/README.md` for the full
key-generation, rotation, revocation, and reproducible-artifact-generation
process, and for this environment's explicit release-provisioning gap
(no real, notarized production signing key exists here — a real release
requires an offline, human-controlled key-generation and catalog-signing
step this repository deliberately never performs on its own).

## PreviewCore (Phase 10 built-in previews)

`PreviewCore`'s Markdown parser/sanitizer, JSON/plist parsers, image
decoder, and SVG sanitizer are 100% original Kod code with **no
third-party dependency of any kind** — no vendored CommonMark/cmark, no
vendored XML/HTML parsing library, no vendored image-decoding library.
Everything is built on Apple's own frameworks already available on every
supported macOS version:

- `Foundation` — `JSONSerialization`/`PropertyListSerialization` are
  deliberately *not* used (see the README's Phase 10 section for why);
  `XMLParser` is used, with external entity resolution disabled, for XML
  property lists only.
- `ImageIO`/`CoreGraphics` — PNG/JPEG/GIF/HEIC/TIFF decode and metadata.
- `UniformTypeIdentifiers` — `UTType.json`/`UTType.propertyList`
  conformance checks used as one (never sole) signal in content
  detection.
- This repository's own `SourceModel`, `SyntaxCore`, and `ThemeCore` —
  fenced-code syntax highlighting in the Markdown renderer reuses the
  exact same pipeline `CodeViewport` uses for whole files; there is no
  second source-rendering path.

There is nothing to pin, vendor, or attribute here beyond what the
sections above already cover.

## UpdaterCore and FuzzSupport (Phase 12 release qualification)

`UpdaterCore` (the signed update-feed mechanism) and `FuzzSupport` (the
seeded fuzz/property-test harness shared by every new Phase 12 fuzz
suite) are both 100% original Kod code with **no third-party
dependency of any kind**:

- `UpdaterCore` uses only `CryptoKit` (Ed25519 signing/verification,
  exactly as `ManagedLanguageServers`' catalog signing already does),
  `Foundation`, and this repository's own `ManagedLanguageServers`
  (`SemanticVersion`/`ManagedInstallArchitecture` reuse).
- `FuzzSupport` uses only `Foundation` (a from-scratch SplitMix64
  pseudo-random generator, not a vendored fuzzing library).

`Scripts/release/`'s packaging scripts call only Apple's own
command-line tools already present on every macOS development machine
(`xcodebuild`, `codesign`, `xcrun notarytool`/`stapler`, `spctl`,
`hdiutil`, `ditto`, `shasum`) plus this repository's own
`UpdateFeedTool`/`ManagedCatalogTool` executables — nothing new to
vendor or attribute.

There is nothing to pin, vendor, or attribute here beyond what this
section already covers.

## Recording future dependencies

Every future dependency must be pinned, reviewed, and recorded here before
it is included in a build.
