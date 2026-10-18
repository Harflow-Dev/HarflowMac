#!/bin/bash
# Build Harflow.app locally. No installation, launch, URL registration, or login-item changes.
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
pkg="$here/Harflow"
out="$here/build"
app="$out/Harflow.app"
config="${CONFIGURATION:-release}"

swift build -c "$config" --package-path "$pkg" --product Harflow
bin_dir="$(swift build -c "$config" --package-path "$pkg" --show-bin-path)"

rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$bin_dir/Harflow" "$app/Contents/MacOS/Harflow"
cp "$pkg/Resources/Info.plist" "$app/Contents/Info.plist"
# Any SwiftPM resource bundles a dependency produces, inside Resources so the bundle stays signable.
for bundle in "$bin_dir"/*.bundle; do
    [ -e "$bundle" ] && cp -R "$bundle" "$app/Contents/Resources/"
done
# App icon and menu-bar template images. `Resources/Branding/` (source SVG/1024px art) is
# deliberately not copied — it is not part of the bundle.
cp "$pkg/Resources/AppIcon.icns" "$app/Contents/Resources/AppIcon.icns"
cp "$pkg/Resources/menubarTemplate.png" "$app/Contents/Resources/menubarTemplate.png"
cp "$pkg/Resources/menubarTemplate@2x.png" "$app/Contents/Resources/menubarTemplate@2x.png"
plutil -lint "$app/Contents/Info.plist" >/dev/null
test -f "$app/Contents/Resources/AppIcon.icns" || { echo "Missing AppIcon.icns in built bundle" >&2; exit 1; }
test -f "$app/Contents/Resources/menubarTemplate.png" || { echo "Missing menubarTemplate.png in built bundle" >&2; exit 1; }
test -f "$app/Contents/Resources/menubarTemplate@2x.png" || { echo "Missing menubarTemplate@2x.png in built bundle" >&2; exit 1; }

# Ad-hoc signature; not sandboxed, not notarized (the app is not distributed).
codesign --force --sign - --timestamp=none "$app"
codesign --verify --strict "$app"


echo "Built: $app"
