# Build Skill

**MANDATORY**: This is the ONLY way to build this project.

## Command

```bash
resources/scripts/build.sh
```

## Rules

- NEVER run `swift build` directly
- NEVER run `swift build 2>&1`
- NEVER run `swift build | anything`
- ALWAYS use `resources/scripts/build.sh`

The build script handles:
- Quitting the running app first
- Building with swift build
- Copying executable to app bundle
- Code signing with entitlements
- Refreshing Spotlight

## Usage

When the user asks to build, compile, or rebuild:

```bash
resources/scripts/build.sh
```

That's it. No other command. Ever.
