# Tree-sitter grammar qualification

`manifest.json` pins every vendored upstream commit. Run
`python3 Scripts/vendor-tree-sitter/fetch.py <target>` to refresh one declared
target, then run `python3 Scripts/vendor-tree-sitter/fetch.py --verify`.
Verification checks the grammar and query projection expected by `fetch.py`;
it prevents a manifest/configuration change from silently omitting a generated
parser, scanner, public header, license, or query.

GraphQL and YAML use Kod-owned highlight queries. GraphQL's pinned upstream
does not ship one; YAML's local query keeps mapping keys and scalar values
non-overlapping so theme precedence remains deterministic.

## Qualified grammars

The current quality-gated expansion compiles C, Go, Java, Ruby, Lua, GraphQL,
and XML. Each has a pinned generated parser, required scanner/helper sources,
license copy, compiling highlight query, representative golden, and malformed
input coverage. XML routing metadata also covers `svg`, `xsd`, `xsl`, `xslt`,
textual `plist`, and common exact XML file names.

The added source footprint is 23,888 KiB uncompressed: C 3,820 KiB, Go
1,568 KiB, Java 2,536 KiB, Ruby 14,992 KiB, Lua 396 KiB, GraphQL 292 KiB, and
XML 284 KiB. SwiftPM's debug syntax-target build completed successfully on
Apple silicon during qualification.

## Deferred grammars

- **SCSS:** the inspected v1.0.0 upstream declares MIT in package metadata but
  does not contain a license-text file to vendor, so it fails the copied-license
  gate.
- **SQL:** the inspected `m-novikov/tree-sitter-sql` parser references an
  external scanner that is absent at the pinned commit; the resulting target
  fails to link. It is deliberately not shipped.
- **C++, Kotlin, C#, PHP, Vue, Svelte, and Astro:** deferred pending a complete
  generated-source, scanner/helper, license, query, and build audit. They are
  not routed to a partial parser; unsupported files remain Plain Text.
