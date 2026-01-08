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
2. Notarizes with Apple (automated, ~5-15 min)
3. Staples the notarization ticket to the app
4. Creates `Detours-<version>.zip`
5. Tags the release as `v<version>`

After the script completes, follow the printed instructions to push the tag and create the GitHub release.

### Manual steps (if needed)

Build:
```bash
resources/scripts/build.sh
```

Notarize and staple:
```bash
xcrun notarytool submit .build/Build/Products/Release/Detours.app \
  --keychain-profile "detours-notarize" --wait
xcrun stapler staple .build/Build/Products/Release/Detours.app
```

Zip:
```bash
cd .build/Build/Products/Release
zip -r Detours-0.6.1.zip Detours.app
```

Tag and release:
```bash
git tag -a v0.6.1 -m "Version 0.6.1"
git push public v0.6.1
gh release create v0.6.1 \
  --repo detours-app/detours \
  --title "Detours v0.6.1" \
  --notes "Release notes" \
  Detours-0.6.1.zip
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
