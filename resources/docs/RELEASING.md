# Releasing Detours

This document covers syncing to the public repo and creating releases.

## Repository Setup

- **Private repo (development)**: `MAF27/detours` (origin)
- **Public repo (releases)**: `detours-app/detours`

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

```bash
./resources/scripts/release.sh
```

The script reads the version from `src/App/AppDelegate.swift` and:
1. Builds the release binary
2. Creates a DMG with the app and Applications symlink
3. Notarizes the DMG with Apple (automated, ~5-15 min)
4. Staples the notarization ticket to the DMG
5. Tags the release as `v<version>`

After the script completes, follow the printed instructions to push the tag and create the GitHub release.

### Manual steps (if needed)

Build:
```bash
resources/scripts/build.sh
```

Create DMG:
```bash
mkdir -p .build/dmg-staging
cp -R .build/Build/Products/Release/Detours.app .build/dmg-staging/
ln -s /Applications .build/dmg-staging/Applications
hdiutil create -volname "Detours" -srcfolder .build/dmg-staging -ov -format UDZO Detours-0.7.0.dmg
rm -rf .build/dmg-staging
```

Notarize and staple:
```bash
xcrun notarytool submit Detours-0.7.0.dmg \
  --keychain-profile "detours-notarize" --wait
xcrun stapler staple Detours-0.7.0.dmg
```

Tag and release:
```bash
git tag -a v0.7.0 -m "Version 0.7.0"
git push public v0.7.0
gh release create v0.7.0 \
  --repo detours-app/detours \
  --title "Detours v0.7.0" \
  --notes "Release notes" \
  Detours-0.7.0.dmg
```

## Version Numbering

- Format: `0.x.y`
- Increment `x` for new features
- Increment `y` for bug fixes
- Update version in `src/App/AppDelegate.swift` (applicationVersion)

## Pre-release Checklist

- [ ] All tests pass
- [ ] CHANGELOG.md updated
- [ ] Version number bumped
- [ ] Build succeeds in release mode
- [ ] App launches and basic functionality works
- [ ] No debug logging left enabled

## Notarization Notes

Notarization is Apple's automated malware scan. Without it, users get "unidentified developer" and must right-click → Open. With it, the app opens normally.

Requires Apple Developer account ($99/year). No human review - fully automated.
