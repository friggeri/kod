#!/usr/bin/env python3
"""Vendor pinned Tree-sitter runtime + grammar sources.

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
    "CTreeSitterTSX": {"key": "typescript", "src_prefix": "tsx/src", "fn": "tree_sitter_tsx", "scanner": "scanner.c"},
    "CTreeSitterJavaScript": {"key": "javascript", "src_prefix": "src", "fn": "tree_sitter_javascript", "scanner": "scanner.c"},
    "CTreeSitterHTML": {"key": "html", "src_prefix": "src", "fn": "tree_sitter_html", "scanner": "scanner.c"},
    "CTreeSitterCSS": {"key": "css", "src_prefix": "src", "fn": "tree_sitter_css", "scanner": "scanner.c"},
    "CTreeSitterPython": {"key": "python", "src_prefix": "src", "fn": "tree_sitter_python", "scanner": "scanner.c"},
    "CTreeSitterRust": {"key": "rust", "src_prefix": "src", "fn": "tree_sitter_rust", "scanner": "scanner.c"},
    "CTreeSitterBash": {"key": "bash", "src_prefix": "src", "fn": "tree_sitter_bash", "scanner": "scanner.c"},
    "CTreeSitterJSON": {"key": "json", "src_prefix": "src", "fn": "tree_sitter_json"},
    "CTreeSitterYAML": {
        "key": "yaml",
        "src_prefix": "src",
        "fn": "tree_sitter_yaml",
        "scanner": "scanner.c",
        "support_sources": ["schema.core.c", "schema.json.c", "schema.legacy.c"],
    },
    "CTreeSitterTOML": {"key": "toml", "src_prefix": "src", "fn": "tree_sitter_toml", "scanner": "scanner.c"},
    "CTreeSitterMarkdown": {
        "key": "markdown",
        "src_prefix": "tree-sitter-markdown/src",
        "fn": "tree_sitter_markdown",
        "scanner": "scanner.c",
    },
    "CTreeSitterMarkdownInline": {
        "key": "markdown",
        "query_key": "markdown-inline",
        "src_prefix": "tree-sitter-markdown-inline/src",
        "fn": "tree_sitter_markdown_inline",
        "scanner": "scanner.c",
    },
    "CTreeSitterC": {
        "key": "c", "src_prefix": "src", "fn": "tree_sitter_c",
        "support_headers": ["alloc.h", "array.h"],
    },
    "CTreeSitterGo": {
        "key": "go", "src_prefix": "src", "fn": "tree_sitter_go",
        "support_headers": ["alloc.h", "array.h"],
    },
    "CTreeSitterJava": {
        "key": "java", "src_prefix": "src", "fn": "tree_sitter_java",
        "support_headers": ["alloc.h", "array.h"],
    },
    "CTreeSitterRuby": {
        "key": "ruby", "src_prefix": "src", "fn": "tree_sitter_ruby",
        "scanner": "scanner.c", "support_headers": ["alloc.h", "array.h"],
    },
    "CTreeSitterLua": {
        "key": "lua",
        "src_prefix": "src",
        "fn": "tree_sitter_lua",
        "scanner": "scanner.c",
        "license": "LICENSE.md",
        "support_headers": ["alloc.h", "array.h"],
    },
    "CTreeSitterGraphQL": {"key": "graphql", "src_prefix": "src", "fn": "tree_sitter_graphql"},
    "CTreeSitterXML": {
        "key": "xml",
        "src_prefix": "xml/src",
        "fn": "tree_sitter_xml",
        "scanner": "scanner.c",
        "common_scanner_header": "common/scanner.h",
        "support_headers": ["alloc.h", "array.h"],
    },
}

QUERY_SOURCES = {
    "swift": {"queries_prefix": "queries", "files": ["highlights.scm", "locals.scm", "injections.scm", "folds.scm"]},
    "typescript": {"queries_prefix": "queries", "files": ["highlights.scm", "locals.scm"]},
    "javascript": {"queries_prefix": "queries", "files": ["highlights.scm", "highlights-jsx.scm", "highlights-params.scm", "locals.scm", "injections.scm"]},
    "html": {"queries_prefix": "queries", "files": ["highlights.scm", "injections.scm"]},
    "css": {"queries_prefix": "queries", "files": ["highlights.scm"]},
    "python": {"queries_prefix": "queries", "files": ["highlights.scm"]},
    "rust": {"queries_prefix": "queries", "files": ["highlights.scm", "injections.scm"]},
    "bash": {"queries_prefix": "queries", "files": ["highlights.scm"]},
    "json": {"queries_prefix": "queries", "files": ["highlights.scm"]},
    # Kod's YAML query avoids upstream's overlapping key/string captures,
    # whose precedence is undefined in the decoration compositor.
    "yaml": {"files": ["highlights.scm"], "local": True},
    "toml": {"queries_prefix": "queries", "files": ["highlights.scm"]},
    "markdown": {
        "manifest_key": "markdown",
        "queries_prefix": "tree-sitter-markdown/queries",
        "files": ["highlights.scm", "injections.scm"],
    },
    "markdown-inline": {
        "manifest_key": "markdown",
        "queries_prefix": "tree-sitter-markdown-inline/queries",
        "files": ["highlights.scm", "injections.scm"],
    },
    "c": {"queries_prefix": "queries", "files": ["highlights.scm"]},
    "go": {"queries_prefix": "queries", "files": ["highlights.scm"]},
    "java": {"queries_prefix": "queries", "files": ["highlights.scm"]},
    "ruby": {"queries_prefix": "queries", "files": ["highlights.scm"]},
    "lua": {"queries_prefix": "queries", "files": ["highlights.scm"]},
    "xml": {"queries_prefix": "queries/xml", "files": ["highlights.scm"]},
    # GraphQL's pinned upstream does not ship a highlights query. This small,
    # Kod-authored query is tested by the GraphQL golden fixture below.
    "graphql": {"files": ["highlights.scm"], "local": True},
}


def fetch_grammar(target_name, cfg):
    m = MANIFEST[cfg["key"]]
    repo, commit = m["repo"], m["commit"]
    target = os.path.join(SOURCES, target_name)
    prefix = cfg["src_prefix"]
    fetch(repo, commit, f"{prefix}/parser.c", os.path.join(target, "parser.c"))
    fetch(repo, commit, f"{prefix}/tree_sitter/parser.h", os.path.join(target, "tree_sitter", "parser.h"))
    for support_header in cfg.get("support_headers", ["alloc.h", "array.h"]):
        if "support_headers" in cfg:
            fetch(
                repo,
                commit,
                f"{prefix}/tree_sitter/{support_header}",
                os.path.join(target, "tree_sitter", support_header),
            )
        else:
            try:
                fetch(
                    repo,
                    commit,
                    f"{prefix}/tree_sitter/{support_header}",
                    os.path.join(target, "tree_sitter", support_header),
                )
            except Exception:
                pass
    scanner = cfg.get("scanner")
    if scanner:
        scanner_path = os.path.join(target, scanner)
        fetch(repo, commit, f"{prefix}/{scanner}", scanner_path)
        if cfg.get("common_scanner_header"):
            with open(scanner_path, "rb") as f:
                scanner_bytes = f.read()
            scanner_bytes = scanner_bytes.replace(b'#include "../../common/scanner.h"', b'#include "common/scanner.h"')
            with open(scanner_path, "wb") as f:
                f.write(scanner_bytes)
            fetch(
                repo,
                commit,
                cfg["common_scanner_header"],
                os.path.join(target, "common", "scanner.h"),
            )
    for support_source in cfg.get("support_sources", []):
        fetch(
            repo,
            commit,
            f"{prefix}/{support_source}",
            os.path.join(target, support_source),
        )
    header_path = os.path.join(target, "include", f"{cfg['fn']}.h")
    os.makedirs(os.path.dirname(header_path), exist_ok=True)
    guard = f"{cfg['fn'].upper()}_H_"
    with open(header_path, "w", encoding="utf-8") as header:
        header.write(
            f"""#ifndef {guard}
#define {guard}

typedef struct TSLanguage TSLanguage;

#ifdef __cplusplus
extern "C" {{
#endif

const TSLanguage *{cfg["fn"]}(void);

#ifdef __cplusplus
}}
#endif

#endif
"""
        )
    fetch(repo, commit, cfg.get("license", "LICENSE"), os.path.join(target, "LICENSE-upstream.txt"))
    print(f"{target_name}: fetched grammar sources")


def fetch_queries(lang_key, dest_dir):
    cfg = QUERY_SOURCES[lang_key]
    if cfg.get("local"):
        return
    m = MANIFEST[cfg.get("manifest_key", lang_key)]
    repo, commit = m["repo"], m["commit"]
    prefix = cfg["queries_prefix"]
    if lang_key == "typescript":
        prefix = "queries"
    for fname in cfg["files"]:
        fetch(repo, commit, f"{prefix}/{fname}", os.path.join(dest_dir, fname))


def expected_projection():
    """The files fetch.py owns; used to reject incomplete or stale vendoring."""
    expected = set()
    for target_name, cfg in GRAMMARS.items():
        root = os.path.join(SOURCES, target_name)
        expected.update({
            os.path.join(root, "parser.c"),
            os.path.join(root, "tree_sitter", "parser.h"),
            os.path.join(root, "include", f"{cfg['fn']}.h"),
            os.path.join(root, "LICENSE-upstream.txt"),
        })
        if cfg.get("scanner"):
            expected.add(os.path.join(root, cfg["scanner"]))
        if cfg.get("common_scanner_header"):
            expected.add(os.path.join(root, "common", "scanner.h"))
        for header in cfg.get("support_headers", []):
            expected.add(os.path.join(root, "tree_sitter", header))
        for source in cfg.get("support_sources", []):
            expected.add(os.path.join(root, source))
    for key, cfg in QUERY_SOURCES.items():
        root = os.path.join(SOURCES, "SyntaxCore", "Resources", "Queries", key)
        expected.update(os.path.join(root, filename) for filename in cfg["files"])
    return expected


def verify():
    manifest_grammar_keys = set(MANIFEST) - {"tree-sitter"}
    projected_grammar_keys = {cfg["key"] for cfg in GRAMMARS.values()}
    if manifest_grammar_keys != projected_grammar_keys:
        print("manifest/grammar target mismatch:")
        print(f"  manifest only: {sorted(manifest_grammar_keys - projected_grammar_keys)}")
        print(f"  target only: {sorted(projected_grammar_keys - manifest_grammar_keys)}")
        return 1
    missing_query_pins = sorted({
        cfg.get("manifest_key", key)
        for key, cfg in QUERY_SOURCES.items()
    } - manifest_grammar_keys)
    if missing_query_pins:
        print(f"query projections without a manifest pin: {missing_query_pins}")
        return 1
    missing = sorted(path for path in expected_projection() if not os.path.isfile(path))
    if missing:
        print("missing vendored projection:")
        print("\n".join(f"  {os.path.relpath(path, ROOT)}" for path in missing))
        return 1
    print(f"verified {len(expected_projection())} grammar/query projection files")
    return 0


def main():
    if sys.argv[1:] == ["--verify"]:
        sys.exit(verify())
    if len(sys.argv) > 1:
        for target_name in sys.argv[1:]:
            if target_name not in GRAMMARS:
                raise RuntimeError(f"unknown grammar target: {target_name}")
            cfg = GRAMMARS[target_name]
            fetch_grammar(target_name, cfg)
            query_key = cfg.get("query_key", cfg["key"])
            if query_key in QUERY_SOURCES:
                queries_root = os.path.join(SOURCES, "SyntaxCore", "Resources", "Queries")
                fetch_queries(query_key, os.path.join(queries_root, query_key))
        return

    fetch_runtime()
    for target_name, cfg in GRAMMARS.items():
        fetch_grammar(target_name, cfg)
    queries_root = os.path.join(SOURCES, "SyntaxCore", "Resources", "Queries")
    for lang_key in QUERY_SOURCES:
        fetch_queries(lang_key, os.path.join(queries_root, lang_key))
    print("done")


if __name__ == "__main__":
    main()
