# Third-party notices

AIRS's original code is licensed under the [MIT License](LICENSE).
Third-party components and platform resources retain their existing copyrights
and license terms.

## Bundled Lumen snapshot

The LumenTokens and LumenUI snapshot included with AIRS is also licensed under
[MIT](native/Vendor/Lumen/LICENSE). Its source revision and ownership record are
documented in [PROVENANCE.md](native/Vendor/Lumen/PROVENANCE.md).

## EntitlementDiff

The vendored EntitlementDiff code retains its [MIT license and attribution](native/Vendor/EntitlementDiff/LICENSE),
copyright 2026 EntitlementDiff contributors. Its origin and local changes are
recorded in [UPSTREAM.md](native/Vendor/EntitlementDiff/UPSTREAM.md).

## Python runtime

The separately prepared Python runtime and its bundled components retain their
upstream licenses. Standalone app packaging includes those notices in
`Contents/Resources/RuntimeNotices`; the compiled runtime is excluded from the
source snapshot. See [runtime preparation](docs/PRIVATE_PYTHON.md).

## Apple platform resources

AIRS uses Apple macOS frameworks. Some custom-symbol SVGs in Lumen's
`Sources/LumenUI/Resources/Symbols.xcassets` include Apple SF Symbols template
metadata and reference artwork. Apple-provided frameworks, symbols, templates
and reference material remain subject to their applicable Apple terms.
The AIRS and Lumen MIT licenses cover the owner's original contributions and
do not relicense that third-party material.
