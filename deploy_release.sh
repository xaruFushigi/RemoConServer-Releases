#!/bin/env bash
set -e

# Config
RELEASE_DIR="$HOME/Documents/GitHub/RemoConServer-Releases"
PKG_PATH="$RELEASE_DIR/RemoConServer.pkg"
GITHUB_REPO_URL="https://github.com/xaruFushigi/RemoConServer-Releases.git"

APPLE_ID="remocon.app.ios@gmail.com"
TEAM_ID="AMZVHB77Z7"
APP_PASS="lijc-xmbk-esvt-xtsw"

APP_SIGNING_IDENTITY="Developer ID Application: BOKHODIR ZIEDULLAEV (AMZVHB77Z7)"
PKG_SIGNING_IDENTITY="Developer ID Installer: BOKHODIR ZIEDULLAEV (AMZVHB77Z7)"

SPARKLE_BIN_DIR=$(dirname "$(which generate_appcast 2>/dev/null || find "$HOME/Library/Developer/Xcode/DerivedData" -name generate_appcast -type f 2>/dev/null | head -n 1)")

echo "Locating the freshest build in Xcode DerivedData..."
# Aggressively search DerivedData and sort by newest modification time to guarantee we get your latest code
APP_PATH=$(find "$HOME/Library/Developer/Xcode/DerivedData" -name "RemoConServer.app" -type d -exec stat -f "%m %N" {} + 2>/dev/null | sort -rn | head -n 1 | cut -d ' ' -f 2-)

if [ -z "$APP_PATH" ] || [ ! -d "$APP_PATH" ]; then
    echo "❌ Error: Could not find RemoConServer.app. Please hit Cmd+B in Xcode to build the app first!"
    exit 1
fi
echo "✅ Using freshest App build at: $APP_PATH"

echo "Cleaning up stale pkg/zip artifacts from previous runs..."
# Prevents generate_appcast from mismatching old files to new version entries
rm -f "$RELEASE_DIR"/RemoConServer.pkg "$RELEASE_DIR"/RemoConServer_*.zip

mkdir -p "$RELEASE_DIR"
PAYLOAD_DIR="$RELEASE_DIR/payload"
SCRIPTS_DIR="$RELEASE_DIR/scripts"
rm -rf "$PAYLOAD_DIR" "$SCRIPTS_DIR"
mkdir -p "$PAYLOAD_DIR" "$SCRIPTS_DIR"

echo "Copying .app to payload directory..."
cp -R "$APP_PATH" "$PAYLOAD_DIR/RemoConServer.app"
STAGING_APP="$PAYLOAD_DIR/RemoConServer.app"

VERSION=$(defaults read "$STAGING_APP/Contents/Info.plist" CFBundleShortVersionString 2>/dev/null || echo "1.0.0")
BUNDLE_ID=$(defaults read "$STAGING_APP/Contents/Info.plist" CFBundleIdentifier 2>/dev/null || echo "bokhodir.ziedullaev.RemoConServer")
TAG_NAME="v$VERSION"

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

# 🪄 Use ditto to zip ONLY the PKG
echo "Zipping PKG for Sparkle Appcast..."
ZIP_PATH="$RELEASE_DIR/RemoConServer_$TAG_NAME.zip"

# Create a temporary staging directory to pack the zip
ZIP_STAGING="$PAYLOAD_DIR/ZipStaging"
mkdir -p "$ZIP_STAGING"
cp "$PKG_PATH" "$ZIP_STAGING/"

# Compress the contents of the staging folder natively
ditto -c -k --sequesterRsrc "$ZIP_STAGING" "$ZIP_PATH"

echo "Generating appcast.xml manually..."
SIGN_UPDATE_BIN="$SPARKLE_BIN_DIR/sign_update"
ED_SIG=$("$SIGN_UPDATE_BIN" "$ZIP_PATH")

FILE_SIZE=$(stat -f "%z" "$ZIP_PATH")
BUILD_NUMBER=$(defaults read "$STAGING_APP/Contents/Info.plist" CFBundleVersion 2>/dev/null || echo "1")
PUB_DATE=$(date "+%a, %d %b %Y %H:%M:%S %z")

# Construct the exact raw GitHub user content URL matching your main branch
DOWNLOAD_URL="https://raw.githubusercontent.com/xaruFushigi/RemoConServer-Releases/main/$(basename "$ZIP_PATH")"

cat << EOF > "$RELEASE_DIR/appcast.xml"
<?xml version="1.0" standalone="yes"?>
<rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" version="2.0">
    <channel>
        <title>RemoConServer</title>
        <item>
            <title>$VERSION</title>
            <pubDate>$PUB_DATE</pubDate>
            <sparkle:version>$BUILD_NUMBER</sparkle:version>
            <sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>
            <sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion>
            <enclosure url="$DOWNLOAD_URL" length="$FILE_SIZE" type="application/octet-stream" sparkle:edSignature="$ED_SIG"/>
        </item>
    </channel>
</rss>
EOF

rm -rf "$PAYLOAD_DIR" "$SCRIPTS_DIR" "$ENTITLEMENTS_FILE"

ORIGINAL_COMMIT_MSG=$(git -C "$RELEASE_DIR" log -1 --pretty=format:"%s" 2>/dev/null || echo "Release $TAG_NAME")

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

gh release create "$TAG_NAME" "$PKG_PATH" "$ZIP_PATH" \
    --repo "xaruFushigi/RemoConServer-Releases" \
    --title "RemoConServer $TAG_NAME" \
    --notes "$ORIGINAL_COMMIT_MSG" \
    --clobber

echo "✅ Success! PKG signed, notarized, zipped, and deployed."
