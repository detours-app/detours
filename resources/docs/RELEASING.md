# Releasing Detours

This document covers syncing to the public repo and creating releases.

## Repository Setup

- **Private repo (development)**: origin
- **Public repo (releases)**: `detours-app/detours` (public remote)

## One-time Setup

### Add public remote

```bash
git remote add public https://github.com/detours-app/detours.git
```

### Store notarization credentials

1. Get your **Team ID** from https://developer.apple.com/account → Membership
2. Generate an **app-specific password** at https://appleid.apple.com → Sign-In and Security → App-Specific Passwords
3. Store credentials in keychain:

```bash
xcrun notarytool store-credentials "detours-notarize" \
  --apple-id "marcofruh@me.com" \
  --team-id "ABC123DEF4" \
  --password "xxxx-xxxx-xxxx-xxxx"
```

(Or omit the flags to be prompted interactively)

## Syncing to Public Repo

```bash
git checkout main
git status  # should be clean
git push public main
```

## Creating a Release

### Using the release script

Run the docs reconciliation before every release:

```bash
$update-docs
resources/scripts/confirm-update-docs.sh
```

The confirmation helper records the current clean commit after the docs pass. `release.sh` refuses to continue if the confirmation is missing, stale, or the worktree has uncommitted changes.

```bash
./resources/scripts/release.sh
```

The script reads the version from the root `VERSION` file and:

1. Verifies the `$update-docs` preflight for the current clean commit
2. Builds the release binary
3. Creates a DMG with the app and Applications symlink
4. Signs the DMG with the Developer ID Application identity
5. Notarizes the DMG with Apple (automated, ~5-15 min)
6. Staples the notarization ticket to the DMG
7. Tags the release as `v<version>`

The script will prompt to push `main`, push the tag, and upload the DMG. Press `y` to publish automatically, or `n` to do it manually later.

### Manual steps (if needed)

Build:

```bash
resources/scripts/build.sh
```

Create DMG:

```bash
version=$(cat VERSION)
mkdir -p .build/dmg-staging
cp -R build/Detours.app .build/dmg-staging/
ln -s /Applications .build/dmg-staging/Applications
hdiutil create -volname "Detours" -srcfolder .build/dmg-staging -ov -format UDZO "Detours-$version.dmg"
rm -rf .build/dmg-staging
```

Sign, notarize, and staple:

```bash
codesign --force --timestamp \
  --sign "Developer ID Application: Marco Fruh (AHUQTWVD7X)" \
  "Detours-$version.dmg"
xcrun notarytool submit "Detours-$version.dmg" \
  --keychain-profile "detours-notarize" --wait
xcrun stapler staple "Detours-$version.dmg"
```

Tag and release:

```bash
git tag -a "v$version" -m "Version $version"
git push public main
git push public "v$version"
# GitHub Actions creates release automatically
gh release upload "v$version" "Detours-$version.dmg" --repo detours-app/detours --clobber
```

## Version Numbering

- Format: `1.x.y`
- Increment `x` for new features
- Increment `y` for bug fixes
- Update version in the root `VERSION` file

## Pre-release Checklist

- [ ] All tests pass
- [ ] `$update-docs` run and `resources/scripts/confirm-update-docs.sh` completed for the release commit
- [ ] CHANGELOG.md updated (heading changed from "Unreleased" to version + date)
- [ ] `VERSION` file bumped (single source of truth - build.sh reads this)
- [ ] Build succeeds in release mode
- [ ] DMG is Developer ID signed
- [ ] Notarization succeeds and staple validates
- [ ] Gatekeeper accepts the DMG and mounted app
- [ ] App launches and basic functionality works
- [ ] No debug logging left enabled

## Notarization Notes

Notarization is Apple's automated malware scan. Without it, users get "unidentified developer" and must right-click → Open. With it, the app opens normally.

Requires Apple Developer account ($99/year). No human review - fully automated.
