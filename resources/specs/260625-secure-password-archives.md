# Process-Private Password-Protected Archives (ZIP and 7Z)

## Meta

- Status: Reviewed
- Branch: feature/secure-password-archives

---

## Business

### Goal

Bring back password protection for archives without exposing the password in the compression tool's command line. Detours can already create and open ZIP and 7Z archives, but password handling was switched off after an audit found that other programs on the same machine were able to read the password from the running tool's arguments.

### Proposal

Re-enable the "Encrypt with password" option for ZIP and 7Z, and let Detours open password-protected ZIP and 7Z archives while keeping the password out of every compression tool's command line.

### Behaviors

- **The "Encrypt with password" checkbox works for ZIP and 7Z.** Choosing ZIP or 7Z enables the checkbox; ticking it reveals a password field. TAR.GZ, TAR.BZ2, and TAR.XZ keep the checkbox disabled because those formats do not carry passwords.
- **Creating an encrypted archive.** With the checkbox ticked and a non-empty password entered, the finished archive requires that password to open. Archive naming, format selection, progress, and cancellation keep their current behavior.
- **Opening an encrypted archive.** Detours asks for a password after an extraction attempt identifies a protected archive. A wrong password displays an incorrect-password message and another prompt without leaving extracted files behind.
- **Remote parity on supported Unix machines.** Password-protected ZIP and 7Z creation and extraction behave the same through Detours' bundled macOS and Linux helper as they do on the Mac.
- **The password stays private from other programs.** Inspecting how the compression tool was started does not reveal the password, and Detours never includes it in progress or error text.
- **ZIP passwords have a clear compatibility limit.** ZIP creation and extraction accept passwords up to 80 UTF-8 bytes. A longer ZIP password keeps the archive dialog or password prompt open and displays "ZIP passwords are limited to 80 UTF-8 bytes" without starting an archive tool. Detours does not impose this limit on 7Z passwords.

### Acceptance Criteria

- [ ] **A1** Selecting ZIP or 7Z enables the "Encrypt with password" checkbox; selecting TAR.GZ, TAR.BZ2, or TAR.XZ disables it.
- [ ] **A2** Ticking the checkbox reveals a password field, and creating an archive with a non-empty password creates an archive that requires that password.
- [ ] **A3** Detours opens its password-protected ZIP and 7Z archives with the correct password, and the extracted contents match the originals.
- [ ] **A4** A wrong password displays an incorrect-password message and another prompt without leaving partial extracted files or folders.
- [ ] **A5** During encrypted creation, listing, or extraction, inspecting how the compression tool was started does not reveal the password, and Detours never includes it in progress or error text.
- [ ] **A6** Password-protected ZIP and 7Z creation and extraction work through the bundled helper on supported macOS and Linux remote machines.
- [ ] **A7** Unencrypted ZIP and 7Z operations and every TAR operation retain their current progress, cancellation, naming, conflict, and cleanup behavior.
- [ ] **A8** ZIP passwords of 80 UTF-8 bytes are accepted, longer ZIP passwords are rejected in the app and helper before an archive tool starts, and 7Z passwords are not subject to this Detours limit.

### Out of scope

- Password protection for TAR.GZ, TAR.BZ2, and TAR.XZ.
- Password-protected archives on Windows remote machines.
- Remembering, storing, or auto-filling archive passwords through Keychain or another credential store.
- Changing the archive formats, compression tools, or encryption algorithms. ZIP creation keeps its current broadly compatible encryption; this work secures password delivery rather than strengthening the ZIP cipher.

---

## Technical

### Approach

Audit commit `862884b` disabled archive passwords after finding `zip -P`, `unzip -P`, and `7z -pPASSWORD` in local and remote flows. Those forms place the secret in the child argument vector. The installed tools expose their argv-free password path through an interactive terminal: `zip -er` prompts for entry and confirmation, while `unzip` and `7z` read a password from a terminal when their password switch has no inline value.

Add a shared `DetoursProcess` library target at `Shared/`, with platform branches for Darwin and Glibc, and make the app, bundled helper, and PTY tests depend on it. The Linux linker settings include `libutil`. The Linux helper build script copies and hashes `Shared/` and `SharedTests/`, declares the shared target in its generated package, runs the shared tests in the Swift 6.2 Noble container, and then builds the helper.

`PtyProcessRunner` allocates a primary/replica pair with `openpty()` and records the replica path. It starts the child with `posix_spawn`, `POSIX_SPAWN_SETSID`, and ordered file actions that open the replica as file descriptor 0 after the new session exists, duplicate descriptor 0 onto descriptors 1 and 2, and close unused descriptors. Opening the replica from the new session leader gives the child a controlling terminal, so tools that read `/dev/tty` work on both macOS and Linux. The runner does not use `forkpty()` inside the multithreaded app.

The runner accepts an invocation policy describing each permitted response: ZIP creation sends the password for entry and confirmation; 7Z creation accepts its one-prompt and two-prompt variants; 7Z listing and extraction send the password once; and ZIP extraction sends the password once, then sends an empty line if `unzip` requests another password so the tool exits with its documented bad-password status. It forces the child locale to `C`, buffers prompt bytes across read boundaries, and recognizes a case-insensitive prompt line containing `password` and ending in a colon only while terminal echo is disabled. New matched prompt bytes plus echo state distinguish consecutive prompts. After a prompt is observed it waits 50 milliseconds, writes the policy's response plus newline, and overwrites the mutable UTF-8 password buffer after its last use. A missing prompt fails after 10 seconds, terminates the child session, and returns an archive-process error naming the tool. The runner never appends the password to arguments, environment values, logs, errors, or returned output. Archive execution after password delivery has no duration limit and remains cancellable. A Swift task cancellation handler sends `SIGTERM` to the child session, waits one second, sends `SIGKILL` if any child remains, and reaps the session leader.

PTY output is drained continuously to prevent the child from blocking. A streaming callback receives new output chunks for live 7Z progress parsing, while the result retains only the final 65,536 bytes for diagnostics plus the exit status. Prompt text is consumed by the state machine but may remain in the diagnostic tail; the password cannot because each write occurs only after echo is off.

Local creation remains in `src/Operations/FileOperationQueue+Archive.swift`. `performArchive`, `runZip`, and `runSevenZip` accept the existing optional password again. Password-bearing ZIP and 7Z commands use `PtyProcessRunner`; unencrypted commands keep their current `Process` paths. ZIP continues to report progress by polling the growing archive. Encrypted 7Z creation parses streamed `-bsp2` percentages from the PTY callback. Both paths preserve existing cancellation and partial-file removal.

Before spawning a ZIP tool, both the app and helper measure the password's UTF-8 representation and reject values longer than 80 bytes with `ZIP passwords are limited to 80 UTF-8 bytes`. The archive dialog disables its Archive action and shows that validation message; the extraction sheet validates before dismissing or launching work and remains open with the same message. The local operation layer and helper repeat the check as defense in depth. An 80-byte ZIP password is valid. The check applies to ZIP creation and extraction but not to 7Z.

Local extraction remains in `src/Operations/FileOperationQueue+Extraction.swift`. An initial attempt without a password keeps the current `ditto` ZIP path or 7Z path so encrypted input raises `archivePasswordRequired`. A retry with a password routes ZIP to a new `/usr/bin/unzip` PTY path and routes 7Z listing and extraction through the PTY runner. Password-bearing extraction always writes into a new `.detours-extract-*` directory and moves results into place only after the tool exits successfully and conflicts are resolved. ZIP exit code 82, or exit code 1 accompanied by a diagnostic that explicitly identifies a bad or incorrect password or skipped encrypted entries, maps to `archivePasswordRequired`; generic CRC, malformed-archive, and I/O diagnostics remain archive failures. 7Z encrypted-data failures map to `archivePasswordRequired`; every failure removes only app-created temporary output. `src/FileList/FileListViewController+FileActions.swift` restores the password sheet for `Location`, labels retries as an incorrect password, treats Cancel as a silent stop, and repeats the same local or remote extraction call.

Remote parity remains in `Server/ArchiveOperations.swift`. Password-bearing create and extract commands use prompt-mode arguments and the shared PTY runner. A distinct wrong-password server error travels through the existing error envelope and is mapped by `RemoteFileProvider` to `FileOperationError.archivePasswordRequired`, allowing the same password sheet to retry. The helper keeps its current starting/completed progress frames. The Windows provider continues to reject password-bearing archive requests.

Once no call site references the audit guard, remove `archivePasswordUnsupported`, `ArchiveOperationsError.passwordUnsupported`, the disabled-password alert, and the sentinel arguments. Restore `ArchiveFormat.supportsPassword` only for ZIP and 7Z. Update the user guide and remote-machine guide to describe the supported macOS/Linux behavior and the Windows boundary.

### Approach Validation

Research and code inspection support the revised approach:

- **A PTY pair alone is insufficient.** Apple's `openpty(3)` documentation distinguishes allocation from `login_tty()`, which creates a session and makes the replica the controlling terminal. The runner therefore opens the replica during spawn after `POSIX_SPAWN_SETSID`, rather than inheriting and duplicating a replica opened before session creation. Sources: [Apple `openpty(3)`](https://keith.github.io/xcode-man-pages/openpty.3.html), [Linux `posix_spawn(3)`](https://man7.org/linux/man-pages/man3/posix_spawn.3.html).
- **`forkpty()` is the wrong app-side fallback.** It establishes a controlling terminal, but fork-based PTY helpers carry a macOS warning when mixed with higher-level APIs. The spawn design avoids running Swift or Foundation work between `fork()` and `exec()`. Source: [Python PTY documentation](https://docs.python.org/3/library/pty.html).
- **Echo-aware password sending addresses the known terminal race.** Password programs often disable echo only after printing a prompt; sending too early can copy the password into captured output. Waiting for no-echo and applying pexpect's documented 50-millisecond pre-send delay addresses that race. Source: [pexpect documentation](https://pexpect.readthedocs.io/en/stable/api/pexpect.html).
- **Info-ZIP needs an explicit wrong-password exit path.** Interactive `unzip` asks again after a wrong password; an empty reply stops further prompts, and exit status 82 means no files were processed because the password was wrong. The ZIP extraction policy therefore sends the supplied password once and an empty reply to any retry prompt. Source: [Apple `unzip(1)`](https://keith.github.io/xcode-man-pages/unzip.1.html).
- **Info-ZIP bounds interactive passwords at 80 bytes.** Apple's ZIP source defines `IZ_PWLEN` as 80 and allocates an 81-byte password buffer including its terminator. Detours applies the same byte limit before process launch so longer input returns deterministic validation instead of another terminal prompt. Source: [Apple ZIP `crypt.h`](https://github.com/apple-oss-distributions/zip/blob/main/zip/zip30/crypt.h#L118).
- **Linux support needs explicit packaging and API handling.** `POSIX_SPAWN_SETSID` is a glibc extension available since 2.26, and spawn file actions run after the session attribute. Detours builds its x86_64 Linux helper in a Swift 6.2 Ubuntu Noble image, so the shared runner must compile and execute there rather than relying on Darwin-only imports. Source: [Linux `posix_spawn(3)`](https://man7.org/linux/man-pages/man3/posix_spawn.3.html).
- **The security boundary is command-line secrecy, not a new ZIP cipher.** Apple's bundled `zip(1)` documentation describes command-line passwords as insecure and its ZIP encryption as relatively weak; keeping `/usr/bin/zip` preserves the existing compatibility choice while the PTY closes the process-argument leak. Source: [Apple `zip(1)`](https://keith.github.io/xcode-man-pages/zip.1.html).

### Risks

| Risk | Mitigation |
| ---- | ---------- |
| The child has PTY file descriptors but no controlling terminal | Open the replica from the spawned session leader and test both `isatty(0)` and opening `/dev/tty` on macOS and Linux |
| A password is written before echo turns off | Wait for the no-echo state, then wait 50 milliseconds before writing |
| ZIP and 7Z variants request different numbers of responses | Combine a per-invocation response bound with no-echo state and prompt-byte detection under `LC_ALL=C` |
| PTY output blocks the child or consumes unbounded memory | Drain continuously, stream progress chunks, and retain only the final 65,536 bytes |
| Cancellation leaves a child or terminal session running | Send `SIGTERM` to the session, wait one second, escalate with `SIGKILL`, and reap the session leader |
| A wrong 7Z password resembles archive corruption | Map only encrypted-data diagnostics to the retry path; other exit-code-2 failures remain archive failures |
| A mixed ZIP returns a warning status after skipping encrypted entries | Treat exit 1 as a password retry only when its diagnostic explicitly identifies a password or skipped encrypted content; keep other warnings as archive failures |
| A failed operation leaves user-visible partial output | Reuse the current partial-archive and app-created-directory cleanup boundaries on every non-zero exit |
| The shared runner compiles on macOS but fails in the Linux helper | Compile and execute the shared PTY tests in the helper's Swift 6.2 Noble build flow |
| Password bytes remain in caller-owned Swift strings | Zero the runner-owned mutable UTF-8 buffer; do not claim protection from privileged memory inspection or caller-owned copies |
| A ZIP password exceeds the tool's interactive input buffer | Validate the UTF-8 byte count in the UI, local operation layer, and helper before spawning; accept 80 bytes and reject 81 or more with one exact message |

### Implementation Plan

**Phase 1: Shared PTY runner**

- [x] **C1** Add `DetoursProcess` and `DetoursProcessTests` targets at `Shared/` and `SharedTests/`, connect their app/helper/test dependencies in `Package.swift`, and add Linux `libutil` linking.
- [x] **C2** Update `resources/scripts/server-cache-hash.sh` and `resources/scripts/build-server-linux.sh` to include, test, and compile the shared PTY sources plus the password-bearing helper archive tests in the Swift 6.2 Noble helper build.
- [x] **C3** Implement `Shared/PtyProcessRunner.swift` with a 50-millisecond pre-send delay, 10-second prompt timeout, one-second cancellation grace, 65,536-byte diagnostic tail, prompt buffering across read boundaries, scripted password-or-empty responses, controlling-terminal spawn, streaming output, Swift task cancellation handling, exit mapping, reaping, and password-buffer clearing.

**Phase 2: Local creation**

- [x] **C4** Restore `ArchiveFormat.supportsPassword` for `.zip` and `.sevenZ` in `src/Utilities/CompressionTools.swift`, allow non-empty passwords through `performArchive`, and add the ZIP-only 80-UTF-8-byte validation to `ArchiveModel` plus the local creation preflight.
- [x] **C5** Route encrypted ZIP creation in `src/Operations/FileOperationQueue+Archive.swift` through `/usr/bin/zip -er -q` on the PTY while retaining file-size progress, cancellation, cleanup, working-directory, and unencrypted behavior.
- [x] **C6** Route encrypted 7Z creation through `7z a -t7z -bsp2 -mhe=on -p` on the PTY and feed streamed percentages into the current progress calculation while leaving the unencrypted path unchanged.

**Phase 3: Local extraction and prompting**

- [x] **C7** Route password-bearing ZIP retries in `src/Operations/FileOperationQueue+Extraction.swift` through `/usr/bin/unzip -o -q` on the PTY, enforce the 80-UTF-8-byte preflight, map exit 82 and password-specific exit-1 diagnostics to `archivePasswordRequired`, keep other failures distinct, and preserve app-created-directory cleanup.
- [x] **C8** Route password-bearing 7Z listing and extraction through `7z l -slt -p` and `7z x -y -bsp2 -p`, stream extraction progress, materialize results from an app-created temporary directory only after success, and distinguish wrong passwords from corruption.
- [x] **C9** Restore the `Location`-based archive password sheet and incorrect-password retry loop in `src/FileList/FileListViewController+FileActions.swift` for local and remote extraction, and keep the sheet open with the exact ZIP byte-limit message when validation fails.

**Phase 4: Remote helper and cleanup**

- [x] **C10** Replace the ZIP and 7Z password sentinels in `Server/ArchiveOperations.swift` with prompt-mode commands, enforce the ZIP-only 80-UTF-8-byte preflight for create and extract requests, and route password-bearing helper invocations through `PtyProcessRunner`.
- [x] **C11** Add a distinct helper wrong-password error and map its existing RPC error-envelope text in `RemoteFileProvider` to `FileOperationError.archivePasswordRequired`.
- [x] **C12** Remove the local and helper unsupported-password errors, guards, alerts, and dead branches after all password paths use the PTY runner.
- [ ] **C13** Update `resources/docs/USER_GUIDE.md` and `resources/docs/remote-vm-browsing.md` for local and macOS/Linux-helper password support, the Windows boundary, and command-line secrecy.
- [ ] **C14** Build through `resources/scripts/build.sh` and resolve every Swift compiler and `swiftlint lint --quiet` finding.

---

## Testing

Tests use temporary directories and real archive tools. The shared runner suite executes on macOS and in the Linux helper container. Tests requiring 7Z skip when the tool is absent.

### Shared Runner Tests (`SharedTests/`)

- [ ] **T1** `PtyProcessRunnerTests.testRunsWithoutPasswordAndCapturesOutput` confirms an unprompted child returns its exit status and output.
- [ ] **T2** `PtyProcessRunnerTests.testChildHasControllingTerminal` confirms the child sees `isatty(0)` and can open `/dev/tty` on macOS and Linux.
- [ ] **T3** `PtyProcessRunnerTests.testFeedsOnePromptWithoutEchoingPassword` splits a mixed-case password prompt across output chunks and confirms the no-echo prompt receives the password while neither streamed nor retained output contains it.
- [ ] **T4** `PtyProcessRunnerTests.testFeedsTwoPromptsWithoutEchoingPassword` confirms split entry and confirmation prompts each receive the password once and unrelated colon-terminated output does not consume a response.
- [ ] **T5** `PtyProcessRunnerTests.testEmptyRetryResponseEndsRepeatedPrompt` confirms a password response followed by an empty response ends an `unzip`-style retry without resending the secret.
- [ ] **T6** `PtyProcessRunnerTests.testPromptTimeoutTerminatesAndReapsChild` confirms an unanswered prompt fails after 10 seconds without leaving the child running.
- [ ] **T7** `PtyProcessRunnerTests.testCancellationTerminatesChildSession` confirms cancellation reaps the child and its session descendants.
- [ ] **T8** `PtyProcessRunnerTests.testStreamsOutputAndBoundsDiagnosticTail` confirms chunk callbacks arrive before exit and retained output never exceeds 65,536 bytes.
- [ ] **T9** `PtyProcessRunnerTests.testPasswordAbsentFromArgumentsEnvironmentAndOutput` confirms a password containing spaces, shell metacharacters, and non-ASCII characters appears only in the child's no-echo terminal input.

### Archive Tests (`Tests/`)

- [ ] **T10** `ArchiveOperationTests.testCreateAndExtractEncryptedZipRoundTrips` creates and extracts a password ZIP, compares contents, and replaces the disabled-password creation test.
- [ ] **T11** `ArchiveOperationTests.testEncryptedZipWrongPasswordRetriesWithoutPartialOutput` confirms the repeated prompt receives an empty response, exit 82 and a mixed encrypted/unencrypted ZIP's password-specific exit-1 diagnostic map to `archivePasswordRequired`, generic exit-1 failures do not, and cleanup removes app-created output.
- [ ] **T12** `ArchiveOperationTests.testCreateListAndExtractEncrypted7zRoundTrips` covers encrypted 7Z creation, password-bearing listing, temporary extraction, materialization, progress callbacks, and matching contents.
- [ ] **T13** `ArchiveOperationTests.testEncrypted7zWrongPasswordDiffersFromCorruption` confirms only encrypted-data diagnostics request another password and both failures clean app-created output.
- [ ] **T14** `ArchiveOperationTests.testSupportsPasswordFlags` confirms ZIP and 7Z support passwords while all TAR formats do not.
- [ ] **T15** `ServerArchiveOperationsTests.testEncryptedZipRoundTripsThroughPtyRunner` confirms on macOS and in the generated Linux test target that the helper creates and extracts an encrypted ZIP through the real PTY runner.
- [ ] **T16** `ServerArchiveOperationsTests.testWrongPasswordMapsToRetryAndCleansTemporaryOutput` confirms the helper error survives the RPC mapping as `archivePasswordRequired` without partial output.
- [ ] **T17** Existing unencrypted ZIP, 7Z, TAR, local, and helper archive tests continue to pass unchanged.

### UI Tests (`Tests/UITests/DetoursUITests/DetoursUITests/`)

- [ ] **T18** `ArchivePasswordUITests.testCreationControlsFollowSelectedFormat` confirms ZIP and 7Z enable the checkbox, TAR formats disable it, ticking the box reveals the secure field, and an 81-byte ZIP password shows the exact limit message and disables Archive.
- [ ] **T19** `ArchivePasswordUITests.testWrongPasswordShowsRetrySheet` confirms an encrypted archive prompts after first extraction, labels a wrong retry, keeps the prompt open without launching work for an 81-byte ZIP password, and succeeds after the correct password without partial output.
- [ ] **T20** `ArchivePasswordValidationTests.testZipPasswordByteLimit` confirms the app and local operation preflights accept exactly 80 UTF-8 bytes, reject 81 bytes including a multibyte boundary case with the exact message, and do not apply the limit to 7Z.
- [ ] **T21** `ServerArchiveOperationsTests.testZipPasswordByteLimit` confirms helper ZIP create and extract requests reject 81 UTF-8 bytes before process launch, accept exactly 80 bytes, and leave 7Z unrestricted by this Detours limit.

## Build Log

- **C1** Added the shared library and test targets, wired the app, helper, and tests to the library, and limited `libutil` linking to Linux. `swift package describe` resolves both new targets and their dependency graph.
- **C2** Extended the helper cache over shared sources and focused helper tests. The generated Noble package installs the real ZIP, unzip, and 7Z tools, runs both shared-runner and server-archive suites before its static release build, restores mounted-workspace ownership, and cleans its remote workspace on every exit.
- **C3** Added the Darwin/Glibc PTY runner with controlling-terminal spawn, echo-aware scripted replies, bounded streaming diagnostics, prompt timeout, task cancellation, process-session termination, exit decoding, reaping, and mutable secret-buffer clearing. Dedicated behavior coverage follows in T1-T9.
- **C4** Restored password capability for ZIP and 7Z and added one ZIP-only validator shared by the dialog model and local operation preflight. Exactly 80 UTF-8 bytes remain valid; longer input yields the specified message before archive launch.
- **C5** Routed encrypted ZIP creation through `zip -er -q` with two echo-disabled PTY replies. The branch retains working-directory item names, file-size polling, queue cancellation, and partial-archive cleanup while leaving unencrypted ZIP creation unchanged.
- **C6** Routed encrypted 7Z creation through prompt-mode `7z` with header encryption, bounded one-or-two prompt handling, streamed percentage parsing, queue cancellation, and partial-file cleanup. Unencrypted 7Z creation still uses its original process path.
- **C7** Routed password-bearing ZIP extraction through prompt-mode `unzip`, with an empty response to repeated prompts, defense-in-depth byte validation, bounded progress, cancellation, and temporary-directory cleanup. Exit 82 and password-specific exit-1 text retry; generic failures remain archive errors.
- **C8** Added a dedicated encrypted-7Z flow that performs prompt-mode listing and streamed extraction into an app-created temporary directory, then resolves conflicts and materializes only after success. Explicit encrypted-data password diagnostics retry; other corruption remains an archive failure.
- **C9** Restored a `Location`-based password sheet for local and remote archives. Incorrect retries are labelled, Cancel is silent, empty input stays in the sheet, and overlong ZIP input shows the exact byte-limit message without launching extraction.
- **C10** Replaced helper password sentinels with prompt-mode ZIP and 7Z PTY invocations for creation and extraction. The helper validates ZIP byte length before tool resolution, retains its progress envelope and temporary extraction boundary, and exposes a focused PTY test seam.
- **C11** Added the helper's distinct `wrongPassword` failure for ZIP and encrypted 7Z diagnostics. `RemoteFileProvider` maps that stable RPC envelope text to `archivePasswordRequired`, feeding remote failures into the shared retry sheet.
- **C12** Removed the audit-era local/helper unsupported-password errors, presentations, sentinels, and obsolete rejection tests. Unsupported TAR input now uses validation, while Windows keeps its explicit boundary through the provider's standard unsupported-operation error.
