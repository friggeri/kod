# Vendoring cmark-gfm

`manifest.json` pins GitHub's `cmark-gfm` release `0.29.0.gfm.13` to commit
`587a12bb54d95ac37241377e6ddc93ea0e45439b` and records the source archive
SHA-256 and every upstream file compiled by Kod.

Run `python3 Scripts/vendor-cmark-gfm/fetch.py` to refresh the in-tree source
subset, or `python3 Scripts/vendor-cmark-gfm/fetch.py --verify` to download the
pinned archive, verify its digest, and byte-compare every vendored upstream
file. Generated platform configuration headers and `kod-cmark-gfm.c` are
Kod-owned integration files and are intentionally not overwritten.

The SwiftPM manifest builds two local C targets. No remote package resolution,
dynamic extension loading, HTML renderer, or runtime download is involved.
