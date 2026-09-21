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
APP_PATH=$(mdfind "kMDItemFSName == 'RemoConServer.app'" 2>/dev/null | head -n 1)

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

if [ -s "$ENTITLEMENTS_FILE" ]; then
    echo "Stripping get-task-allow entitlement using PlistBuddy..."
    /usr/libexec/PlistBuddy -c "Delete :com.apple.security.get-task-allow" "$ENTITLEMENTS_FILE" 2>/dev/null || true
fi

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

echo "Generating appcast.xml..."
"$SPARKLE_BIN_DIR/generate_appcast" "$RELEASE_DIR"
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
    --repo "xaruFushigi/RemoConServer-Releases" \
    --title "RemoConServer $TAG_NAME" \
    --notes "$ORIGINAL_COMMIT_MSG" \
    --clobber

echo "✅ Success! PKG signed, notarized, and deployed."
