#!/bin/env bash
set -e

# ==========================================
# Config Parameters
# ==========================================
RELEASE_DIR="$HOME/Documents/GitHub/RemoConServer-Releases"
PKG_PATH="$RELEASE_DIR/RemoConServer.pkg"
GITHUB_REPO_URL="https://github.com/xaruFushigi/RemoConServer-Releases.git"

APPLE_ID="remocon.app.ios@gmail.com"
TEAM_ID="AMZVHB77Z7"
APP_PASS="lijc-xmbk-esvt-xtsw"

APP_SIGNING_IDENTITY="Developer ID Application: BOKHODIR ZIEDULLAEV (AMZVHB77Z7)"
PKG_SIGNING_IDENTITY="Developer ID Installer: BOKHODIR ZIEDULLAEV (AMZVHB77Z7)"

# Resolve paths
SPARKLE_BIN_DIR=$(dirname "$(which generate_appcast 2>/dev/null || find "$HOME/Library/Developer/Xcode/DerivedData" -name generate_appcast -type f 2>/dev/null | head -n 1)")
APP_PATH=$(mdfind "kMDItemFSName == 'RemoConServer.app'" 2>/dev/null | head -n 1)

# ==========================================
# 1. Validate & Prepare
# ==========================================
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

# ==========================================
# 2. Deep Codesigning (Inside-Out)
# ==========================================
echo "Signing nested frameworks and XPC services..."

# 1. Sign Sparkle's raw Autoupdate binary (since it's a file, not a directory)
SPARKLE_AUTOUPDATE="$STAGING_APP/Contents/Frameworks/Sparkle.framework/Versions/B/Autoupdate"
if [ -f "$SPARKLE_AUTOUPDATE" ]; then
    echo "Signing: Sparkle Autoupdate binary"
    codesign --force --options runtime --timestamp --sign "$APP_SIGNING_IDENTITY" "$SPARKLE_AUTOUPDATE"
fi

# 2. Find all nested directories (frameworks, apps, XPCs) and sign them inside-out
find "$STAGING_APP" -type d \( -name "*.framework" -o -name "*.app" -o -name "*.xpc" -o -name "*.bundle" \) | awk '{ print length, $0 }' | sort -rn | cut -d" " -f2- | while read -r component; do
    if [ "$component" != "$STAGING_APP" ]; then
        echo "Signing: $(basename "$component")"
        codesign --force --options runtime --timestamp --sign "$APP_SIGNING_IDENTITY" "$component"
    fi
done

echo "Signing main .app bundle..."
codesign --force --options runtime --timestamp --sign "$APP_SIGNING_IDENTITY" "$STAGING_APP"

# ==========================================
# 3. Build the Post-Install Script
# ==========================================
echo "Generating postinstall script for auto-launch..."
cat << 'EOF' > "$SCRIPTS_DIR/postinstall"
#!/bin/bash
# Identify the currently logged-in GUI user (not root)
LOGGED_IN_USER=$(stat -f "%Su" /dev/console)

# Launch the app as the user so TCC prompts attach to their profile
sudo -u "$LOGGED_IN_USER" open "/Applications/RemoConServer.app"

exit 0
EOF

chmod +x "$SCRIPTS_DIR/postinstall"

# ==========================================
# 4. Build & Sign the .pkg
# ==========================================
echo "Building and signing PKG with Developer ID Installer..."
pkgbuild --root "$PAYLOAD_DIR" \
         --install-location "/Applications" \
         --scripts "$SCRIPTS_DIR" \
         --identifier "$BUNDLE_ID" \
         --version "$VERSION" \
         --sign "$PKG_SIGNING_IDENTITY" \
         --timestamp \
         "$PKG_PATH"

# ==========================================
# 5. Notarize & Staple
# ==========================================
echo "Submitting PKG to Apple Notary Service (this may take 1-2 minutes)..."
xcrun notarytool submit "$PKG_PATH" \
    --apple-id "$APPLE_ID" \
    --team-id "$TEAM_ID" \
    --password "$APP_PASS" \
    --wait

echo "Stapling notarization ticket to PKG..."
xcrun stapler staple "$PKG_PATH"

# ==========================================
# 6. Generate Release Notes & Appcast
# ==========================================
ORIGINAL_COMMIT_MSG=$(git -C "$RELEASE_DIR" log -1 --pretty=format:"%s" 2>/dev/null || echo "Release $TAG_NAME")

echo "Generating appcast.xml..."
"$SPARKLE_BIN_DIR/generate_appcast" "$RELEASE_DIR"

rm -rf "$PAYLOAD_DIR" "$SCRIPTS_DIR"

# ==========================================
# 7. Deploy Release to GitHub
# ==========================================
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

echo "✅ Success! Signed, notarized, and published PKG to GitHub Releases."
