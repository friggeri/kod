# Kod Preview Workspace

This workspace contains one valid sample for every built-in preview format in
Kod, plus an HTML document for source and browser checks. Open each previewable
file and use the Source/Preview control to exercise its renderer.

| Sample | Format | Rendering checks |
| --- | --- | --- |
| `index.html` | HTML | Semantic markup, embedded CSS/JS, local links, forms, and tables |
| `README.md` | Markdown | GFM layout, links, task lists, tables, and fenced code |
| `alpha.png` | PNG | Transparency and alpha blending |
| `photo.jpeg` | JPEG | Lossy color image decoding |
| `motion.gif` | GIF | Multi-frame animation and timing |
| `efficient.heic` | HEIC | HEIF container and color decoding |
| `print.tiff` | TIFF | TIFF container and alpha decoding |
| `vector.svg` | SVG | Safe vector shapes, gradients, paths, and text |
| `data.json` | JSON | Nested objects, arrays, scalars, and key ordering |
| `data-xml.plist` | XML plist | Dictionary, array, date, data, and scalar values |
| `data-binary.plist` | Binary plist | Binary property-list detection and decoding |

## GitHub Flavored Markdown

> A rendered preview should preserve hierarchy, spacing, and inline
> **emphasis** while remaining completely read-only.

- [x] Heading, paragraph, and block quote
- [x] **Bold**, *italic*, ~~strikethrough~~, and `inline code`
- [x] Ordered and unordered lists
- [ ] Toggle this item only in your imagination

1. Open [the SVG sample](vector.svg).
2. Check its gradient, geometry, and centered label.
3. Return here with navigation history.

```json
{
  "renderer": "markdown",
  "fencedCodeHighlighting": true
}
```

---

The horizontal rule above and this final paragraph make the end of the
document easy to identify while scrolling.
