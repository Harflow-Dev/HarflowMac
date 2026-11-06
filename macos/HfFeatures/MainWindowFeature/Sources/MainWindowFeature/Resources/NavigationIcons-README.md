# Sidebar navigation artwork

The SVG files are the exact percent-decoded `.hd-i-*` data URIs from
HarflowDesign commit `5b37a3d4d4d06b3d96c517cd384892e1ac6883cf`, `v2/styles/bundle.css`.
The adjacent provenance manifest records selectors and source/PDF SHA-256 hashes.
SVG view boxes (24 × 24), paths and 1.8-unit strokes are preserved.

The PDFs are vector format exports made once during development with an offscreen
WKWebView using a nonpersistent store, disabled JavaScript and inline SVG only.
HTML/body/SVG occupy 24 × 24 points with transparent backgrounds;
WKPDFConfiguration uses a 24 × 24 rectangle and allowTransparentBackground=true.
This changes vector container format only; source geometry and strokes are unchanged.

SwiftPM copies these resources because its command-line build copies asset catalogs
without compiling Assets.car. The application loads template PDFs from its packaged
MainWindowFeature resource bundle; standalone package tests use the module bundle.
No sibling checkout, network request, WebKit or runtime SVG parser is required to load icons.
