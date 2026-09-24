#!/bin/env bash
set -e

# Config
RELEASE_DIR="$HOME/Documents/GitHub/RemoConServer-Releases"
GITHUB_USERNAME="xaruFushigi"
GITHUB_REPO_URL="https://github.com/$GITHUB_USERNAME/RemoConServer-Releases.git"
APPCAST_PATH="$RELEASE_DIR/appcast.xml"

APPLE_ID="remocon.app.ios@gmail.com"
TEAM_ID="AMZVHB77Z7"
APP_PASS="lijc-xmbk-esvt-xtsw"

APP_SIGNING_IDENTITY="Developer ID Application: BOKHODIR ZIEDULLAEV (AMZVHB77Z7)"
PKG_SIGNING_IDENTITY="Developer ID Installer: BOKHODIR ZIEDULLAEV (AMZVHB77Z7)"

# sign_update is what we need now (generate_appcast does NOT support bare .pkg files)
SPARKLE_BIN_DIR=$(dirname "$(which sign_update 2>/dev/null || find "$HOME/Library/Developer/Xcode/DerivedData" -name sign_update -type f 2>/dev/null | head -n 1)")

echo "Locating the freshest build in Xcode DerivedData..."
# Aggressively search DerivedData and sort by newest modification time to guarantee we get your latest code
APP_PATH=$(find "$HOME/Library/Developer/Xcode/DerivedData" -name "RemoConServer.app" -type d -exec stat -f "%m %N" {} + 2>/dev/null | sort -rn | head -n 1 | cut -d ' ' -f 2-)

if [ -z "$APP_PATH" ] || [ ! -d "$APP_PATH" ]; then
    echo "❌ Error: Could not find RemoConServer.app. Please hit Cmd+B in Xcode to build the app first!"
    exit 1
fi
echo "✅ Using freshest App build at: $APP_PATH"

echo "Syncing local release dir with GitHub before editing appcast.xml..."
if [ -d "$RELEASE_DIR/.git" ]; then
    git -C "$RELEASE_DIR" pull --rebase origin main || true
fi

echo "Cleaning up stale pkg/zip artifacts from previous runs..."
rm -f "$RELEASE_DIR"/RemoConServer_v*.pkg "$RELEASE_DIR"/RemoConServer_*.zip "$RELEASE_DIR"/RemoConServer.pkg

mkdir -p "$RELEASE_DIR"
PAYLOAD_DIR="$RELEASE_DIR/payload"
SCRIPTS_DIR="$RELEASE_DIR/scripts"
rm -rf "$PAYLOAD_DIR" "$SCRIPTS_DIR"
mkdir -p "$PAYLOAD_DIR" "$SCRIPTS_DIR"

echo "Copying .app to payload directory..."
cp -R "$APP_PATH" "$PAYLOAD_DIR/RemoConServer.app"
STAGING_APP="$PAYLOAD_DIR/RemoConServer.app"

VERSION=$(defaults read "$STAGING_APP/Contents/Info.plist" CFBundleShortVersionString 2>/dev/null || echo "1.0.0")
BUILD_NUMBER=$(defaults read "$STAGING_APP/Contents/Info.plist" CFBundleVersion 2>/dev/null || echo "1")
BUNDLE_ID=$(defaults read "$STAGING_APP/Contents/Info.plist" CFBundleIdentifier 2>/dev/null || echo "bokhodir.ziedullaev.RemoConServer")
MIN_OS_VERSION=$(defaults read "$STAGING_APP/Contents/Info.plist" LSMinimumSystemVersion 2>/dev/null || echo "")
TAG_NAME="v$VERSION"

# Versioned pkg name so each release keeps its own file (fixed name was overwriting prior versions)
PKG_NAME="RemoConServer_$TAG_NAME.pkg"
PKG_PATH="$RELEASE_DIR/$PKG_NAME"

echo "Signing nested frameworks and binaries..."
# 1. Sign Sparkle standalone binary file directly
SPARKLE_AUTOUPDATE="$STAGING_APP/Contents/Frameworks/Sparkle.framework/Versions/B/Autoupdate"
if [ -f "$SPARKLE_AUTOUPDATE" ]; then
    codesign --force --options runtime --timestamp --sign "$APP_SIGNING_IDENTITY" "$SPARKLE_AUTOUPDATE"
fi

# 2. Deep sign inside-out framework directories
find "$STAGING_APP" -type d \( -name "*.framework" -o -name "*.app" -o -name "*.xpc" -o -name "*.bundle" \) | awk '{ print length, $0 }' | sort -rn | cut -d" " -f2- | while read -r component; do
    if [ "$component" != "$STAGING_APP" ]; then
        codesign --force --options runtime --timestamp --sign "$APP_SIGNING_IDENTITY" "$component"
    fi
done

echo "Extracting and preserving existing entitlements..."
ENTITLEMENTS_FILE="$RELEASE_DIR/entitlements.plist"
codesign -d --entitlements :- "$STAGING_APP" > "$ENTITLEMENTS_FILE" 2>/dev/null || true

# If the file is empty or missing, create a base empty plist
if ! grep -q "<plist" "$ENTITLEMENTS_FILE"; then
    echo '<?xml version="1.0" encoding="UTF-8"?><!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd"><plist version="1.0"><dict></dict></plist>' > "$ENTITLEMENTS_FILE"
fi

echo "Configuring entitlements for Hardened Runtime..."
# 1. Strip debug entitlement (Fixes Notarization)
/usr/libexec/PlistBuddy -c "Delete :com.apple.security.get-task-allow" "$ENTITLEMENTS_FILE" 2>/dev/null || true

# 2. Inject Apple Events entitlement (Fixes Automation/System Events prompt)
/usr/libexec/PlistBuddy -c "Add :com.apple.security.automation.apple-events bool true" "$ENTITLEMENTS_FILE" 2>/dev/null || \
/usr/libexec/PlistBuddy -c "Set :com.apple.security.automation.apple-events true" "$ENTITLEMENTS_FILE" 2>/dev/null

echo "Removing embedded provisioning profile (prevents debugger entitlement conflicts)..."
rm -f "$STAGING_APP/Contents/embedded.provisionprofile"

echo "Signing main .app bundle..."
if [ -s "$ENTITLEMENTS_FILE" ]; then
    # Re-sign using the preserved, cleaned entitlements
    codesign --force --options runtime --entitlements "$ENTITLEMENTS_FILE" --timestamp --sign "$APP_SIGNING_IDENTITY" "$STAGING_APP"
else
    codesign --force --options runtime --timestamp --sign "$APP_SIGNING_IDENTITY" "$STAGING_APP"
fi

echo "Generating postinstall script..."
cat << 'EOF' > "$SCRIPTS_DIR/postinstall"
#!/bin/bash
# Extract the real user session ID to escape the Installer's root daemon context.
# Launching via launchctl ensures the app has full WindowServer and TCC UI prompt access.
LOGGED_IN_USER=$(stat -f "%Su" /dev/console)
USER_ID=$(id -u "$LOGGED_IN_USER")
/bin/launchctl asuser "$USER_ID" /usr/bin/open "/Applications/RemoConServer.app"
exit 0
EOF
chmod +x "$SCRIPTS_DIR/postinstall"

echo "Building PKG..."
pkgbuild --root "$PAYLOAD_DIR" \
         --install-location "/Applications" \
         --scripts "$SCRIPTS_DIR" \
         --identifier "$BUNDLE_ID" \
         --version "$VERSION" \
         --sign "$PKG_SIGNING_IDENTITY" \
         --timestamp \
         "$PKG_PATH"

echo "Submitting to Apple Notary Service..."
xcrun notarytool submit "$PKG_PATH" \
    --apple-id "$APPLE_ID" \
    --team-id "$TEAM_ID" \
    --password "$APP_PASS" \
    --wait

echo "Stapling notarization ticket..."
xcrun stapler staple "$PKG_PATH"

ORIGINAL_COMMIT_MSG=$(git -C "$RELEASE_DIR" log -1 --pretty=format:"%s" 2>/dev/null || echo "Release $TAG_NAME")

echo "Signing pkg with Sparkle EdDSA key..."
# generate_appcast does NOT support bare .pkg files, so we sign + build the appcast item manually.
SIGN_OUTPUT=$("$SPARKLE_BIN_DIR/sign_update" "$PKG_PATH")
ED_SIGNATURE=$(echo "$SIGN_OUTPUT" | sed -n 's/.*sparkle:edSignature="\([^"]*\)".*/\1/p')
FILE_LENGTH=$(echo "$SIGN_OUTPUT" | sed -n 's/.*length="\([^"]*\)".*/\1/p')

if [ -z "$ED_SIGNATURE" ] || [ -z "$FILE_LENGTH" ]; then
    echo "❌ Error: sign_update did not return a signature. Output was:"
    echo "$SIGN_OUTPUT"
    exit 1
fi

PUB_DATE=$(date -u +"%a, %d %b %Y %H:%M:%S %z")
DOWNLOAD_URL="https://raw.githubusercontent.com/$GITHUB_USERNAME/RemoConServer-Releases/main/$PKG_NAME"

echo "Updating appcast.xml..."
python3 - "$APPCAST_PATH" "$VERSION" "$BUILD_NUMBER" "$PUB_DATE" "$DOWNLOAD_URL" "$FILE_LENGTH" "$ED_SIGNATURE" "$MIN_OS_VERSION" << 'PYEOF'
import sys
import xml.etree.ElementTree as ET

appcast_path, version, build_number, pub_date, url, length, ed_sig, min_os = sys.argv[1:9]

NS = "http://www.andymatuschak.org/xml-namespaces/sparkle"
ET.register_namespace("sparkle", NS)

try:
    tree = ET.parse(appcast_path)
    root = tree.getroot()
    channel = root.find("channel")
except (FileNotFoundError, ET.ParseError):
    # Don't set xmlns:sparkle manually here -- register_namespace() above already
    # makes ElementTree emit it once during write(); adding it here too produced
    # a duplicate xmlns:sparkle attribute, which is invalid XML and broke Sparkle's parser.
    root = ET.Element("rss", {"version": "2.0"})
    channel = ET.SubElement(root, "channel")
    title = ET.SubElement(channel, "title")
    title.text = "RemoConServer"
    tree = ET.ElementTree(root)

item = ET.Element("item")
t = ET.SubElement(item, "title")
t.text = version
pd = ET.SubElement(item, "pubDate")
pd.text = pub_date
sv = ET.SubElement(item, "{%s}version" % NS)
sv.text = build_number
ssv = ET.SubElement(item, "{%s}shortVersionString" % NS)
ssv.text = version
if min_os:
    mv = ET.SubElement(item, "{%s}minimumSystemVersion" % NS)
    mv.text = min_os
enclosure = ET.SubElement(item, "enclosure", {
    "url": url,
    "length": length,
    "type": "application/octet-stream",
    "{%s}installationType" % NS: "package",
    "{%s}edSignature" % NS: ed_sig,
})

# Insert newest item first, right after any leading metadata elements (title/link/description)
first_item_index = len(list(channel))
for i, child in enumerate(channel):
    if child.tag == "item":
        first_item_index = i
        break
channel.insert(first_item_index, item)

ET.indent(tree, space="    ")
tree.write(appcast_path, encoding="utf-8", xml_declaration=True)
print(f"✅ appcast.xml updated with {version} ({build_number})")
PYEOF

rm -rf "$PAYLOAD_DIR" "$SCRIPTS_DIR" "$ENTITLEMENTS_FILE"

echo "Deploying to GitHub Releases..."
cd "$RELEASE_DIR"
if [ ! -d ".git" ]; then
    git init
    git remote add origin "$GITHUB_REPO_URL"
    git branch -M main
fi

git add .
git commit -m "Update appcast for release $TAG_NAME" || true
git pull --rebase origin main
git push origin main

gh release create "$TAG_NAME" "$PKG_PATH" \
    --repo "$GITHUB_USERNAME/RemoConServer-Releases" \
    --title "RemoConServer $TAG_NAME" \
    --notes "$ORIGINAL_COMMIT_MSG" \
    --clobber

echo "✅ Success! PKG signed, notarized, appcast updated, and deployed."
