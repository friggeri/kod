#!/bin/sh
# Sets up pinned, real (non-Kod-managed) language server installations
# purely so `LanguageAdaptersTests` can run genuine, headless protocol
# tests against them (SPEC 6.5's TypeScript/JavaScript, HTML/CSS, and
# Python adapters, plus Rust's `rust-analyzer` via a pinned `rustup`
# component). This script is NOT part of the Kod app or its build, and
# nothing it installs is bundled into a release build — Kod-managed
# installation for end users (a signed, versioned catalog with
# consent/rollback) is implemented separately in the `ManagedLanguageServers`
# package (Phase 8); its own tests are fully offline and need no setup
# from this script. Versions are pinned in manifest.json; re-run this
# script to (re)provision them after a clean checkout, matching `Scripts/vendor-ripgrep`'s and
# `Scripts/vendor-tree-sitter`'s existing "how this was produced, and
# how to reproduce it" convention.
#
# Everything installed by this script lives under
# Packages/KodCore/.build/test-language-servers/, which is already
# covered by the repository-wide `.build/` gitignore rule — nothing here
# is ever committed.
#
# Requirements: npm (Node.js), python3, rustup. Swift's SourceKit-LSP is
# discovered separately through the active Xcode toolchain (unchanged
# from Phase 6) and needs no setup here.

set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
repository_root=$(CDPATH= cd -- "$script_dir/../.." && pwd)
install_dir="$repository_root/Packages/KodCore/.build/test-language-servers"
manifest="$script_dir/manifest.json"

read_pin() {
    python3 -c "import json; print(json.load(open('$manifest'))['pinned']$1)"
}

ts_version=$(read_pin "['typescript-language-server']['version']")
typescript_version=$(read_pin "['typescript-language-server']['peerPackages']['typescript']")
vscode_langservers_version=$(read_pin "['vscode-langservers-extracted']['version']")
pyright_version=$(read_pin "['pyright']['version']")

mkdir -p "$install_dir"

printf '%s\n' "==> Installing pinned npm-distributed servers into $install_dir"
cat > "$install_dir/package.json" << EOF
{
  "name": "kod-test-language-servers",
  "private": true,
  "version": "1.0.0",
  "dependencies": {
    "typescript": "$typescript_version",
    "typescript-language-server": "$ts_version",
    "vscode-langservers-extracted": "$vscode_langservers_version"
  }
}
EOF
(cd "$install_dir" && npm install --no-audit --no-fund --silent)

printf '%s\n' "==> Installing pinned pyright ($pyright_version) into a local venv"
python3 -m venv "$install_dir/pyright-venv"
"$install_dir/pyright-venv/bin/pip" install --quiet "pyright==$pyright_version"

printf '%s\n' "==> Ensuring the pinned rustup 'rust-analyzer' component is installed"
if command -v rustup >/dev/null 2>&1; then
    rustup component add rust-analyzer >/dev/null 2>&1 || true
else
    printf '%s\n' "rustup not found; skipping rust-analyzer setup (RustLanguageAdapter's integration test will report it as the missing executable)." >&2
fi

printf '%s\n' "==> Done. Installed executables:"
printf '%s\n' "    $install_dir/node_modules/.bin/typescript-language-server"
printf '%s\n' "    $install_dir/node_modules/.bin/vscode-html-language-server"
printf '%s\n' "    $install_dir/node_modules/.bin/vscode-css-language-server"
printf '%s\n' "    $install_dir/pyright-venv/bin/pyright-langserver"
if command -v rustup >/dev/null 2>&1; then
    printf '%s\n' "    $(rustup which rust-analyzer 2>/dev/null || echo '<rust-analyzer component unavailable>')"
fi
