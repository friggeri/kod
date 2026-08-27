#!/bin/sh
# Thin Mach-O binaries under a file or directory to arm64 only.
# Non-Mach-O resources are left untouched. Missing paths, non-Mach-O
# single-file inputs, and binaries without an arm64 slice fail closed.
#
# Usage: Scripts/release/thin-macho-arm64.sh <file-or-directory>

set -eu
set -o pipefail

export LC_ALL=C

target=${1:-}
if [ -z "$target" ]; then
    printf '%s\n' "Usage: $0 <file-or-directory>" >&2
    exit 64
fi
if [ ! -e "$target" ]; then
    printf '%s\n' "BLOCKED: missing path: $target" >&2
    exit 65
fi

thin_tmp=
cleanup_thin_tmp() {
    if [ -n "${thin_tmp:-}" ] && [ -e "$thin_tmp" ]; then
        rm -f -- "$thin_tmp"
    fi
}
trap cleanup_thin_tmp EXIT HUP INT TERM

is_mach_o() {
    case "$(file -b "$1")" in
        *Mach-O*)
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

require_arm64_only() {
    verified_architectures=$(lipo -archs "$1")
    if [ "$verified_architectures" != "arm64" ]; then
        printf '%s\n' "BLOCKED: expected arm64-only code, found '$verified_architectures': $1" >&2
        exit 65
    fi
}

has_arm64_slice() {
    for slice_arch in $(lipo -archs "$1"); do
        if [ "$slice_arch" = "arm64" ]; then
            return 0
        fi
    done
    return 1
}

thin_one() {
    candidate=$1
    if [ ! -f "$candidate" ]; then
        printf '%s\n' "BLOCKED: missing Mach-O: $candidate" >&2
        exit 65
    fi
    if ! is_mach_o "$candidate"; then
        printf '%s\n' "BLOCKED: not a Mach-O: $candidate" >&2
        exit 65
    fi
    source_architectures=$(lipo -archs "$candidate")
    if ! has_arm64_slice "$candidate"; then
        printf '%s\n' "BLOCKED: no arm64 slice in '$source_architectures': $candidate" >&2
        exit 65
    fi
    if [ "$source_architectures" = "arm64" ]; then
        printf '%s\n' "    already arm64: $candidate"
        require_arm64_only "$candidate"
        return 0
    fi

    thin_tmp="${candidate}.arm64-thin.$$"
    rm -f -- "$thin_tmp"
    mode=$(stat -f '%Lp' "$candidate")
    lipo -thin arm64 "$candidate" -output "$thin_tmp"
    chmod "$mode" "$thin_tmp"
    mv -f -- "$thin_tmp" "$candidate"
    thin_tmp=
    require_arm64_only "$candidate"
    printf '%s\n' "    thinned ($source_architectures -> arm64): $candidate"
}

thinned_count=0
if [ -f "$target" ]; then
    thin_one "$target"
    thinned_count=1
elif [ -d "$target" ]; then
    while IFS= read -r candidate; do
        [ -n "$candidate" ] || continue
        if is_mach_o "$candidate"; then
            thin_one "$candidate"
            thinned_count=$((thinned_count + 1))
        fi
    done <<EOF
$(find "$target" -type f)
EOF
    if [ "$thinned_count" -eq 0 ]; then
        printf '%s\n' "BLOCKED: no Mach-O files found under $target" >&2
        exit 65
    fi
else
    printf '%s\n' "BLOCKED: not a regular file or directory: $target" >&2
    exit 65
fi

printf '%s\n' "==> Thinned $thinned_count Mach-O file(s) to arm64"
