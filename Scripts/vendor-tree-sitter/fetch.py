#!/usr/bin/env python3
"""One-time vendoring script for pinned Tree-sitter runtime + grammar sources.

This script is NOT part of the build; it is a record of how the vendored
sources under Packages/KodCore/Sources/CTreeSitter* were produced, and can be
re-run to refresh them against the same pinned commits. All commits are
pinned to tagged upstream releases (see manifest.json).
"""
import json
import os
import sys
import urllib.request

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
SOURCES = os.path.join(ROOT, "Packages", "KodCore", "Sources")

with open(os.path.join(os.path.dirname(__file__), "manifest.json")) as f:
    MANIFEST = json.load(f)


def raw_url(repo, commit, path):
    return f"https://raw.githubusercontent.com/{repo}/{commit}/{path}"


def fetch(repo, commit, path, dest):
    url = raw_url(repo, commit, path)
    os.makedirs(os.path.dirname(dest), exist_ok=True)
    req = urllib.request.Request(url, headers={"User-Agent": "kod-vendor-fetch"})
    with urllib.request.urlopen(req, timeout=60) as resp:
        data = resp.read()
    if data.startswith(b"404: Not Found") or len(data) == 0:
        raise RuntimeError(f"failed to fetch {url}")
    with open(dest, "wb") as f:
        f.write(data)
    return len(data)


def fetch_runtime():
    m = MANIFEST["tree-sitter"]
    repo, commit = m["repo"], m["commit"]
    target = os.path.join(SOURCES, "CTreeSitter")
    files = [
        ("lib/include/tree_sitter/api.h", "include/tree_sitter/api.h"),
        ("lib/src/lib.c", "lib.c"),
        ("lib/src/alloc.c", "alloc.c"),
        ("lib/src/alloc.h", "alloc.h"),
        ("lib/src/array.h", "array.h"),
        ("lib/src/atomic.h", "atomic.h"),
        ("lib/src/error_costs.h", "error_costs.h"),
        ("lib/src/get_changed_ranges.c", "get_changed_ranges.c"),
        ("lib/src/get_changed_ranges.h", "get_changed_ranges.h"),
        ("lib/src/host.h", "host.h"),
        ("lib/src/language.c", "language.c"),
        ("lib/src/language.h", "language.h"),
        ("lib/src/length.h", "length.h"),
        ("lib/src/lexer.c", "lexer.c"),
        ("lib/src/lexer.h", "lexer.h"),
        ("lib/src/node.c", "node.c"),
        ("lib/src/parser.c", "parser.c"),
        ("lib/src/parser.h", "parser.h"),
        ("lib/src/point.c", "point.c"),
        ("lib/src/point.h", "point.h"),
        ("lib/src/query.c", "query.c"),
        ("lib/src/reduce_action.h", "reduce_action.h"),
        ("lib/src/reusable_node.h", "reusable_node.h"),
        ("lib/src/stack.c", "stack.c"),
        ("lib/src/stack.h", "stack.h"),
        ("lib/src/subtree.c", "subtree.c"),
        ("lib/src/subtree.h", "subtree.h"),
        ("lib/src/tree.c", "tree.c"),
        ("lib/src/tree.h", "tree.h"),
        ("lib/src/tree_cursor.c", "tree_cursor.c"),
        ("lib/src/tree_cursor.h", "tree_cursor.h"),
        ("lib/src/ts_assert.h", "ts_assert.h"),
        ("lib/src/unicode.h", "unicode.h"),
        ("lib/src/wasm_store.c", "wasm_store.c"),
        ("lib/src/wasm_store.h", "wasm_store.h"),
        ("lib/src/unicode/ptypes.h", "unicode/ptypes.h"),
        ("lib/src/unicode/umachine.h", "unicode/umachine.h"),
        ("lib/src/unicode/urename.h", "unicode/urename.h"),
        ("lib/src/unicode/utf.h", "unicode/utf.h"),
        ("lib/src/unicode/utf16.h", "unicode/utf16.h"),
        ("lib/src/unicode/utf8.h", "unicode/utf8.h"),
        ("lib/src/unicode/LICENSE", "unicode/LICENSE"),
        ("lib/src/portable/endian.h", "portable/endian.h"),
        ("LICENSE", "LICENSE-tree-sitter.txt"),
    ]
    for src, dst in files:
        fetch(repo, commit, src, os.path.join(target, dst))
    print(f"runtime: fetched {len(files)} files")


GRAMMARS = {
    "CTreeSitterSwift": {"key": "swift", "src_prefix": "src", "fn": "tree_sitter_swift", "scanner": "scanner.c"},
    "CTreeSitterTypeScript": {"key": "typescript", "src_prefix": "typescript/src", "fn": "tree_sitter_typescript", "scanner": "scanner.c"},
    "CTreeSitterJavaScript": {"key": "javascript", "src_prefix": "src", "fn": "tree_sitter_javascript", "scanner": "scanner.c"},
    "CTreeSitterHTML": {"key": "html", "src_prefix": "src", "fn": "tree_sitter_html", "scanner": "scanner.c"},
    "CTreeSitterCSS": {"key": "css", "src_prefix": "src", "fn": "tree_sitter_css", "scanner": "scanner.c"},
    "CTreeSitterPython": {"key": "python", "src_prefix": "src", "fn": "tree_sitter_python", "scanner": "scanner.c"},
    "CTreeSitterRust": {"key": "rust", "src_prefix": "src", "fn": "tree_sitter_rust", "scanner": "scanner.c"},
}

QUERY_SOURCES = {
    "swift": {"queries_prefix": "queries", "files": ["highlights.scm", "locals.scm", "injections.scm", "folds.scm"]},
    "typescript": {"queries_prefix": "queries", "files": ["highlights.scm", "locals.scm"]},
    "javascript": {"queries_prefix": "queries", "files": ["highlights.scm", "highlights-jsx.scm", "highlights-params.scm", "locals.scm", "injections.scm"]},
    "html": {"queries_prefix": "queries", "files": ["highlights.scm", "injections.scm"]},
    "css": {"queries_prefix": "queries", "files": ["highlights.scm"]},
    "python": {"queries_prefix": "queries", "files": ["highlights.scm"]},
    "rust": {"queries_prefix": "queries", "files": ["highlights.scm", "injections.scm"]},
}


def fetch_grammar(target_name, cfg):
    m = MANIFEST[cfg["key"]]
    repo, commit = m["repo"], m["commit"]
    target = os.path.join(SOURCES, target_name)
    prefix = cfg["src_prefix"]
    fetch(repo, commit, f"{prefix}/parser.c", os.path.join(target, "parser.c"))
    fetch(repo, commit, f"{prefix}/tree_sitter/parser.h", os.path.join(target, "tree_sitter", "parser.h"))
    try:
        fetch(repo, commit, f"{prefix}/{cfg['scanner']}", os.path.join(target, cfg["scanner"]))
    except Exception as e:
        print(f"  (no external scanner for {target_name}: {e})")
    fetch(repo, commit, "LICENSE", os.path.join(target, "LICENSE-upstream.txt"))
    print(f"{target_name}: fetched grammar sources")


def fetch_queries(lang_key, dest_dir):
    m = MANIFEST[lang_key]
    repo, commit = m["repo"], m["commit"]
    cfg = QUERY_SOURCES[lang_key]
    prefix = cfg["queries_prefix"]
    if lang_key == "typescript":
        prefix = "queries"
    for fname in cfg["files"]:
        try:
            fetch(repo, commit, f"{prefix}/{fname}", os.path.join(dest_dir, fname))
        except Exception as e:
            print(f"  (missing query {lang_key}/{fname}: {e})")


def main():
    fetch_runtime()
    for target_name, cfg in GRAMMARS.items():
        fetch_grammar(target_name, cfg)
    queries_root = os.path.join(SOURCES, "SyntaxCore", "Resources", "Queries")
    for lang_key in QUERY_SOURCES:
        fetch_queries(lang_key, os.path.join(queries_root, lang_key))
    print("done")


if __name__ == "__main__":
    main()
