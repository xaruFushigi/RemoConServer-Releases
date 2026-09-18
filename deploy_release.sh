#!/usr/bin/env bash
set -e

# ==========================================
# Config Parameters
# ==========================================
DMG_PATH="$HOME/Desktop/RemoConServer.dmg"
RELEASE_DIR="$HOME/Desktop/RemoConServer-Releases"
GITHUB_REPO_URL="https://github.com/xaruFushigi/RemoConServer-Releases.git"

# Dynamically resolve Sparkle bin folder location
SPARKLE_BIN_DIR=$(dirname "$(which generate_appcast 2>/dev/null || find "$HOME" -name generate_appcast -type f 2>/dev/null | head -n 1)")

# ==========================================
# 1. Validate Sparkle Binary Path
# ==========================================
if [ -z "$SPARKLE_BIN_DIR" ] || [ ! -x "$SPARKLE_BIN_DIR/generate_appcast" ]; then
    echo "Error: Could not locate generate_appcast binary automatically."
    exit 1
fi

echo "Using Sparkle binary at: $SPARKLE_BIN_DIR/generate_appcast"

# ==========================================
# 2. Prepare Release Directory
# ==========================================
echo "Preparing release directory at $RELEASE_DIR..."
mkdir -p "$RELEASE_DIR"

if [ ! -f "$DMG_PATH" ]; then
    echo "Error: DMG file not found at $DMG_PATH"
    exit 1
fi

cp "$DMG_PATH" "$RELEASE_DIR/"

# ==========================================
# 3. Generate Appcast XML
# ==========================================
echo "Generating appcast.xml..."
"$SPARKLE_BIN_DIR/generate_appcast" "$RELEASE_DIR"

# ==========================================
# 4. Deploy to GitHub
# ==========================================
echo "Deploying to GitHub..."
cd "$RELEASE_DIR"

if [ ! -d ".git" ]; then
    git init
    git remote add origin "$GITHUB_REPO_URL"
    git branch -M main
fi

git add RemoConServer.dmg appcast.xml
git commit -m "Automated release deployment: $(date +'%Y-%m-%d %H:%M:%S')"
git push -u origin main

echo "✅ Deployment complete!"
