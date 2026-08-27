#!/bin/sh
# Sets up pinned, real language server installations
# purely so `LanguageAdaptersTests` can run genuine, headless protocol
# tests against them (SPEC 6.5's built-in language adapters, including
# shell, Markdown, JSON, YAML, and TOML). This script is NOT part of the
# Kod app or its build, and nothing it installs is bundled into a release
# build or made available to end users by Kod. Versions are pinned in
# manifest.json; re-run this
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
set -o pipefail

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
bash_language_server_version=$(read_pin "['bash-language-server']['version']")
yaml_language_server_version=$(read_pin "['yaml-language-server']['version']")
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
    "vscode-langservers-extracted": "$vscode_langservers_version",
    "bash-language-server": "$bash_language_server_version",
    "yaml-language-server": "$yaml_language_server_version"
  }
}
EOF
(cd "$install_dir" && npm install --no-audit --no-fund --silent)

native_dir="$install_dir/native"
mkdir -p "$native_dir"

download_verified() {
    url=$1
    expected_sha256=$2
    destination=$3
    temporary="$destination.download"
    curl --fail --location --silent --show-error "$url" --output "$temporary"
    actual_sha256=$(shasum -a 256 "$temporary" | awk '{print $1}')
    if [ "$actual_sha256" != "$expected_sha256" ]; then
        rm -f "$temporary"
        printf '%s\n' "Digest mismatch for $url" >&2
        exit 1
    fi
    mv "$temporary" "$destination"
}

marksman_url=$(read_pin "['marksman']['url']")
marksman_sha256=$(read_pin "['marksman']['sha256']")
printf '%s\n' "==> Installing pinned Marksman"
download_verified "$marksman_url" "$marksman_sha256" "$native_dir/marksman"
chmod 755 "$native_dir/marksman"

machine_arch=$(uname -m)
case "$machine_arch" in
    arm64) manifest_arch=arm64 ;;
    *)
        printf '%s\n' "Kod v0.1.x test servers require Apple Silicon; found $machine_arch." >&2
        exit 1
        ;;
esac
tombi_url=$(read_pin "['tombi']['artifacts']['$manifest_arch']['url']")
tombi_sha256=$(read_pin "['tombi']['artifacts']['$manifest_arch']['sha256']")
tombi_archive="$native_dir/tombi.tar.gz"
tombi_extract="$native_dir/tombi-extract"
printf '%s\n' "==> Installing pinned Tombi"
download_verified "$tombi_url" "$tombi_sha256" "$tombi_archive"
rm -rf "$tombi_extract"
mkdir -p "$tombi_extract"
tar -xzf "$tombi_archive" -C "$tombi_extract"
tombi_binary=$(find "$tombi_extract" -type f -name tombi -print -quit)
if [ -z "$tombi_binary" ]; then
    printf '%s\n' "Tombi archive did not contain a tombi executable" >&2
    exit 1
fi
cp "$tombi_binary" "$native_dir/tombi"
chmod 755 "$native_dir/tombi"
rm -rf "$tombi_extract"
rm -f "$tombi_archive"

printf '%s\n' "==> Installing pinned pyright ($pyright_version) into a local venv"
python3 -m venv "$install_dir/pyright-venv"
"$install_dir/pyright-venv/bin/pip" install --quiet "pyright==$pyright_version"

printf '%s\n' "==> Ensuring the pinned rustup 'rust-analyzer' component is installed"
if ! command -v rustup >/dev/null 2>&1; then
    printf '%s\n' "BLOCKED: rustup is required to provision rust-analyzer for Phase 7+ verification." >&2
    exit 1
fi
rustup component add rust-analyzer
if ! rustup which rust-analyzer >/dev/null 2>&1; then
    printf '%s\n' "BLOCKED: rust-analyzer is not available after rustup component add." >&2
    exit 1
fi

printf '%s\n' "==> Done. Installed executables:"
printf '%s\n' "    $install_dir/node_modules/.bin/typescript-language-server"
printf '%s\n' "    $install_dir/node_modules/.bin/vscode-html-language-server"
printf '%s\n' "    $install_dir/node_modules/.bin/vscode-css-language-server"
printf '%s\n' "    $install_dir/node_modules/.bin/vscode-json-language-server"
printf '%s\n' "    $install_dir/node_modules/.bin/bash-language-server"
printf '%s\n' "    $install_dir/node_modules/.bin/yaml-language-server"
printf '%s\n' "    $install_dir/pyright-venv/bin/pyright-langserver"
printf '%s\n' "    $native_dir/marksman"
printf '%s\n' "    $native_dir/tombi"
if command -v rustup >/dev/null 2>&1; then
    printf '%s\n' "    $(rustup which rust-analyzer 2>/dev/null || echo '<rust-analyzer component unavailable>')"
fi
