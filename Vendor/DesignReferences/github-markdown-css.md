# github-markdown-css design reference

- Project: `sindresorhus/github-markdown-css`
- Pinned commit: `e49401776c9d581ad42367fc4ea3d677d13e2e39`
- License: MIT; see `Vendor/Licenses/github-markdown-css-LICENSE.txt`

Kod uses the pinned stylesheet only as a reviewed design reference for Markdown
hierarchy: 16-point proportional prose, 1.5-ish line height, restrained heading
scales and separators, 24-point block rhythm, padded code/table surfaces, muted
blockquote borders, and readable line length. The CSS itself is not copied into
the app, bundled as a resource, parsed, or executed. Kod implements the design
with AppKit, TextKit, system fonts, semantic colors, and native text blocks.
