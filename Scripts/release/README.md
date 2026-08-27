# Kod release pipeline

Kod v0.1.x is distributed as a Developer-ID-signed and notarized Apple
Silicon DMG. Sparkle uses a separately published ZIP and signed appcast from
the same GitHub Release.

Production releases run only through the protected manual GitHub Actions
workflow. It resolves dependencies, runs every qualification test, and
downloads/checksums Sparkle and CycloneDX tools before importing Developer ID
credentials or writing any notarization key. `package-release.sh` is
intentionally fail-closed: `preflight.sh` requires the exact annotated
`v<MARKETING_VERSION>` tag, a clean `friggeri/kod` tree, Apple Silicon, and
real signing and notarization credentials. It never packages an ad-hoc or
Intel build, and it aborts before a draft GitHub Release can be created.

## Required environment

- `KOD_CODE_SIGN_IDENTITY`
- `KOD_DEVELOPMENT_TEAM`
- `KOD_NOTARIZATION_KEYCHAIN_PROFILE`, or all three
  `KOD_NOTARIZATION_API_KEY_PATH`, `KOD_NOTARIZATION_API_KEY_ID`, and
  `KOD_NOTARIZATION_API_ISSUER_ID`
- `SPARKLE_PUBLIC_ED_KEY`
- `KOD_SWIFTPM_CLONED_SOURCE_PACKAGES_DIR`, populated by a successful
  dependency-resolution step before credentials are imported

The short, post-packaging Sparkle signing step additionally requires:

- `SPARKLE_PRIVATE_KEY`
- `KOD_SPARKLE_GENERATE_APPCAST`, pinned to Sparkle 2.9.6's
  `generate_appcast` executable
- `KOD_SPARKLE_SIGN_UPDATE`, pinned to Sparkle 2.9.6's `sign_update`
  executable

The metadata-finalization step requires `KOD_CYCLONEDX_CLI`, the checksummed
official CycloneDX CLI validator pinned by the release workflow.

The private Sparkle key exists only in the appcast-signing step and is passed
to Sparkle over standard input (`--ed-key-file -`), never as an argument.
Before metadata is finalized, the key is cryptographically challenged against
the exact `SUPublicEDKey` in the built app, the ZIP enclosure signature is
verified with that public key, and pinned Sparkle `sign_update` verifies the
signed appcast. Pinned Sparkle 2.9.6 ships
universal `arm64+x86_64` framework and helper binaries; `build-archive.sh`
thins every Sparkle Mach-O to arm64 first (`thin-macho-arm64.sh`) and
leaves non-Mach-O resources untouched. Missing helpers or a binary without
an arm64 slice fail closed. The archive is then signed inside-out with a
real Developer ID identity: Sparkle XPC services, `Updater.app`,
`Autoupdate`, the Sparkle framework, bundled ripgrep, then `Kod.app`. The
DMG is signed, and both the app and DMG are notarized and stapled. GitHub
Actions imports Apple credentials into an ephemeral keychain, keeps the
login keychain search list, and removes the ephemeral keychain at the end
of the job. `Scripts/release/test-thin-macho-arm64.sh` exercises the
thinner with local universal, arm64-only, and invalid fixtures and does
not need production credentials.

The protected `release` environment must define these secrets:

- `DEVELOPER_ID_P12_BASE64`
- `DEVELOPER_ID_P12_PASSWORD`
- `DEVELOPER_ID_APPLICATION_IDENTITY`
- `APP_STORE_CONNECT_PRIVATE_KEY`
- `SPARKLE_PRIVATE_KEY`

These non-secret Actions variables may be repository- or environment-scoped:

- `APPLE_TEAM_ID`
- `APP_STORE_CONNECT_KEY_ID`
- `APP_STORE_CONNECT_ISSUER_ID`
- `SPARKLE_PUBLIC_ED_KEY`

Generate the Sparkle key with Sparkle's official `generate_keys` tool. Retain
an offline backup of the private key. Once generated, replace
`REPLACE_WITH_SPARKLE_PUBLIC_KEY` in the Xcode project with the public key as
well as configuring the release environment.

## Output

The workflow runs `package-release.sh`, then `sign-appcast.sh`, then
`finalize-release.sh`. Together they produce:

- `Kod-0.1.0-arm64.dmg`
- `Kod-0.1.0-arm64.zip`
- `Kod-0.1.0-licenses.zip`
- `appcast.xml`
- `SHA256SUMS.txt`
- `sbom.cdx.json`
- provenance JSON for each primary artifact

`finalize-release.sh` validates the generated SBOM against CycloneDX 1.5 with
the pinned official CLI; release-specific license locations use CycloneDX
name/value properties, not unsupported fields. `.github/workflows/release.yml`
creates a draft only after every gate succeeds. The separate protected publish
workflow resolves the immutable annotated tag commit and verifies GitHub build
attestations for every distributable archive against that commit and
`.github/workflows/release.yml`; draft checksums are supplementary rather than
the trust root.

Homebrew and Intel builds are not supported for v0.1.0.
