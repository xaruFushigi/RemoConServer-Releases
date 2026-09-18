#!/usr/bin/env bash
set -e

# ==========================================
# Config Parameters
# ==========================================
RELEASE_DIR="$HOME/Documents/GitHub/RemoConServer-Releases"
DMG_PATH="$RELEASE_DIR/RemoConServer.dmg"
GITHUB_REPO_URL="https://github.com/xaruFushigi/RemoConServer-Releases.git"

APPLE_ID="remocon.app.ios@gmail.com"
TEAM_ID="AMZVHB77Z7"
APP_PASS="lijc-xmbk-esvt-xtsw"
SIGNING_IDENTITY="Developer ID Application: BOKHODIR ZIEDULLAEV (AMZVHB77Z7)"

# Resolve paths
SPARKLE_BIN_DIR=$(dirname "$(which generate_appcast 2>/dev/null || find "$HOME/Library/Developer/Xcode/DerivedData" -name generate_appcast -type f 2>/dev/null | head -n 1)")
APP_PATH=$(mdfind "kMDItemFSName == 'RemoConServer.app'" 2>/dev/null | head -n 1)

# ==========================================
# 1. Validate & Prepare
# ==========================================
mkdir -p "$RELEASE_DIR"
STAGING_APP="$RELEASE_DIR/RemoConServer.app"

echo "Copying .app to release directory to protect Xcode cache..."
rm -rf "$STAGING_APP"
cp -R "$APP_PATH" "$STAGING_APP"

echo "Signing .app bundle with Developer ID..."
codesign --deep --force --options runtime --sign "$SIGNING_IDENTITY" "$STAGING_APP"

echo "Building DMG..."
hdiutil create -volname "RemoConServer" -srcfolder "$STAGING_APP" -ov -format UDZO "$DMG_PATH"

echo "Signing DMG..."
codesign --force --sign "$SIGNING_IDENTITY" "$DMG_PATH"

# ==========================================
# 2. Notarize & Staple
# ==========================================
echo "Submitting DMG to Apple Notary Service (this may take 1-2 minutes)..."
xcrun notarytool submit "$DMG_PATH" \
    --apple-id "$APPLE_ID" \
    --team-id "$TEAM_ID" \
    --password "$APP_PASS" \
    --wait

echo "Stapling notarization ticket to DMG..."
xcrun stapler staple "$DMG_PATH"

# ==========================================
# 3. Generate Release Notes & Appcast
# ==========================================
VERSION=$(defaults read "$STAGING_APP/Contents/Info.plist" CFBundleShortVersionString 2>/dev/null || echo "1.0.0")
TAG_NAME="v$VERSION"

# Extract original commit message BEFORE we make the automated appcast commit
ORIGINAL_COMMIT_MSG=$(git -C "$RELEASE_DIR" log -1 --pretty=format:"%s" 2>/dev/null || echo "Release $TAG_NAME")

echo "Generating appcast.xml..."
"$SPARKLE_BIN_DIR/generate_appcast" "$RELEASE_DIR"

# Clean up temporary bundle
rm -rf "$STAGING_APP"

# ==========================================
# 4. Deploy Release to GitHub
# ==========================================
echo "Deploying to GitHub Releases..."
cd "$RELEASE_DIR"

if [ ! -d ".git" ]; then
    git init
    git remote add origin "$GITHUB_REPO_URL"
    git branch -M main
fi

# Commit local changes FIRST to prevent git pull rebase errors
git add .
git commit -m "Update appcast for release $TAG_NAME" || true
git pull --rebase origin main
git push origin main

# Create GitHub Release using the ORIGINAL commit message
gh release create "$TAG_NAME" "$DMG_PATH" \
    --repo "xaruFushigi/RemoConServer-Releases" \
    --title "RemoConServer $TAG_NAME" \
    --notes "$ORIGINAL_COMMIT_MSG" \
    --clobber

echo "✅ Success! Signed, notarized, and published to GitHub Releases."
