#!/bin/bash
set -euo pipefail

# Release script for Detours
# Usage: ./resources/scripts/release.sh

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
DOCS_PREFLIGHT_FILE="$PROJECT_DIR/.build/update-docs-preflight"

ensure_main_branch() {
    local project_dir="$1"
    local current_branch
    current_branch=$(git -C "$project_dir" branch --show-current)
    if [[ "$current_branch" != "main" ]]; then
        echo "Error: Must be on main branch to release (currently on $current_branch)"
        return 1
    fi
}

ensure_release_tag_available_or_at_head() {
    local project_dir="$1"
    local version="$2"
    if git -C "$project_dir" rev-parse "v$version" >/dev/null 2>&1; then
        local tag_commit
        local head_commit
        tag_commit=$(git -C "$project_dir" rev-parse "v$version^{}")
        head_commit=$(git -C "$project_dir" rev-parse HEAD)
        if [[ "$tag_commit" != "$head_commit" ]]; then
            echo "Error: Tag v$version already exists but does not point at HEAD"
            echo "  tag:  $tag_commit"
            echo "  HEAD: $head_commit"
            echo "Bump VERSION or move the local tag intentionally before releasing."
            return 1
        fi
        echo "Tag v$version already points at HEAD, skipping"
        return 2
    fi
    return 0
}

ensure_update_docs_preflight() {
    local project_dir="$1"
    local preflight_file="$2"
    local status
    status=$(git -C "$project_dir" status --porcelain)
    if [[ -n "$status" ]]; then
        echo "Error: Worktree has uncommitted changes."
        echo "Run \$update-docs first, commit any docs changes, then confirm the preflight:"
        echo "  resources/scripts/confirm-update-docs.sh"
        return 1
    fi

    if [[ ! -f "$preflight_file" ]]; then
        echo "Error: Missing \$update-docs preflight confirmation for this release."
        echo "Run \$update-docs first, commit any docs changes, then confirm the preflight:"
        echo "  resources/scripts/confirm-update-docs.sh"
        return 1
    fi

    local expected_commit
    local confirmed_commit
    expected_commit=$(git -C "$project_dir" rev-parse HEAD)
    confirmed_commit=$(awk -F= '$1 == "commit" { print $2 }' "$preflight_file" | tail -n 1)

    if [[ "$confirmed_commit" != "$expected_commit" ]]; then
        echo "Error: \$update-docs preflight is stale."
        echo "  confirmed: ${confirmed_commit:-missing}"
        echo "  HEAD:      $expected_commit"
        echo "Run \$update-docs again, commit any docs changes, then confirm the preflight:"
        echo "  resources/scripts/confirm-update-docs.sh"
        return 1
    fi
}

main() {
# Ensure we're on main branch
ensure_main_branch "$PROJECT_DIR"

echo "==> Verifying \$update-docs preflight..."
ensure_update_docs_preflight "$PROJECT_DIR" "$DOCS_PREFLIGHT_FILE"

# Read version from VERSION file (single source of truth)
VERSION=$(cat "$PROJECT_DIR/VERSION")

if [[ -z "$VERSION" ]]; then
    echo "Error: VERSION file is empty"
    exit 1
fi

echo "Version: $VERSION"
APP_PATH="$PROJECT_DIR/build/Detours.app"
DMG_NAME="Detours-$VERSION.dmg"
DMG_PATH="$PROJECT_DIR/$DMG_NAME"
STAGING_DIR="$PROJECT_DIR/.build/dmg-staging"

cd "$PROJECT_DIR"

echo "==> Building release..."
"$SCRIPT_DIR/build.sh" --no-install

if [[ ! -d "$APP_PATH" ]]; then
    echo "Error: Build failed, no app at $APP_PATH"
    exit 1
fi

echo "==> Creating DMG..."
rm -rf "$STAGING_DIR"
mkdir -p "$STAGING_DIR"
cp -R "$APP_PATH" "$STAGING_DIR/"
ln -s /Applications "$STAGING_DIR/Applications"

rm -f "$DMG_PATH"
hdiutil create -volname "Detours" -srcfolder "$STAGING_DIR" -ov -format UDZO "$DMG_PATH"
rm -rf "$STAGING_DIR"

echo "==> Signing DMG..."
CODESIGN_IDENTITY="${CODESIGN_IDENTITY:-Developer ID Application: Marco Fruh (AHUQTWVD7X)}"
CODESIGN_DMG_ARGS=(--force --timestamp --sign "$CODESIGN_IDENTITY")
if [[ -n "${CODESIGN_KEYCHAIN:-}" ]]; then
    CODESIGN_DMG_ARGS+=(--keychain "$CODESIGN_KEYCHAIN")
fi
/usr/bin/codesign "${CODESIGN_DMG_ARGS[@]}" "$DMG_PATH"

echo "==> Notarizing DMG..."
# Submit for notarization (requires keychain profile "detours-notarize")
# Set up with: xcrun notarytool store-credentials "detours-notarize" ...
NOTARY_PROFILE="${NOTARY_PROFILE:-detours-notarize}"
NOTARY_KEYCHAIN="${NOTARY_KEYCHAIN:-${CODESIGN_KEYCHAIN:-}}"
NOTARY_KEYCHAIN_PASSWORD="${NOTARY_KEYCHAIN_PASSWORD:-${CODESIGN_KEYCHAIN_PASSWORD:-}}"
NOTARY_KEYCHAIN_PASSWORD_FILE="${NOTARY_KEYCHAIN_PASSWORD_FILE:-${CODESIGN_KEYCHAIN_PASSWORD_FILE:-}}"

if [[ -n "$NOTARY_KEYCHAIN_PASSWORD_FILE" ]]; then
    NOTARY_KEYCHAIN_PASSWORD="$(cat "$NOTARY_KEYCHAIN_PASSWORD_FILE")"
fi

if [[ -n "$NOTARY_KEYCHAIN" && -n "$NOTARY_KEYCHAIN_PASSWORD" ]]; then
    security unlock-keychain -p "$NOTARY_KEYCHAIN_PASSWORD" "$NOTARY_KEYCHAIN"
    NOTARY_KEYCHAIN_PASSWORD=""
fi

NOTARY_ARGS=(--keychain-profile "$NOTARY_PROFILE")
if [[ -n "$NOTARY_KEYCHAIN" ]]; then
    NOTARY_ARGS+=(--keychain "$NOTARY_KEYCHAIN")
fi

xcrun notarytool submit "$DMG_PATH" "${NOTARY_ARGS[@]}" --wait

echo "==> Stapling notarization ticket..."
xcrun stapler staple "$DMG_PATH"

echo "==> Generating release notes..."
CHANGELOG="$PROJECT_DIR/resources/docs/CHANGELOG.md"
RELEASE_NOTES="$PROJECT_DIR/RELEASE_NOTES.md"

# Extract latest version section from changelog
# Format: ## X.Y.Z (YYMMDD) - skips "## Unreleased" section
# Captures from version header to next version header or end
LATEST_ENTRY=$(awk '
    /^## [0-9]+\.[0-9]+\.[0-9]+/ {
        if (found) exit
        found = 1
    }
    found { print }
' "$CHANGELOG")
ENTRY_BODY=$(echo "$LATEST_ENTRY" | tail -n +2)

cat > "$RELEASE_NOTES" << EOF
## What's New in $VERSION

$ENTRY_BODY

---

Detours is a fast, keyboard-driven file manager for macOS with dual-pane layout, Quick Open, and full keyboard control.

**Requirements:** macOS 14.0 (Sonoma) or later
EOF

echo "==> Tagging v$VERSION..."
TAG_STATUS=0
ensure_release_tag_available_or_at_head "$PROJECT_DIR" "$VERSION" || TAG_STATUS=$?
if [[ "$TAG_STATUS" == "0" ]]; then
    git tag -a "v$VERSION" -m "Version $VERSION"
elif [[ "$TAG_STATUS" != "2" ]]; then
    exit "$TAG_STATUS"
fi

echo ""
echo "Release prepared: $DMG_PATH"
echo ""
read -p "Push tag and upload DMG to GitHub? [y/N] " -n 1 -r
echo ""
if [[ $REPLY =~ ^[Yy]$ ]]; then
    echo "==> Pushing main to public..."
    git push public main

    echo "==> Pushing tag v$VERSION..."
    git push public "v$VERSION"

    echo "==> Waiting for GitHub Actions to create release..."
    sleep 10

    echo "==> Uploading DMG..."
    gh release upload "v$VERSION" "$DMG_NAME" --repo detours-app/detours --clobber

    echo ""
    echo "Done! https://github.com/detours-app/detours/releases/tag/v$VERSION"
else
    echo "Skipped. To publish manually:"
    echo "  git push public main"
    echo "  git push public v$VERSION"
    echo "  gh release upload v$VERSION $DMG_NAME --repo detours-app/detours --clobber"
fi
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
