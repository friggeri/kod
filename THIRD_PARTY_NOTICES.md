# Third-party notices

Kod includes or adapts the following third-party work. Third-party work shipped
in Kod is pinned to exact upstream commits, included locally, and never fetched
at build or run time. Test-only tooling that is not shipped is called out
separately.

## PVC color themes

- **Project:** [friggeri/pvc-theme](https://github.com/friggeri/pvc-theme)
- **Pinned commit:** `43592b1ff36944cff69f8de973f96dcb5a901d91` (version `1.0.8`)
- **Adapted at:** `Packages/KodCore/Sources/ThemeCore/BundledThemes.swift`
- **Changes:** PVC (Light) and PVC (Dark) are adapted to Kod's native theme
  schema and exposed as Kod Light and Kod Dark.
- **License:** MIT (Copyright 2022 Adrien Friggeri) — full text at
  `Vendor/Licenses/pvc-theme-LICENSE.txt`.

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
- `Scripts/vendor-tree-sitter/fetch.py` and
  `Scripts/vendor-tree-sitter/manifest.json` record the exact commits and can
  be re-run to refresh a pin.

## Tree-sitter grammars

Every grammar below is a generated parser (`parser.c`, plus an external
scanner where the grammar has one) committed by the upstream project itself
and vendored unmodified except for the internal include-path fix noted for
TypeScript.

| Language | Project | Pinned commit | Tag | Vendored at |
| --- | --- | --- | --- | --- |
| Swift | [alex-pinkus/tree-sitter-swift](https://github.com/alex-pinkus/tree-sitter-swift) | `31d17fe7e818a2048c808b5c6fdc2dc792f4f5b5` | `0.7.3-with-generated-files` | `Packages/KodCore/Sources/CTreeSitterSwift` |
| TypeScript / TSX | [tree-sitter/tree-sitter-typescript](https://github.com/tree-sitter/tree-sitter-typescript) | `f975a621f4e7f532fe322e13c4f79495e0a7b2e7` | `v0.23.2` | `Packages/KodCore/Sources/CTreeSitterTypeScript` and `Packages/KodCore/Sources/CTreeSitterTSX` |
| JavaScript | [tree-sitter/tree-sitter-javascript](https://github.com/tree-sitter/tree-sitter-javascript) | `44c892e0be055ac465d5eeddae6d3e194424e7de` | `v0.25.0` | `Packages/KodCore/Sources/CTreeSitterJavaScript` |
| HTML | [tree-sitter/tree-sitter-html](https://github.com/tree-sitter/tree-sitter-html) | `5a5ca8551a179998360b4a4ca2c0f366a35acc03` | `v0.23.2` | `Packages/KodCore/Sources/CTreeSitterHTML` |
| CSS | [tree-sitter/tree-sitter-css](https://github.com/tree-sitter/tree-sitter-css) | `dda5cfc5722c429eaba1c910ca32c2c0c5bb1a3f` | `v0.25.0` | `Packages/KodCore/Sources/CTreeSitterCSS` |
| Python | [tree-sitter/tree-sitter-python](https://github.com/tree-sitter/tree-sitter-python) | `293fdc02038ee2bf0e2e206711b69c90ac0d413f` | `v0.25.0` | `Packages/KodCore/Sources/CTreeSitterPython` |
| Rust | [tree-sitter/tree-sitter-rust](https://github.com/tree-sitter/tree-sitter-rust) | `77a3747266f4d621d0757825e6b11edcbf991ca5` | `v0.24.2` | `Packages/KodCore/Sources/CTreeSitterRust` |
| Shell | [tree-sitter/tree-sitter-bash](https://github.com/tree-sitter/tree-sitter-bash) | `a06c2e4415e9bc0346c6b86d401879ffb44058f7` | `v0.25.1` | `Packages/KodCore/Sources/CTreeSitterBash` |
| JSON | [tree-sitter/tree-sitter-json](https://github.com/tree-sitter/tree-sitter-json) | `ee35a6ebefcef0c5c416c0d1ccec7370cfca5a24` | `v0.24.8` | `Packages/KodCore/Sources/CTreeSitterJSON` |
| YAML | [tree-sitter-grammars/tree-sitter-yaml](https://github.com/tree-sitter-grammars/tree-sitter-yaml) | `7708026449bed86239b1cd5bce6e3c34dbca6415` | `v0.7.2` | `Packages/KodCore/Sources/CTreeSitterYAML` |
| TOML | [tree-sitter-grammars/tree-sitter-toml](https://github.com/tree-sitter-grammars/tree-sitter-toml) | `64b56832c2cffe41758f28e05c756a3a98d16f41` | `v0.7.0` | `Packages/KodCore/Sources/CTreeSitterTOML` |
| Markdown (block and inline) | [tree-sitter-grammars/tree-sitter-markdown](https://github.com/tree-sitter-grammars/tree-sitter-markdown) | `f969cd3ae3f9fbd4e43205431d0ae286014c05b5b` | `v0.5.3` | `Packages/KodCore/Sources/CTreeSitterMarkdown` and `Packages/KodCore/Sources/CTreeSitterMarkdownInline` |
| C | [tree-sitter/tree-sitter-c](https://github.com/tree-sitter/tree-sitter-c) | `b780e47fc780ddc8da13afa35a3f4ed5c157823d` | `v0.24.2` | `Packages/KodCore/Sources/CTreeSitterC` |
| Go | [tree-sitter/tree-sitter-go](https://github.com/tree-sitter/tree-sitter-go) | `1547678a9da59885853f5f5cc8a99cc203fa2e2c` | `v0.25.0` | `Packages/KodCore/Sources/CTreeSitterGo` |
| Java | [tree-sitter/tree-sitter-java](https://github.com/tree-sitter/tree-sitter-java) | `94703d5a6bed02b98e438d7cad1136c01a60ba2c` | `v0.23.5` | `Packages/KodCore/Sources/CTreeSitterJava` |
| Ruby | [tree-sitter/tree-sitter-ruby](https://github.com/tree-sitter/tree-sitter-ruby) | `71bd32fb7607035768799732addba884a37a6210` | `v0.23.1` | `Packages/KodCore/Sources/CTreeSitterRuby` |
| Lua | [tree-sitter-grammars/tree-sitter-lua](https://github.com/tree-sitter-grammars/tree-sitter-lua) | `10fe0054734eec83049514ea2e718b2a56acd0c9` | `v0.5.0` | `Packages/KodCore/Sources/CTreeSitterLua` |
| GraphQL | [bkegley/tree-sitter-graphql](https://github.com/bkegley/tree-sitter-graphql) | `5e66e961eee421786bdda8495ed1db045e06b5fe` | unreleased | `Packages/KodCore/Sources/CTreeSitterGraphQL` |
| XML | [tree-sitter-grammars/tree-sitter-xml](https://github.com/tree-sitter-grammars/tree-sitter-xml) | `4b64dd3a03ec002258d6268d712fd93716d6ab57` | `v0.7.0` | `Packages/KodCore/Sources/CTreeSitterXML` |

All twenty-one parser targets are licensed under the MIT License. Each vendored
directory carries its own upstream `LICENSE-upstream.txt` copy.

The bundled `highlights.scm` (and, for Swift, `locals.scm`/`injections.scm`)
queries under `Packages/KodCore/Sources/SyntaxCore/Resources/Queries` are
vendored from the same pinned commits and carry the same MIT license as their
grammar, except GraphQL's small Kod-authored highlights query: its pinned
upstream does not ship one. The vendoring script records it as local and its
fixture/golden test validates its node names and captures. XML's external
scanner includes the upstream shared scanner header; its vendored include path
is adjusted in the same reproducible script for the target-local header path.

## Kod-authored code that adapts third-party formats

- `ThemeCore`'s VS Code color-theme JSON import
  (`Packages/KodCore/Sources/ThemeCore/VSCodeThemeImport.swift`) reads the
  public, documented `colors`/`tokenColors`/`semanticTokenColors` JSON
  schema Visual Studio Code themes use, but contains no code copied from
  VS Code; it is original Kod code implementing an open, documented file
  format.

## Visual Studio Code minimap design reference

- **Project:** [microsoft/vscode](https://github.com/microsoft/vscode)
- **Pinned commit:** `ec07db383765ac7e9784e1eb32bf4a7350e33a26`
- **Reference files:** `src/vs/editor/browser/viewParts/minimap/minimap.ts`,
  `minimapCharRendererFactory.ts`, `minimapCharSheet.ts`,
  `minimapTokensColorTracker.ts`, editor minimap options, and minimap theme
  color declarations.
- **Use:** Architectural research for separating proportional layout, bounded
  base pixels, decorations, token-color invalidation, glyph masks, and slider
  interaction. Kod's implementation is original Swift/AppKit code and does not
  copy or ship VS Code TypeScript or assets.
- **License:** MIT (Copyright Microsoft Corporation), as declared by the pinned
  upstream repository.

## Material Icon Theme

- **Project:** [material-extensions/vscode-material-icon-theme](https://github.com/material-extensions/vscode-material-icon-theme)
- **Pinned version:** `5.37.0` (commit
  `957d82b494e5737ef7b3c63e4d01f756d73a9936`)
- **License:** MIT (Copyright 2025 Material Extensions) — full text at
  `Vendor/Licenses/material-icon-theme-LICENSE.txt`.
- **Vendored at:** `Packages/KodUI/Sources/KodUIComponents/MaterialIcons/`,
  shipped as a `KodUIComponents` package resource and loaded through that
  target's own `Bundle.module`. Kod ships the upstream SVGs
  referenced by its file-name, compound-extension, and light-appearance
  mappings. Folder mappings and unused SVGs are omitted.
- **Source integrity:** npm tarball SHA-512
  `/F5llOVU0DZ88V+wmPlEbBqi8FochPg5XaJ7zqVzGCTTygeFnpIpdVQQTRElEnHyxSWRMfF0wBbOqwFKnujFLA==`.

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

Real-server integration tests (`Packages/KodCore/Tests/LanguageAdaptersTests`)
exercise Kod's TypeScript/JavaScript, HTML, CSS, Python, Rust, shell, Markdown,
JSON, YAML, and TOML language
adapters against genuine, pinned third-party language servers. None of
these are vendored into the repository, linked into Kod, or shipped with
any build — they are installed locally, on demand, purely so the test
suite can run real protocol round trips instead of only the deterministic
`FakeLanguageServer` fixture. `Scripts/vendor-test-language-servers/setup.sh`
and its `manifest.json` record the exact pinned versions and reproduce the
installation; everything it installs lives under
`Packages/KodCore/.build/test-language-servers/`, which the repository-wide
`.build/` `.gitignore` rule already excludes. These dependencies are test
fixtures only. Kod does not download or install language servers for users.

| Server | Project | Pinned version | License |
| --- | --- | --- | --- |
| `typescript-language-server` | [typescript-language-server/typescript-language-server](https://github.com/typescript-language-server/typescript-language-server) | `4.3.4` (with `typescript` `5.9.3`) | Apache-2.0 |
| `vscode-html-language-server` / `vscode-css-language-server` / `vscode-json-language-server` | [hrsh7th/vscode-langservers-extracted](https://github.com/hrsh7th/vscode-langservers-extracted) | `4.10.0` | MIT |
| `pyright-langserver` | [microsoft/pyright](https://github.com/microsoft/pyright) | `1.1.407` | MIT |
| `rust-analyzer` | [rust-lang/rust-analyzer](https://github.com/rust-lang/rust-analyzer) | rustup `rust-analyzer` component for the pinned `stable-aarch64-apple-darwin` toolchain (rustc `1.95.0`) | MIT OR Apache-2.0 (dual-licensed) |
| `bash-language-server` | [bash-lsp/bash-language-server](https://github.com/bash-lsp/bash-language-server) | `5.6.0` | MIT |
| `yaml-language-server` | [redhat-developer/yaml-language-server](https://github.com/redhat-developer/yaml-language-server) | `1.24.0` | MIT |
| Marksman | [artempyanykh/marksman](https://github.com/artempyanykh/marksman) | `2026-02-08` | MIT |
| Tombi | [tombi-toml/tombi](https://github.com/tombi-toml/tombi) | `1.2.10` | MIT |

Swift's SourceKit-LSP continues to be discovered exclusively through the
active Xcode/toolchain (unchanged from Phase 6) and needs no setup here.

## cmark-gfm

- **Project:** [github/cmark-gfm](https://github.com/github/cmark-gfm)
- **Pinned release:** `0.29.0.gfm.13`
- **Pinned commit:** `587a12bb54d95ac37241377e6ddc93ea0e45439b`
- **Vendored at:** `Packages/KodCore/Sources/CCMarkGFM` and
  `Packages/KodCore/Sources/CCMarkGFMExtensions`
- **License:** BSD-2-Clause with the upstream COPYING file's included MIT and
  derivative-work notices — complete text at
  `Packages/KodCore/Sources/CCMarkGFM/LICENSE-cmark-gfm.txt`; binary release
  archives include the same text as
  `THIRD_PARTY_LICENSES/cmark-gfm-COPYING.txt`.
- **Use:** formal CommonMark/GFM parsing only. Kod enables table, tasklist,
  strikethrough, autolink, and tagfilter; footnotes are not enabled. Kod does
  not use cmark's HTML renderer or dynamic extension loading.
- **Reproducibility:** `Scripts/vendor-cmark-gfm/manifest.json` records the
  source archive SHA-256 and compiled file set;
  `Scripts/vendor-cmark-gfm/fetch.py --verify` re-downloads the exact archive,
  verifies it, and byte-compares every vendored upstream file.

## github-markdown-css design reference

- **Project:** [sindresorhus/github-markdown-css](https://github.com/sindresorhus/github-markdown-css)
- **Pinned commit:** `e49401776c9d581ad42367fc4ea3d677d13e2e39`
- **License:** MIT (Copyright Sindre Sorhus) — full text at
  `Vendor/Licenses/github-markdown-css-LICENSE.txt`; binary release archives
  include it under `THIRD_PARTY_LICENSES/`.
- **Use:** reviewed design reference for Markdown hierarchy and spacing only.
  Kod does not vendor, bundle, parse, or execute the CSS; the corresponding
  AppKit translation is documented at
  `Vendor/DesignReferences/github-markdown-css.md`.

## PreviewCore (Phase 10 built-in previews)

Except for the pinned cmark-gfm parser above, `PreviewCore`'s safe Markdown AST
conversion/sanitization/render model, JSON/plist parsers, image decoder, and SVG
sanitizer are original Kod code. They use Apple's frameworks available on every
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

No other preview dependency is fetched or resolved at build or runtime.

## UpdaterCore and FuzzSupport (Phase 12 release qualification)

`UpdaterCore` (the signed update-feed mechanism) and `FuzzSupport` (the
seeded fuzz/property-test harness shared by every new Phase 12 fuzz
suite) are both 100% original Kod code with **no third-party
dependency of any kind**:

- `UpdaterCore` uses only `CryptoKit` (Ed25519 signing/verification) and
  `Foundation`; its semantic-version and release-architecture models are
  owned by `UpdaterCore`.
- `FuzzSupport` uses only `Foundation` (a from-scratch SplitMix64
  pseudo-random generator, not a vendored fuzzing library).

`Scripts/release/`'s packaging scripts call only Apple's own
command-line tools already present on every macOS development machine
(`xcodebuild`, `codesign`, `xcrun notarytool`/`stapler`, `spctl`,
`hdiutil`, `ditto`, `shasum`) plus this repository's own
`UpdateFeedTool` executable — nothing new to
vendor or attribute.

There is nothing to pin, vendor, or attribute here beyond what this
section already covers.

## Recording future dependencies

Every future dependency must be pinned, reviewed, and recorded here before
it is included in a build.
