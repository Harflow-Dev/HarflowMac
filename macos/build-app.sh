#!/bin/bash
# Build Harflow.app locally; Xcode registers this generated bundle with LaunchServices.
# No app installation, ordinary launch, MCP registration or login-item changes.
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
out="$here/build"
app="$out/Harflow.app"
case "${CONFIGURATION:-release}" in
    release|Release) config="Release" ;;
    debug|Debug) config="Debug" ;;
    *) echo "CONFIGURATION must be debug or release" >&2; exit 1 ;;
esac

# The native target is the only product and packaging authority. SwiftPM owns its
# importable shell and dependency resources; Xcode embeds those resource bundles.
rm -rf "$app"
xcodebuild -project "$here/Harflow.xcodeproj" -scheme Harflow \
    -configuration "$config" -destination 'generic/platform=macOS' \
    -derivedDataPath "$out/DerivedData" \
    -onlyUsePackageVersionsFromResolvedFile \
    CONFIGURATION_BUILD_DIR="$out" ARCHS=arm64 CODE_SIGNING_ALLOWED=NO build

plutil -lint "$app/Contents/Info.plist" >/dev/null
test -f "$app/Contents/Resources/AppIcon.icns" || { echo "Missing AppIcon.icns in built bundle" >&2; exit 1; }
test -f "$app/Contents/Resources/menubarTemplate.png" || { echo "Missing menubarTemplate.png in built bundle" >&2; exit 1; }
test -f "$app/Contents/Resources/menubarTemplate@2x.png" || { echo "Missing menubarTemplate@2x.png in built bundle" >&2; exit 1; }

# Ad-hoc signature; not sandboxed, not notarized (the app is not distributed).
codesign --force --sign - --timestamp=none "$app"
codesign --verify --strict "$app"


echo "Built: $app"
