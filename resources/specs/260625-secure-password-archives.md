# Secure Password-Protected Archives (ZIP and 7Z)

## Meta

- Status: Draft
- Branch: feature/secure-password-archives

---

## Business

### Goal

Bring back password protection for archives. Detours can already create and open ZIP and 7Z archives; it used to let you put a password on them too, but that was switched off because the password was handed to the underlying compression tools in a way that other programs on the same Mac could read while the archive was being built. This change brings password protection back, this time keeping the password private the whole time.

### Proposal

Re-enable the "Encrypt with password" option in the Create Archive dialog for ZIP and 7Z, and let Detours open password-protected ZIP and 7Z archives, with the password never exposed to other programs running on the machine.

### Behaviors

- **The "Encrypt with password" checkbox works again for ZIP and 7Z.** Choosing ZIP or 7Z in the Create Archive dialog enables the checkbox; ticking it reveals a password field. The TAR formats (TAR.GZ, TAR.BZ2, TAR.XZ) keep the checkbox disabled, because those formats cannot carry a password.
- **Creating an encrypted archive.** With the checkbox ticked and a password typed, the finished archive requires that password to open. The archive name, format choice, and progress display behave exactly as they do today.
- **Opening an encrypted archive.** When Detours is asked to extract an archive that turns out to be password-protected, it asks for the password and then extracts. If the password is wrong, it says so and asks again rather than failing silently or producing a broken result.
- **Same behavior for archives on a connected server.** Creating and opening password-protected ZIP and 7Z archives works the same way when the files live on a remote server, not just on the Mac.
- **The password stays private.** At no point can another program running on the same machine read the password by inspecting the running compression tool.

### Acceptance Criteria

- [ ] **A1** In the Create Archive dialog, selecting ZIP or 7Z enables the "Encrypt with password" checkbox; selecting any TAR format leaves it disabled.
- [ ] **A2** Ticking the checkbox reveals a password field, and creating the archive with a password produces an archive that requires that password to open.
- [ ] **A3** A ZIP or 7Z archive created with a password by Detours can be opened again by Detours using the correct password, and the extracted contents match the originals.
- [ ] **A4** Opening a password-protected archive with the correct password succeeds; opening it with the wrong password reports that the password was incorrect and prompts again, and never leaves a partial or broken extraction behind.
- [ ] **A5** While an encrypted archive is being created or opened, the password does not appear in the list of running processes or their arguments visible to other programs on the machine.
- [ ] **A6** Creating and opening password-protected ZIP and 7Z archives on a connected remote server behaves the same as on the Mac.
- [ ] **A7** Creating and opening archives without a password, and all TAR formats, behave exactly as they do today, including the progress display.

### Out of scope

- Password protection for TAR-based formats (TAR.GZ, TAR.BZ2, TAR.XZ) — those formats have no native encryption and remain unencryptable.
- Remembering, storing, or auto-filling archive passwords (no Keychain integration); each create and each extract asks for the password as needed.
- Changing the set of supported archive formats or the compression tools used.

---

## Technical

### Approach

The reason passwords were disabled (audit commit `862884b`, 2026-06-14, finding: "Archive passwords are passed in subprocess argv for zip, unzip, and 7z flows") is that `zip -P`, `unzip -P`, and `7z -pPASSWORD` place the secret in the process argument vector, readable via `ps` by any process on the host. The compression CLIs offer no stdin, file-descriptor, or environment option for the password; their only non-argv path is the interactive terminal prompt. Therefore the secure mechanism is to run each tool attached to a pseudo-terminal (pty) and answer its password prompt by writing to the pty master. This is verified behavior: `zip -er` refuses to run unless its terminal is a tty and prompts twice (enter + verify); `unzip` reads the password from `/dev/tty` (a plain pipe does not work) and a single write covers the whole archive; `7z a -p` (switch with no inline value) and `7z x -p` prompt on the tty as well. Foundation's `Process`/NSTask cannot attach a controlling terminal, so the runner is built directly on `openpty()` + `posix_spawn` with `POSIX_SPAWN_SETSID` (available since macOS 10.15; the app targets 14.0+).

A new shared library target, `DetoursProcess` (path `Shared/`), holds the pty runner so both the app (`src`) and the remote helper (`Server`) use one tested implementation; both executable targets and the test target depend on it. The runner spawns the tool on a pty, then feeds the password by responding to each prompt as it appears: it detects the prompt by waiting for the child to clear the terminal's ECHO flag (the moment the tool switches the tty to no-echo to read a secret), writes the password followed by a newline, and repeats for each subsequent prompt until the child either prompts no more or exits. Responding per-prompt rather than writing a fixed number of times absorbs the difference between tools that prompt once (extraction, official 7-Zip create) and twice (zip create, p7zip create). The runner reads all pty output into a buffer (for tools whose progress or errors now arrive on the pty), reaps the child, and returns exit status plus captured output. A short settle delay before each write avoids the known echo race where writing before the tool disables echo leaks the password into the tool's output stream.

Local create/extract live in `src/Operations/FileOperationQueue.swift`. `runZip` and `runSevenZip` switch to the pty runner when a non-empty password is present (and keep today's `Process`-based path when there is no password, preserving the existing `pollFileSize` progress for zip and the `parseStderr`/`-bsp2` progress for 7z). With a password, 7z's `-bsp2` progress arrives on the pty stream, so the 7z password path parses percentage from the pty buffer instead of a separate stderr pipe; zip's password path keeps `pollFileSize` (it only stats the growing output file, unaffected by the pty). Extraction (`performExtract`, `extractZipWithUnzip`, the 7z extract path, and the 7z listing path) routes encrypted archives through the pty runner with the supplied password. Wrong-password outcomes are mapped to a clear error so the existing caller re-prompts: `unzip` exit code 82 and a 7z encrypted-data failure both surface as the "incorrect password" path (reusing `archivePasswordRequired` so the caller's existing prompt loop runs again); a partial extraction directory is removed on failure via the existing app-created-temp cleanup.

Restoration work: `ArchiveFormat.supportsPassword` (`src/Utilities/CompressionTools.swift`) returns true for `.zip` and `.sevenZ` again and false for the TAR formats; the `archivePasswordUnsupported` throws added by the audit in `performArchive`, `runZip`, `runSevenZip`, `performExtract`, `extractZipWithUnzip`, the 7z extract path, and the 7z listing path are removed; the "Password Archives Disabled" alert branch in `FileOperationQueue` is removed (the `archivePasswordUnsupported` enum case in `FileOperationError.swift` is removed once unreferenced). `ArchiveDialog.swift` needs no structural change — the checkbox and SecureField are already wired and gated on `supportsPassword`; restoring the flag re-enables them.

Remote parity lives in `Server/ArchiveOperations.swift`. The audit replaced the password branches with a `["--passwords-disabled"]` sentinel argument and an up-front `passwordUnsupported` throw. Those are removed; `createCommand`/`extractCommand` build the real prompt-mode invocations (`zip -er`, `7z a -p`, `unzip`, `7z x -p`) and, when a password is present, the helper runs them through the shared pty runner instead of the default `ProcessRunner`. The `ProcessRunner` typealias gains an optional password so the helper can inject a test runner; the default runner uses the pty path when a password is supplied. The helper's coarse progress frames (starting/completed) are unchanged.

### Approach Validation

Researched the password-feeding options for `zip`, `unzip`, and the 7-Zip CLI, and the macOS pty mechanics, before settling on the design:

- **No non-tty secret path exists for these tools**, so the audit's recommendation of "stdin / protected fd / 0600 temp file" is not directly achievable — none of the three CLIs read the password from stdin, a file, or an environment variable. `zip` explicitly errors if its terminal is not a tty; `unzip` reads from `/dev/tty`, not stdin; `7z` reads from the tty. The pty prompt path is the only argv-free mechanism, confirmed against the Info-ZIP man pages (`zip(1)` "the password prompt is repeated", `unzip(1)`) and the 7-Zip manual. Sources: linux.die.net/man/1/zip, man.archlinux.org unzip(1), 7-zip.org password docs.
- **Prompt count differs across tools and 7z builds** (official 7-Zip prompts once on create, legacy p7zip twice; extraction and unzip prompt once). Driving the response off the terminal's ECHO-flag transition rather than a fixed write count, as recommended in pexpect's guidance on automating password prompts, handles all cases and avoids brittle prompt-string matching. The known echo race is mitigated with a small settle delay before writing. Source: pexpect documentation (`waitnoecho`, `delaybeforesend`).
- **macOS pty plumbing is standard and available**: `openpty()` from `<util.h>` (no extra link flag under `import Darwin`) plus `posix_spawn` with `POSIX_SPAWN_SETSID` to give the child its own session and controlling terminal; `POSIX_SPAWN_SETSID` landed in macOS 10.15, well under the 14.0+ floor. `forkpty()` is the one-call alternative. Confirmed against Apple's xcode-man-pages for `openpty(3)` and `posix_spawnattr_setflags(3)`.
- **Wrong-password detection** is reliable for `unzip` (dedicated exit code 82) and best-effort for 7z (exit code 2 covers encrypted-data failures but also generic corruption); both are mapped to the existing re-prompt path, which is the safe behavior either way (a genuinely corrupt archive simply re-prompts once and then reports failure).

This is a niche capability with no meaningful external user-feedback corpus; the design goal is internal consistency with Detours' existing archive flows plus closing the audit finding, which it does.

### Risks

| Risk | Mitigation |
| ---- | ---------- |
| pty echo race leaks the password into the tool's captured output | Wait for the child to clear the tty ECHO flag before writing, with a small settle delay; never write before the tool opens the tty |
| A tool prompts a different number of times than expected (1 vs 2) | Respond per prompt (on each ECHO-disable transition) up to a small bound, not a fixed write count, so one-prompt and two-prompt tools both work |
| 7z progress (`-bsp2`) now shares the pty with the password prompt and output | The 7z password path parses percentage from the pty buffer after the prompt phase; the no-password path keeps the existing separate-stderr parser untouched |
| Hang if a tool waits on a prompt that never gets answered | The pty runner enforces an overall timeout and a per-prompt wait timeout; on timeout it terminates the child and returns failure |
| Wrong 7z password is indistinguishable from a corrupt archive (exit 2) | Map to the re-prompt path; a corrupt archive re-prompts once then reports failure — no data loss, no silent success |
| Partial/broken output left behind on failure | Remove the partial archive (create) or the `.detours-extract-*` temp directory (extract) on any non-zero exit, reusing the existing app-created-path cleanup |
| Shared pty code drifts between app and helper | Single `DetoursProcess` library target depended on by both executables and the tests, not duplicated source |
| Password bytes linger in memory longer than needed | Hold the password in a local buffer scoped to the runner call and overwrite/zero it after the child exits |

### Implementation Plan

**Phase 1: Shared pty runner**

- [ ] **T1** Add a new library target `DetoursProcess` at path `Shared/` in `Package.swift`, and add it as a dependency of the `Detours`, `detours-server`, and `DetoursTests` targets.
- [ ] **T2** Create `Shared/PtyProcessRunner.swift`: a `PtyProcessRunner` that runs an executable with given arguments and working directory attached to a pty via `openpty()` + `posix_spawn` (`POSIX_SPAWN_SETSID`, slave fd dup2'd onto the child's stdin/stdout/stderr). It accepts an optional password; when present it feeds the password by waiting for the child to clear the tty ECHO flag (`termios`), applying a short settle delay, then writing the password + newline, repeating for each subsequent ECHO-disable transition up to a small bound. It reads all pty output into a buffer, enforces an overall timeout and a per-prompt wait timeout (terminating the child on timeout), reaps the child, zeroes the password buffer, and returns exit status plus captured output. Handle BSD EOF-as-empty-read on child exit.

**Phase 2: Local create**

- [ ] **T3** In `src/Utilities/CompressionTools.swift`, restore `ArchiveFormat.supportsPassword` to return true for `.zip` and `.sevenZ` and false for `.tarGz`/`.tarBz2`/`.tarXz`.
- [ ] **T4** In `src/Operations/FileOperationQueue.swift` `performArchive`, remove the `archivePasswordUnsupported` throw guard so a non-empty password proceeds.
- [ ] **T5** In `src/Operations/FileOperationQueue.swift` `runZip`, remove the `archivePasswordUnsupported` throw; when a non-empty password is present, run `/usr/bin/zip -er -q <dest> <items>` through `PtyProcessRunner` with the password (keeping the working directory and `pollFileSize` progress); when no password, keep the existing `Process` path with `-r -q` unchanged.
- [ ] **T6** In `src/Operations/FileOperationQueue.swift` `runSevenZip`, remove the `archivePasswordUnsupported` throw; when a non-empty password is present, run `7z a -t7z -bsp2 -mhe=on -p <dest> <items>` through `PtyProcessRunner` with the password and parse the `-bsp2` percentage from the pty output buffer for progress; when no password, keep the existing `Process` + separate-stderr `parseStderr` path unchanged.

**Phase 3: Local extract**

- [ ] **T7** In `src/Operations/FileOperationQueue.swift` `performExtract`, remove the `archivePasswordUnsupported` throw guard so a non-empty password proceeds.
- [ ] **T8** In `src/Operations/FileOperationQueue.swift` `extractZipWithUnzip`, remove the `password.isEmpty` guard and the `archivePasswordUnsupported` throw; run `/usr/bin/unzip -o -q <archive> -d <dest>` through `PtyProcessRunner` with the supplied password; map a non-zero exit identified as a bad password (unzip exit code 82) to `FileOperationError.archivePasswordRequired` so the caller re-prompts, and remove the partial destination on failure.
- [ ] **T9** In `src/Operations/FileOperationQueue.swift`, update the 7z extract path (the password branch that currently throws `archivePasswordUnsupported`) to run `7z x -y -bsp2 -p -o<dest> <archive>` through `PtyProcessRunner` with the password; on the encrypted-data failure exit, map to `FileOperationError.archivePasswordRequired` for re-prompt and remove the partial `.detours-extract-*` directory via the existing app-created-directory cleanup.
- [ ] **T10** In `src/Operations/FileOperationQueue.swift`, update the 7z listing path that the audit changed to `return []` when a password is present so it runs `7z l -slt -p <archive>` through `PtyProcessRunner` with the password and returns the real entry list.

**Phase 4: UI and error cleanup**

- [ ] **T11** In `src/Operations/FileOperationQueue.swift`, remove the `case .archivePasswordUnsupported` "Password Archives Disabled" alert branch; in `src/Operations/FileOperationError.swift`, remove the `archivePasswordUnsupported` case and its `localizedDescription` once no references remain.
- [ ] **T12** Confirm `src/Operations/ArchiveDialog.swift` needs no change beyond the restored `supportsPassword` (the checkbox and SecureField are already wired); verify the checkbox enables for ZIP/7Z and the `onChange` clears the password when switching to a TAR format.

**Phase 5: Remote helper parity**

- [ ] **T13** In `Server/ArchiveOperations.swift` `createArchive`, remove the up-front `passwordUnsupported` throw, and in `createCommand` replace the `["--passwords-disabled"]` zip and 7z sentinels with real prompt-mode invocations (`zip -er -q`, `7z a -t7z -mhe=on -p`).
- [ ] **T14** In `Server/ArchiveOperations.swift` `extractArchive`, remove the `passwordUnsupported` throw, and in `extractCommand` replace the `["--passwords-disabled"]` unzip and 7z sentinels with real prompt-mode invocations (`unzip -q`, `7z x -y -p`).
- [ ] **T15** In `Server/ArchiveOperations.swift`, extend the `ProcessRunner` typealias and default `runProcess` to accept an optional password and route password-bearing invocations through the shared `PtyProcessRunner`; remove the `ArchiveOperationsError.passwordUnsupported` case once unreferenced.

**Phase 6: Build**

- [ ] **T16** Build the app and the helper with `resources/scripts/build.sh` and resolve all `swiftlint lint --quiet` findings.

---

## Testing

Tests are implementation tasks. Numbering continues the `**T<n>**` sequence. Use real temp directories and real archives, no mocks, per project rules. 7z-dependent tests are skipped automatically when `/opt/homebrew/bin/7z` is absent (consistent with how the suite already gates on tool availability).

### Unit Tests (`Tests/`)

- [ ] **T17** `PtyProcessRunnerTests.testRunsToolWithoutPasswordCapturesOutput` — running a simple tty-aware command through the runner returns its exit status and captured output, with no password supplied.
- [ ] **T18** `PtyProcessRunnerTests.testFeedsPasswordToTwoPromptTool` — a stub script that disables echo and reads two lines (mimicking enter+verify) receives the password on both prompts and exits zero.
- [ ] **T19** `PtyProcessRunnerTests.testTimesOutAndTerminatesHungChild` — a child that prompts but is never satisfiable is terminated at the timeout and the runner returns a non-zero/failure result rather than hanging.
- [ ] **T20** `PtyProcessRunnerTests.testPasswordNotPresentInChildArguments` — the spawned child's argument vector contains no occurrence of the password string.
- [ ] **T21** `ArchiveOperationTests.testCreateAndExtractEncryptedZipRoundTrips` — replacing `testCreateZipWithPasswordIsDisabled`: create a ZIP with a password, then extract it with the correct password and assert the contents match the originals.
- [ ] **T22** `ArchiveOperationTests.testExtractEncryptedZipWrongPasswordReprompts` — replacing `testExtractPasswordZipIsDisabled`: extracting a password ZIP with the wrong password surfaces `archivePasswordRequired` (re-prompt) and leaves no partial extraction behind.
- [ ] **T23** `ArchiveOperationTests.testCreateAndExtractEncrypted7zRoundTrips` — create a 7Z with a password and extract it with the correct password; contents match (skipped when 7z is unavailable).
- [ ] **T24** `ArchiveOperationTests.testSupportsPasswordFlags` — replacing `testPasswordDisabledForZipAnd7z`/`testPasswordDisabledForTarFormats`: `supportsPassword` is true for `.zip` and `.sevenZ` and false for the three TAR formats.
- [ ] **T25** `ServerArchiveOperationsTests.testCreateAndExtractEncryptedZipRoundTrips` — replacing `testPasswordArchiveCreationIsRejectedBeforeProcessLaunch`: the helper creates a password ZIP and extracts it with the correct password through the real pty path; contents match.
- [ ] **T26** `ServerArchiveOperationsTests.testExtractEncryptedWrongPasswordFails` — the helper extracting an encrypted archive with the wrong password returns a failure and cleans up its temp directory.

### UI Tests (`Tests/UITests/DetoursUITests/`, run on Foundry)

- [ ] **T27** `ArchivePasswordUITests.testCheckboxEnabledForZipAndDisabledForTar` — in the Create Archive dialog, the "Encrypt with password" checkbox is enabled when ZIP (or 7Z) is selected and disabled when a TAR format is selected, and the password field appears when the box is ticked.
