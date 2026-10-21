#!/usr/bin/env bash
# RemoConServer release: archive -> export (Developer ID) -> pkg -> notarize -> Sparkle appcast -> GitHub
# Usage:  bash deploy_release.sh        (do NOT use sudo)
set -euo pipefail

if [ "$EUID" -eq 0 ]; then
    echo "❌ Don't run this with sudo. Run: bash deploy_release.sh"
    exit 1
fi

# ---------------------------------------------------------------- config
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${RELEASE_CONFIG:-$SCRIPT_DIR/release.config}"
if [ ! -f "$CONFIG_FILE" ]; then
    echo "❌ Missing $CONFIG_FILE. Copy release.config.example to release.config and fill it in."
    exit 1
fi
# shellcheck disable=SC1090
source "$CONFIG_FILE"

for var in PROJECT_DIR SCHEME RELEASE_DIR GITHUB_USERNAME APPLE_ID TEAM_ID APP_PASS PKG_SIGNING_IDENTITY; do
    if [ -z "${!var:-}" ]; then
        echo "❌ $var is empty in $CONFIG_FILE"
        exit 1
    fi
done

REPO_NAME="RemoConServer-Releases"
APPCAST_PATH="$RELEASE_DIR/appcast.xml"
WORK_DIR="$HOME/.remocon-release-build"          # outside the git repo, wiped every run

# ---------------------------------------------------------------- helpers
retry() {  # retry <times> <delay> cmd...   (for flaky network steps)
    local times="$1" delay="$2" n=1
    shift 2
    until "$@"; do
        if [ "$n" -ge "$times" ]; then return 1; fi
        echo "⚠️  Failed (attempt $n/$times): $*  -- retrying in ${delay}s" >&2
        n=$((n + 1))
        sleep "$delay"
    done
}

# ---------------------------------------------------------------- 1. archive
echo "▶ 1/7 Locating Xcode project..."
CONTAINER_FLAG=()
WORKSPACE=$(find "$PROJECT_DIR" -maxdepth 1 -name "*.xcworkspace" | head -n 1)
PROJECT=$(find "$PROJECT_DIR" -maxdepth 1 -name "*.xcodeproj" | head -n 1)
if [ -n "$WORKSPACE" ]; then
    CONTAINER_FLAG=(-workspace "$WORKSPACE")
    echo "   using workspace: $WORKSPACE"
elif [ -n "$PROJECT" ]; then
    CONTAINER_FLAG=(-project "$PROJECT")
    echo "   using project: $PROJECT"
else
    echo "❌ No .xcworkspace or .xcodeproj found in $PROJECT_DIR"
    exit 1
fi

echo "▶ 2/7 Archiving (clean Release build, this takes a while)..."
rm -rf "$WORK_DIR"
mkdir -p "$WORK_DIR"
ARCHIVE_PATH="$WORK_DIR/$SCHEME.xcarchive"
DERIVED="$WORK_DIR/DerivedData"

# Signing during the build needs Apple's timestamp server; a dropped request fails the whole
# archive. The compiled code is cached in DerivedData, so a retry is quick.
do_archive() {
    rm -rf "$ARCHIVE_PATH"
    xcodebuild archive \
        "${CONTAINER_FLAG[@]}" \
        -scheme "$SCHEME" \
        -configuration Release \
        -destination 'generic/platform=macOS' \
        -archivePath "$ARCHIVE_PATH" \
        -derivedDataPath "$DERIVED" \
        -allowProvisioningUpdates \
        ENABLE_HARDENED_RUNTIME=YES \
        -quiet
}
retry 5 10 do_archive

echo "▶ 3/7 Exporting with Developer ID signing (Xcode signs all nested frameworks)..."

# Some prebuilt frameworks (e.g. MediaRemoteAdapter) ship malformed:
#  - the top-level binary is a real file instead of a symlink to Versions/Current/<binary>
#    (makes codesign say "bundle format is ambiguous")
#  - Info.plist lacks CFBundleSupportedPlatforms (makes export say "Couldn't find platform family")
# Repair both inside the archive. Export re-signs everything afterwards, so this is safe.
repair_frameworks() {
    local app="$1" fw exec_name plist
    while IFS= read -r fw; do
        # (a) CFBundleSupportedPlatforms
        for plist in "$fw"/Versions/*/Resources/Info.plist; do
            [ -f "$plist" ] || continue
            python3 -I - "$plist" << 'PYEOF'
import plistlib, sys
path = sys.argv[1]
with open(path, "rb") as f:
    data = plistlib.load(f)
if "CFBundleSupportedPlatforms" not in data:
    data["CFBundleSupportedPlatforms"] = ["MacOSX"]
    with open(path, "wb") as f:
        plistlib.dump(data, f, fmt=plistlib.FMT_XML)
    print("   repaired: added CFBundleSupportedPlatforms to " + path)
PYEOF
        done
        # (b) top-level binary must be a symlink into Versions/Current
        plist=$(ls "$fw"/Versions/*/Resources/Info.plist 2>/dev/null | head -n 1 || true)
        [ -n "$plist" ] || continue
        exec_name=$(python3 -I -c "import plistlib,sys; print(plistlib.load(open(sys.argv[1],'rb')).get('CFBundleExecutable',''))" "$plist")
        if [ -n "$exec_name" ] && [ -f "$fw/$exec_name" ] && [ ! -L "$fw/$exec_name" ] && [ -e "$fw/Versions/Current/$exec_name" ]; then
            rm -f "$fw/$exec_name"
            ln -s "Versions/Current/$exec_name" "$fw/$exec_name"
            echo "   repaired: $fw/$exec_name is now a symlink"
        fi
    done < <(find "$app" -type d -name "*.framework")
}

ARCHIVED_APP=$(find "$ARCHIVE_PATH/Products/Applications" -maxdepth 1 -name "*.app" -type d | head -n 1)
if [ -n "$ARCHIVED_APP" ]; then
    repair_frameworks "$ARCHIVED_APP"
fi

EXPORT_DIR="$WORK_DIR/export"
cat > "$WORK_DIR/ExportOptions.plist" << EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>method</key><string>developer-id</string>
    <key>teamID</key><string>$TEAM_ID</string>
    <key>signingStyle</key><string>automatic</string>
</dict>
</plist>
EOF

# Export signs many files and each needs Apple's timestamp server; one dropped request fails the
# whole export. The archive is already built, so simply retry the export.
do_export() {
    rm -rf "$EXPORT_DIR"
    xcodebuild -exportArchive \
        -archivePath "$ARCHIVE_PATH" \
        -exportPath "$EXPORT_DIR" \
        -exportOptionsPlist "$WORK_DIR/ExportOptions.plist" \
        -allowProvisioningUpdates
}
retry 5 10 do_export

APP_PATH=$(find "$EXPORT_DIR" -maxdepth 1 -name "*.app" -type d | head -n 1)
if [ -z "$APP_PATH" ]; then
    echo "❌ Export produced no .app in $EXPORT_DIR"
    exit 1
fi
APP_NAME=$(basename "$APP_PATH")
echo "   exported: $APP_PATH"

echo "   verifying signature..."
codesign --verify --deep --strict --verbose=2 "$APP_PATH"

# Notarization rejects apps without the hardened runtime; catch it now instead of after the upload.
SIGN_INFO=$(codesign -dv --verbose=4 "$APP_PATH" 2>&1 || true)
FLAGS_LINE=$(grep -m1 "flags=" <<< "$SIGN_INFO" || true)
echo "   signature flags: ${FLAGS_LINE:-<none found>}"
if ! grep -q "flags=.*runtime" <<< "$SIGN_INFO"; then
    echo "❌ The exported app does not have the hardened runtime enabled."
    echo "   In Xcode: target → Signing & Capabilities → add/enable 'Hardened Runtime', then run again."
    exit 1
fi
echo "   hardened runtime: enabled"

# With the hardened runtime on, controlling other apps (System Events etc.) needs this entitlement.
ENTITLEMENTS_INFO=$(codesign -d --entitlements :- "$APP_PATH" 2>/dev/null || true)
if ! grep -q "com.apple.security.automation.apple-events" <<< "$ENTITLEMENTS_INFO"; then
    echo "⚠️  The app lacks the Apple Events entitlement (com.apple.security.automation.apple-events)."
    echo "   If RemoCon controls other apps, enable it in Xcode: Signing & Capabilities → Hardened Runtime → Apple Events."
fi

PLIST="$APP_PATH/Contents/Info.plist"
VERSION=$(defaults read "$PLIST" CFBundleShortVersionString)
BUILD_NUMBER=$(defaults read "$PLIST" CFBundleVersion)
BUNDLE_ID=$(defaults read "$PLIST" CFBundleIdentifier)
MIN_OS_VERSION=$(defaults read "$PLIST" LSMinimumSystemVersion 2>/dev/null || echo "")
TAG_NAME="v$VERSION"
PKG_NAME="RemoConServer_$TAG_NAME.pkg"
PKG_PATH="$RELEASE_DIR/$PKG_NAME"
echo "   version $VERSION (build $BUILD_NUMBER), bundle id $BUNDLE_ID"

# Guard: Sparkle compares build numbers; refuse to publish one that is already in the appcast.
if [ -f "$APPCAST_PATH" ] && grep -q "<sparkle:version>$BUILD_NUMBER</sparkle:version>" "$APPCAST_PATH"; then
    echo "❌ Build number $BUILD_NUMBER is already in appcast.xml."
    echo "   Increase the build number (CFBundleVersion) in Xcode, then run again."
    exit 1
fi

SIGN_UPDATE=$(find "$DERIVED/SourcePackages" -type f -name sign_update 2>/dev/null | head -n 1)
if [ -z "$SIGN_UPDATE" ]; then
    SIGN_UPDATE=$(command -v sign_update || true)
fi
if [ -z "$SIGN_UPDATE" ]; then
    echo "❌ Could not find Sparkle's sign_update tool."
    exit 1
fi

# ---------------------------------------------------------------- 2. pkg
echo "▶ 4/7 Building signed PKG..."
PAYLOAD_DIR="$WORK_DIR/payload"
SCRIPTS_DIR="$WORK_DIR/scripts"
mkdir -p "$PAYLOAD_DIR" "$SCRIPTS_DIR"
ditto "$APP_PATH" "$PAYLOAD_DIR/$APP_NAME"

cat > "$SCRIPTS_DIR/postinstall" << EOF
#!/bin/bash
# Relaunch the app in the logged-in user's GUI session after install.
LOGGED_IN_USER=\$(stat -f "%Su" /dev/console)
USER_ID=\$(id -u "\$LOGGED_IN_USER")
/bin/launchctl asuser "\$USER_ID" /usr/bin/open "/Applications/$APP_NAME"
exit 0
EOF
chmod +x "$SCRIPTS_DIR/postinstall"

mkdir -p "$RELEASE_DIR"
rm -f "$PKG_PATH"
pkgbuild --root "$PAYLOAD_DIR" \
         --install-location "/Applications" \
         --scripts "$SCRIPTS_DIR" \
         --identifier "$BUNDLE_ID" \
         --version "$VERSION" \
         --sign "$PKG_SIGNING_IDENTITY" \
         --timestamp \
         "$PKG_PATH"

# ---------------------------------------------------------------- 3. notarize
echo "▶ 5/7 Notarizing (waits for Apple)..."
NOTARY_OUT=$(xcrun notarytool submit "$PKG_PATH" \
    --apple-id "$APPLE_ID" \
    --team-id "$TEAM_ID" \
    --password "$APP_PASS" \
    --wait 2>&1) || true
echo "$NOTARY_OUT"
if ! echo "$NOTARY_OUT" | grep -q "status: Accepted"; then
    echo "❌ Notarization was not accepted. Apple's log for this submission:"
    SUBMISSION_ID=$(echo "$NOTARY_OUT" | sed -n 's/^ *id: *\([0-9a-f-]\{36\}\).*/\1/p' | head -n 1)
    if [ -n "$SUBMISSION_ID" ]; then
        xcrun notarytool log "$SUBMISSION_ID" \
            --apple-id "$APPLE_ID" --team-id "$TEAM_ID" --password "$APP_PASS" || true
    fi
    exit 1
fi
retry 3 5 xcrun stapler staple "$PKG_PATH"

# ---------------------------------------------------------------- 4. appcast
echo "▶ 6/7 Signing for Sparkle and updating appcast.xml..."
SIGN_OUTPUT=$("$SIGN_UPDATE" "$PKG_PATH")
ED_SIGNATURE=$(echo "$SIGN_OUTPUT" | sed -n 's/.*sparkle:edSignature="\([^"]*\)".*/\1/p')
FILE_LENGTH=$(echo "$SIGN_OUTPUT" | sed -n 's/.*length="\([^"]*\)".*/\1/p')
if [ -z "$ED_SIGNATURE" ] || [ -z "$FILE_LENGTH" ]; then
    echo "❌ sign_update returned no signature. Output was: $SIGN_OUTPUT"
    exit 1
fi

PUB_DATE=$(LC_ALL=C date -u +"%a, %d %b %Y %H:%M:%S +0000")
DOWNLOAD_URL="https://raw.githubusercontent.com/$GITHUB_USERNAME/$REPO_NAME/main/$PKG_NAME"

# Make sure local repo is current before editing appcast.xml
if [ -d "$RELEASE_DIR/.git" ]; then
    git -C "$RELEASE_DIR" pull --rebase --autostash origin main || true
fi

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
    root = ET.Element("rss", {"version": "2.0"})
    channel = ET.SubElement(root, "channel")
    ET.SubElement(channel, "title").text = "RemoConServer"
    tree = ET.ElementTree(root)

# Drop any older entry for the same build number
for old in list(channel.findall("item")):
    v = old.find("{%s}version" % NS)
    if v is not None and v.text == build_number:
        channel.remove(old)

item = ET.Element("item")
ET.SubElement(item, "title").text = version
ET.SubElement(item, "pubDate").text = pub_date
ET.SubElement(item, "{%s}version" % NS).text = build_number
ET.SubElement(item, "{%s}shortVersionString" % NS).text = version
if min_os:
    ET.SubElement(item, "{%s}minimumSystemVersion" % NS).text = min_os
ET.SubElement(item, "enclosure", {
    "url": url,
    "length": length,
    "type": "application/octet-stream",
    "{%s}installationType" % NS: "package",
    "{%s}edSignature" % NS: ed_sig,
})

idx = len(list(channel))
for i, child in enumerate(channel):
    if child.tag == "item":
        idx = i
        break
channel.insert(idx, item)

ET.indent(tree, space="    ")
tree.write(appcast_path, encoding="utf-8", xml_declaration=True)

# Re-parse to prove the file is valid XML before it gets published
ET.parse(appcast_path)
print("   appcast.xml updated and validated: %s (%s)" % (version, build_number))
PYEOF

# ---------------------------------------------------------------- 5. publish
echo "▶ 7/7 Publishing to GitHub..."
ORIGINAL_COMMIT_MSG="Release $TAG_NAME"

cd "$RELEASE_DIR"
if [ ! -d ".git" ]; then
    git init
    git remote add origin "https://github.com/$GITHUB_USERNAME/$REPO_NAME.git"
    git branch -M main
fi

# Never commit secrets or build leftovers
touch .gitignore
for pattern in "release.config" ".DS_Store"; do
    grep -qxF "$pattern" .gitignore || echo "$pattern" >> .gitignore
done

git add .
git commit -m "Update appcast for release $TAG_NAME" || true
git pull --rebase --autostash origin main
retry 3 5 git push origin main

if gh release view "$TAG_NAME" --repo "$GITHUB_USERNAME/$REPO_NAME" >/dev/null 2>&1; then
    gh release upload "$TAG_NAME" "$PKG_PATH" --repo "$GITHUB_USERNAME/$REPO_NAME" --clobber
else
    gh release create "$TAG_NAME" "$PKG_PATH" \
        --repo "$GITHUB_USERNAME/$REPO_NAME" \
        --title "RemoConServer $TAG_NAME" \
        --notes "$ORIGINAL_COMMIT_MSG"
fi

rm -rf "$WORK_DIR"
echo "✅ Done: $TAG_NAME (build $BUILD_NUMBER) archived, signed, notarized, appcast updated, published."
echo "   Note: raw.githubusercontent.com can serve the old appcast for a few minutes."
