#!/bin/bash
# Build "Polybridge Monitor.app" into macos/build/. Build only: it does not install, open, register
# the URL scheme, or add a login item. To install, copy the printed .app into ~/Applications
# yourself (LaunchServices registers `polybridge-monitor://` when the app is first opened there).
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
pkg="$here/PolybridgeMonitor"
out="$here/build"
app="$out/Polybridge Monitor.app"
config="${CONFIGURATION:-release}"

swift build -c "$config" --package-path "$pkg" --product PolybridgeMonitor
bin_dir="$(swift build -c "$config" --package-path "$pkg" --show-bin-path)"

rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$bin_dir/PolybridgeMonitor" "$app/Contents/MacOS/PolybridgeMonitor"
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

# Best-effort: unregister this build copy from LaunchServices (Monitor piece 9) so
# `polybridge-monitor://` task links resolve to an installed copy instead of quietly picking this
# throwaway build copy back up. Never fails the build — this is convenience cleanup, not a
# requirement — and it is fine whether or not the copy was registered in the first place.
lsregister="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
if "$lsregister" -u "$app" >/dev/null 2>&1; then
    echo "Unregistered from LaunchServices: $app"
else
    echo "Could not unregister $app from LaunchServices (already unregistered, or lsregister unavailable) — continuing"
fi

echo "Built: $app"
echo "Install: rm -rf ~/Applications/'Polybridge Monitor.app' && cp -R '$app' ~/Applications/"
echo "Task links (polybridge-monitor://) resolve to an installed copy in ~/Applications; if none is"
echo "installed there, the scheme simply has no handler until the app is opened once from there."
