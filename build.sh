#!/bin/bash
# Builds "Claude Usage.app" into ./build.
#
# Usage: ./build.sh [--install] [--zip]
#   --install   copy the app to /Applications
#   --zip       also write build/Claude-Usage-<version>.zip for a GitHub release, plus its SHA-256
#
# Optional environment:
#   VERSION        marketing version            (default: 1.0.0)
#   BUILD_NUMBER   build number                 (default: git commit count, else 1)
#   ARCHS          architectures to include     (default: "arm64 x86_64", a universal app)
#   SOURCE_URL     repository link shown in Settings → About
#   TIP_JAR_URL    tip jar link shown in Settings → About
#   SIGN_IDENTITY  codesign identity, e.g. "Developer ID Application: Name (TEAMID)".
#                  Defaults to ad-hoc signing ("-"), which is fine for local builds; downloaded
#                  ad-hoc builds need right-click → Open the first time (see README).
#   BUNDLE_ID      bundle identifier. Changing it starts from scratch: sign-ins and settings
#                  are stored per bundle identifier.
set -euo pipefail
cd "$(dirname "$0")"

VERSION="${VERSION:-1.0.0}"
BUILD_NUMBER="${BUILD_NUMBER:-$(git rev-list --count HEAD 2>/dev/null || echo 1)}"
ARCHS="${ARCHS:-arm64 x86_64}"
SOURCE_URL="${SOURCE_URL:-}"
TIP_JAR_URL="${TIP_JAR_URL:-}"
SIGN_IDENTITY="${SIGN_IDENTITY:--}"
BUNDLE_ID="${BUNDLE_ID:-local.claudeusage.menubar}"

INSTALL=0
ZIP=0
for arg in "$@"; do
    case "$arg" in
        --install) INSTALL=1 ;;
        --zip) ZIP=1 ;;
        *) echo "Unknown option: $arg" >&2; exit 2 ;;
    esac
done

# Build each architecture separately and merge them; this works with just the Command Line Tools.
BINARIES=()
for arch in $ARCHS; do
    echo "Building $arch…"
    swift build -c release --triple "$arch-apple-macosx14.0"
    BINARIES+=("$(swift build -c release --triple "$arch-apple-macosx14.0" --show-bin-path)/ClaudeUsage")
done

APP="build/Claude Usage.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
lipo -create "${BINARIES[@]}" -output "$APP/Contents/MacOS/ClaudeUsage"

PLIST="$APP/Contents/Info.plist"
cat > "$PLIST" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>Claude Usage</string>
    <key>CFBundleDisplayName</key><string>Claude Usage</string>
    <key>CFBundleExecutable</key><string>ClaudeUsage</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSApplicationCategoryType</key><string>public.app-category.developer-tools</string>
    <key>LSUIElement</key><true/>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSHumanReadableCopyright</key><string>Free and open source under the MIT License. Not affiliated with Anthropic.</string>
</dict>
</plist>
EOF
# plutil escapes the values, so URLs containing & or quotes are safe.
plutil -insert CFBundleIdentifier -string "$BUNDLE_ID" "$PLIST"
plutil -insert CFBundleShortVersionString -string "$VERSION" "$PLIST"
plutil -insert CFBundleVersion -string "$BUILD_NUMBER" "$PLIST"
plutil -insert ClaudeUsageSourceURL -string "$SOURCE_URL" "$PLIST"
plutil -insert ClaudeUsageTipJarURL -string "$TIP_JAR_URL" "$PLIST"
plutil -lint "$PLIST" >/dev/null

if [[ "$SIGN_IDENTITY" == "-" ]]; then
    codesign --force --sign - "$APP"
else
    # Hardened runtime and a secure timestamp are required for notarization.
    codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY" "$APP"
fi
codesign --verify --strict "$APP"
echo "Built $APP ($VERSION, build $BUILD_NUMBER, $(lipo -archs "$APP/Contents/MacOS/ClaudeUsage"))"

if [[ $ZIP == 1 ]]; then
    ZIPFILE="build/Claude-Usage-$VERSION.zip"
    rm -f "$ZIPFILE"
    ditto -c -k --keepParent "$APP" "$ZIPFILE"
    echo "Wrote $ZIPFILE"
    shasum -a 256 "$ZIPFILE"
fi

if [[ $INSTALL == 1 ]]; then
    rm -rf "/Applications/Claude Usage.app"
    cp -R "$APP" /Applications/
    echo "Installed to /Applications"
fi
