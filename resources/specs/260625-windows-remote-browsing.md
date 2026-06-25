# Windows Remote-Host Browsing (PowerShell over SSH)

## Meta

- Status: Implemented
- Branch: feature/windows-remote-browsing

---

## Business

### Goal

Let Detours browse and work with files on a Windows server the same way it already does with Mac and Linux servers. Today, connecting to a Windows machine over SSH fails immediately with an unhelpful error, because Detours assumes every server behaves like a Unix machine. After this change, a Windows server connects successfully, opens to the user's home folder, and supports the same file operations Detours offers everywhere else.

### Proposal

Add first-class support for Windows servers: when a connected server turns out to be Windows, Detours talks to it in its native language (PowerShell) instead of trying to run Unix commands, and every file operation, listing, navigation, copy, move, rename, trash, archive, search, live updates, and previews, works against that Windows server.

### Behaviors

- **Connecting to a Windows server succeeds.** Adding and connecting to a Windows host (an OpenSSH server whose default shell is PowerShell) succeeds. Detours recognizes it is Windows automatically; the user does not declare the operating system.
- **You land in your home folder.** A freshly connected Windows host opens in the signed-in user's profile folder (for example `C:\Users\sans`).
- **All drives are reachable.** Navigating up out of a drive (for example up from `C:\`) shows a top-level view of the machine listing every drive (C:, D:, mapped network drives) as entries you can open.
- **The existing remote file actions work on Windows.** Listing, opening folders, file sizes and dates, copy, move, rename, new folder, delete to a Detours-managed host trash location (with undo), create and extract archives, Quick Look previews, drag in/out transfers, Quick Open search, and live refresh when the folder changes all function against the Windows host.
- **Deleting is safe.** Deleting a file on a Windows host moves it to a Detours-managed trash folder in the signed-in user's profile, never a permanent erase. Undo restores it to the original path, and Detours reports a clear failure if the trash item is unavailable.
- **Names with accents and symbols are correct.** Files and folders with non-English characters, spaces, or punctuation display and operate correctly.
- **Connection loss behaves like any other server.** If a Windows host disconnects, the same "Connection lost" banner and reconnect behavior used for other servers applies, and it can be dismissed.

### Acceptance Criteria

- [x] **A1** Connecting to a Windows OpenSSH host (default shell PowerShell) succeeds and opens in the signed-in user's profile folder, with no operating-system choice required from the user.
- [x] **A2** Navigating up past a drive root shows a top-level machine view listing all drives, and opening a drive enters it.
- [x] **A3** Listing a Windows folder shows correct names, sizes, modification dates, and folder/file distinction, including entries whose names contain spaces, quotes, semicolons, and non-English characters.
- [x] **A4** Creating a folder, renaming, copying, and moving items on a Windows host all succeed and the result is reflected in the listing.
- [x] **A5** Deleting an item on a Windows host moves it to Detours-managed host trash rather than permanently deleting it; undo restores it when the trash item is available and reports a clear failure when it cannot.
- [x] **A6** Creating a ZIP archive and extracting a ZIP archive on a Windows host both succeed, including selected hidden files and folders; 7z and tar formats are offered only when those tools exist on the host and are hidden otherwise.
- [x] **A7** Downloading a file from, and uploading a file to, a Windows host both succeed for large and binary files with intact contents.
- [x] **A8** Quick Look preview of a Windows file works, and Quick Open search returns matching names from the active directory, streaming results as they are found.
- [x] **A9** A folder open on a Windows host refreshes automatically when its contents change on the server.
- [x] **A10** When a Windows host connection drops, the dismissable "Connection lost" banner and reconnect path behave exactly as they do for Mac/Linux hosts.
- [x] **A11** Connecting to a Mac or Linux host is unchanged in every respect.
- [x] **A12** If a Windows host does not expose SFTP, small transfers still work and large transfers report a clear limitation instead of hanging, truncating the file, or pretending the transfer succeeded.

### Out of scope

- Running the native Detours helper binary on Windows (Windows uses the PowerShell backend instead; no helper is deployed there).
- Windows hosts whose SSH server is configured with a Unix-style shell (bash/WSL) as the default; this spec targets OpenSSH hosts configured with PowerShell as `DefaultShell`.
- Password-protected ZIP creation on Windows where only the built-in ZIP tool is present (the built-in tool cannot encrypt; encrypted archives require a 7z tool on the host, consistent with the separate secure-password-archives work).
- Per-host manual operating-system override UI (detection is automatic).

---

## Technical

### Approach

Detours already abstracts file access behind the `FileProvider` protocol (`src/Services/FileProvider/FileProvider.swift`), with `LocalFileProvider` for the Mac and `RemoteFileProvider` (an actor, `src/Services/FileProvider/RemoteFileProvider.swift`) for Unix hosts. `RemoteFileProvider` speaks a binary RPC (`RPCMessage`) to the deployed `detours-server` helper over an `SSHConnection` actor (`src/Remote/SSHConnection.swift`) that manages a multiplexed OpenSSH ControlMaster. This work adds a third provider, `WindowsRemoteProvider` (an actor implementing the same `FileProvider` protocol), plus connect-time routing that selects it before helper deployment.

The Windows backend never deploys a binary. Instead it starts `powershell.exe -NoProfile -NonInteractive -EncodedCommand <dispatcher>` through a new `PowerShellChannel` that uses the same SSH host-trust and ControlMaster options as `SSHConnection`, but owns its own stdin/stdout pipes because no `detours-server` helper is running. Live validation on `win-carriercall` showed Windows OpenSSH does not reliably deliver a second stdin frame to a long-lived PowerShell exec process, so regular file operations use one dispatcher invocation per request over the reused SSH ControlMaster. Each request carries an operation name, a UTF-16LE base64 script payload, and JSON-encoded argument data. The dispatcher decodes the script, binds the argument object as data, executes it, and writes exactly one length-framed UTF-8 JSON response envelope. Because every user-controlled value travels as JSON data rather than as text appended to a shell command, file names containing spaces, quotes, semicolons, backticks, or `$` cannot break framing or inject commands. Windows paths map into the existing `Location.remote(hostID:path:)` model with no change to `Location`: paths are stored forward-slash with a drive letter (`C:\Users\sans` becomes `/C:/Users/sans`) so the existing `/`-based join/split logic keeps working, and the provider translates to native backslash only at the PowerShell boundary. Navigating up past a drive root (`/C:/`) yields a synthetic host root (`/`) whose listing is the machine's drives, produced from `Get-PSDrive -PSProvider FileSystem` plus `Get-Volume` details when available.

Connect-time routing (`src/Windows/MainSplitViewController.swift` connect flow near the current `deployIfNeeded()` call, plus `RemoteConnectionRegistry` and `src/Remote/ServerDeployer.swift`) gains a `RemoteHostKindProbe`. The probe first runs an explicit `powershell.exe -NoProfile -NonInteractive -EncodedCommand <UTF-16LE marker script>` command and classifies the host as Windows only when stdout contains the expected Detours marker plus a Windows platform value; if that fails, it runs today's `uname -sm` Unix architecture path. On Windows it constructs `WindowsRemoteProvider`, registers its channel for reconnect/state tracking, and skips `deployIfNeeded()` entirely; on Unix it runs today's helper deployment path unchanged. The detected OS is cached on `RemoteHost` (`src/Remote/RemoteHost.swift`) so reconnects and session restore route to the right backend without repeating the probe unless the field is absent.

Transfers use the OpenSSH SFTP subsystem over the host's ControlMaster against normalized Windows SFTP paths (`/C:/Users/...`), with byte-count verification and the same `.detours-partial` local-file cleanup used by `RemoteTransferChannel`. If SFTP is unavailable, the provider uses base64-over-`PowerShellChannel` only up to `RemoteTransferChannel.rpcThresholdBytes` (1,048,576 bytes); larger transfers fail with a clear unsupported-large-transfer error. Directory watching uses exactly one additional long-lived PowerShell channel per host that registers a .NET `FileSystemWatcher` from the first request, then waits for filesystem events instead of depending on later stdin frames; `unwatch` drops callbacks locally and the channel closes when no watches remain. Trash uses a Detours-managed `.detours-trash` folder under the signed-in user's Windows profile and returns restore tokens pointing to moved trash items, because the Windows Shell Recycle Bin metadata was not available from the noninteractive SSH session.

Archive creation and extraction use a PowerShell/.NET ZIP implementation, not `Compress-Archive`, because `Compress-Archive` ignores hidden files and has documented size limitations. The ZIP script enumerates selected files with `-Force`, writes them through `System.IO.Compression.ZipArchive`, preserves relative paths, extracts through the same API, and returns a clear error for any entry too large for the built-in API. When a host `7z.exe` is present, 7z handles encrypted ZIP/7z and large archives; tar formats are shown only when `tar.exe` exists on the host PATH. Quick Open `find` recurses from the active directory, streams `FoundItem` matches up to 1,000 results or 20 seconds, and prunes `C:\Windows`, `C:\Program Files`, `C:\Program Files (x86)`, `C:\ProgramData`, and user `AppData` unless the active directory is inside one of those trees. The reconnect banner and Quick Open scope header already present for remote tabs apply to Windows hosts unchanged.

### Approach Validation

- **PowerShell over SSH is a documented Windows automation path.** Microsoft documents OpenSSH Server for Windows and the `DefaultShell` registry setting, and documents `-EncodedCommand` as UTF-16LE base64 for startup-time scripts. The spec uses that property for the one-shot OS probe and the per-operation dispatcher, but does not pretend `-EncodedCommand` can be sent to an already-running shell. Sources: https://learn.microsoft.com/en-us/windows-server/administration/openssh/openssh-server-configuration and https://learn.microsoft.com/en-us/powershell/module/microsoft.powershell.core/about/about_powershell_exe
- **Encoding is the classic failure mode and is designed out.** PowerShell's console output encoding varies by Windows version and codepage; every dispatcher reply forces `[Console]::OutputEncoding`/`$OutputEncoding` to UTF-8 and emits `ConvertTo-Json -Compress -Depth 8`, then Swift decodes UTF-8 JSON. Sources: https://learn.microsoft.com/en-us/powershell/module/microsoft.powershell.utility/convertto-json and https://learn.microsoft.com/en-us/powershell/module/microsoft.powershell.core/about/about_character_encoding
- **`Compress-Archive` is unsuitable for a file-manager archive operation.** Microsoft documents that it ignores hidden files and relies on an API with a 2 GB per-entry limit. The spec therefore uses explicit `.NET ZipArchive` scripts for built-in ZIP, includes hidden selections, and returns a clear large-entry error unless `7z.exe` is available. Source: https://learn.microsoft.com/en-us/powershell/module/microsoft.powershell.archive/compress-archive
- **Recycle Bin metadata is not reliable from noninteractive SSH sessions**, which is why live implementation uses Detours-managed host trash instead of Shell Recycle Bin restore tokens. The hard guarantee is still preserved: delete is a move to a restorable host-side trash path, never permanent erase.
- **The command dispatcher must fit Windows OpenSSH stdin behavior.** Live validation showed one framed request per PowerShell exec is reliable, while a second stdin frame to the same exec process is not. SSH ControlMaster reuse keeps the per-operation process cost acceptable, and `.NET FileSystemWatcher` still has a dedicated long-lived process for event streaming. Source: https://learn.microsoft.com/en-us/dotnet/api/system.io.filesystemwatcher
- **Drive model:** Windows has no single filesystem root, so a synthetic host-root listing drives from `Get-PSDrive -PSProvider FileSystem` with `Get-Volume` enrichment gives Detours a navigable equivalent to a Unix root. Landing in the user profile matches Windows file-manager expectations.

### Risks

| Risk | Mitigation |
| ---- | ---------- |
| PowerShell cold-start latency makes browsing feel slow | Each command uses a fresh dispatcher invocation because Windows OpenSSH does not deliver reliable second stdin frames, but the SSH ControlMaster is reused and live operations complete within acceptable latency |
| Non-ASCII / codepage corruption of names | All replies are `ConvertTo-Json` with `[Console]::OutputEncoding`/`$OutputEncoding` forced to UTF-8, decoded as UTF-8; never parse formatted text |
| Command injection / framing breakage from names with quotes, `;`, backtick, `$` | Requests carry JSON argument data and a UTF-16LE base64 script payload inside a Detours frame; nothing is concatenated onto a shell-parsed line |
| Dispatcher protocol deadlocks or emits malformed frames | `PowerShellChannel` owns stdin/stdout, enforces per-request timeouts, validates one response frame per request id, and tears down/restarts the session on framing errors |
| Windows path semantics leaking into shared `/`-based path logic | Paths stored normalized as `/C:/...`; backslash translation confined to the provider's PowerShell boundary; `Location` and shared join/split untouched |
| Shell Recycle Bin metadata unavailable from SSH sessions | Delete moves items to a Detours-managed `.detours-trash` folder under the Windows profile and restore moves them back from a tokenized trash path |
| A blocking `FileSystemWatcher` ties up the command channel | Watching runs on a separate dedicated PowerShell channel per host; the command RPC path is never blocked |
| Built-in ZIP support omits hidden files or fails for large entries | Do not use `Compress-Archive`; enumerate selected files with `-Force` and use `.NET ZipArchive`, with a clear large-entry error unless `7z.exe` is available |
| SFTP subsystem disabled on some Windows hosts | Detect at connect; fall back to base64-over-session transfer up to 1,048,576 bytes and surface a clear unsupported-large-transfer error above that threshold |
| Wrong backend chosen after reconnect/session restore | Detected OS cached on `RemoteHost`; routing reads the cached kind and re-probes only when absent |
| Long-running `find`/`folderSize` on huge drives | `find` is bounded to 1,000 results or 20 seconds and is current-drive-only; streamed so partial results appear immediately |
| Existing Unix remote behavior regressed by the routing change | OS routing is additive: absent/Unix detection runs the unchanged `uname` + helper path; covered by routing tests and the unchanged Unix provider tests |

### Implementation Plan

**Phase 1: OS detection and provider routing**

- [x] **T1** Add a `RemoteHostKind` (`unix`, `windows`) and persist it as an optional cached field on `RemoteHost` in `src/Remote/RemoteHost.swift` (Codable, defaulting to absent for existing saved hosts).
- [x] **T2** Add `RemoteHostKindProbe` in `src/Remote/`: first run `powershell.exe -NoProfile -NonInteractive -EncodedCommand <UTF-16LE marker script>` over SSH and classify Windows only when stdout contains the Detours marker plus a Windows platform value; when that command fails or the marker is absent, run the existing `uname -sm` Unix architecture probe.
- [x] **T3** In the connect path in `src/Windows/MainSplitViewController.swift` (current `deployIfNeeded()` call site), branch on the probe: for Windows construct `WindowsRemoteProvider` and skip `deployIfNeeded()` entirely; for Unix keep today's deploy + `RemoteFileProvider`. Generalize `RemoteConnectionRegistry` from storing only `SSHConnection` to storing a `RemoteConnectionHandle` that supports pane-count updates, reconnect, disconnect state publication, and optional RPC reconnect preparation; register the Windows channel through that handle. Cache the detected `RemoteHostKind` on the `RemoteHost` and route reconnects/session restore by the cached kind, re-probing only when absent.

**Phase 2: PowerShell command channel and script construction**

- [x] **T4** Create `src/Remote/Windows/PowerShellChannel.swift`: an actor conforming to the new `RemoteConnectionHandle` that uses `powershell.exe -NoProfile -NonInteractive -EncodedCommand <dispatcher>` with the host-trust and ControlMaster arguments shared with `SSHConnection`, sends one Detours length-framed request envelope per dispatcher invocation, reads one length-framed UTF-8 JSON response envelope, correlates request ids, enforces per-request timeouts, and tears down failed processes on framing or process failure.
- [x] **T5** Create `src/Remote/Windows/PowerShellScript.swift`: builders that assemble each operation's PowerShell script with arguments bound as JSON data (never string-concatenated), force `[Console]::OutputEncoding`/`$OutputEncoding` to UTF-8, emit `ConvertTo-Json -Compress -Depth 8`, and produce the UTF-16LE base64 script payload consumed by the dispatcher.
- [x] **T6** Create `src/Remote/Windows/WindowsPath.swift`: bidirectional normalization between `Location.remote` forward-slash form (`/C:/Users/sans`, synthetic root `/`) and native Windows paths (`C:\Users\sans`), plus drive-root detection and the synthetic-host-root concept.
- [x] **T7** Define the Codable reply models (`src/Remote/Windows/WindowsReplies.swift`) for directory entries, stat, drive list, hashes, archive/tool availability, transfer results, and error envelopes, decoded from the JSON replies.

**Phase 3: WindowsRemoteProvider read operations and drive model**

- [x] **T8** Create `src/Services/FileProvider/WindowsRemoteProvider.swift` as an actor conforming to `FileProvider`, holding the host id and `PowerShellChannel`; `WindowsTransferChannel` is added in T11, and every implemented `Location` path routes through `WindowsPath`.
- [x] **T9** Implement `list` (via `Get-ChildItem -Force`, mapping to `LoadedFileEntry` with size, dates, directory flag, hidden/system attributes, reparse-point flag) and the synthetic host-root listing of drives (via `Get-PSDrive -PSProvider FileSystem`/`Get-Volume`); landing location on connect is the user profile.
- [x] **T10** Implement `stat`, `folderSize` (recursive measure), `readSymlink` (resolve reparse points/junctions best-effort), and `version` (SHA-256 via `Get-FileHash` plus modification date) in `WindowsRemoteProvider`.

**Phase 4: Transfers, Quick Look**

- [x] **T11** Create `src/Remote/Windows/WindowsTransferChannel.swift` using the OpenSSH SFTP subsystem over the host ControlMaster against normalized `/C:/...` paths, with byte-count verification, `.detours-partial` local cleanup, and a base64-over-`PowerShellChannel` fallback up to `RemoteTransferChannel.rpcThresholdBytes` (1,048,576 bytes) when SFTP is unavailable.
- [x] **T12** Implement `download` and `upload` in `WindowsRemoteProvider` via the transfer channel; implement `openForQuickLook` by downloading to a temp file and previewing through the existing remote Quick Look path; return a clear unsupported-large-transfer error when SFTP is unavailable and the file exceeds 1,048,576 bytes.

**Phase 5: Write operations**

- [x] **T13** Implement `createDirectory`, `rename`, `copy`, and `move` in `WindowsRemoteProvider` via PowerShell (`New-Item`, `Rename-Item`, `Copy-Item`, `Move-Item`), returning the resulting `Location`s and honoring within-host vs cross-host semantics consistent with `RemoteFileProvider`.
- [x] **T14** Implement `delete` in `WindowsRemoteProvider` as a move to Detours-managed host trash (never a permanent delete), matching the protocol's `delete` contract used by callers.

**Phase 6: Trash and restore**

- [x] **T15** Implement `trash` returning `TrashedItem`s by moving items to the Detours-managed `.detours-trash` folder under the Windows profile, recording original and trash locations.
- [x] **T16** Implement `restoreFromTrash` by moving the tokenized Detours trash item back to its original path; on failure, surface a clear error rather than silently losing data.

**Phase 7: Archive**

- [x] **T17** Implement `archiveCreate`/`archiveExtract` for ZIP via `System.IO.Compression.ZipArchive` PowerShell scripts that enumerate selected files with `-Force`, preserve relative paths, include hidden files and folders, and return a clear large-entry error for entries the built-in API cannot write; add a host tool-availability probe that enables 7z and tar.* only when `7z.exe`/`tar.exe` are on the host PATH (mirroring `CompressionTools.isFormatAvailable` gating), and route 7z/tar through those tools when present. Encrypted ZIP requires a host 7z tool (built-in ZIP cannot encrypt).

**Phase 8: Directory watching**

- [x] **T18** Create `src/Remote/Windows/WindowsWatchChannel.swift`: one additional long-lived PowerShell channel per host that registers a .NET `FileSystemWatcher` from the first watch request and streams change events tagged by directory id as framed JSON, independent of the command channel.
- [x] **T19** Implement `watch`/`unwatch` in `WindowsRemoteProvider` against the watch channel: `watch` registers a directory and invokes `onChange` per coalesced event, `unwatch` drops callbacks locally, and the watch channel closes when no watches remain.

**Phase 9: Search and git status**

- [x] **T20** Implement `find(query:cap:)` in `WindowsRemoteProvider`: recurse from the active directory via `Get-ChildItem -Recurse -Force`, case-insensitive name match, prune `C:\Windows`, `C:\Program Files`, `C:\Program Files (x86)`, `C:\ProgramData`, and user `AppData` unless the active directory is inside one of those trees, stream `FoundItem` batches, and stop at 1,000 results or 20 seconds.
- [x] **T21** Implement `gitStatus` returning results only when `git` is on the host PATH (porcelain parse), otherwise an empty result.

**Phase 10: Coexistence and build**

- [x] **T22** Ensure the sidebar (`src/Sidebar/`), Quick Open scope header, and the dismissable reconnect banner treat Windows hosts identically to other remote hosts (no helper-cache assumptions for Windows hosts); guard any code that assumes a deployed helper exists so it is skipped for `RemoteHostKind.windows`.
- [x] **T23** Build the app and helper with `resources/scripts/build.sh` and resolve all `swiftlint lint --quiet` findings.

---

## Testing

Tests are implementation tasks. Numbering continues the `**T<n>**` sequence. Unit tests use real temp data and deterministic fixtures, no mocks, per project rules. Integration tests that require a live Windows host run against inventory host `win-carriercall` (user `sans`) and are marked so they skip cleanly when the host is unreachable.

### Unit Tests (`Tests/`)

- [x] **T24** `WindowsPathTests.testRoundTripsDriveAndProfilePaths` — `/C:/Users/sans` maps to `C:\Users\sans` and back; the synthetic root `/` maps to the drive-list view; join/split via `Location` stays correct for Windows paths.
- [x] **T25** `WindowsPathTests.testDriveRootDetectionAndUpNavigation` — navigating up from `/C:/` yields the synthetic host root, and the host root lists drives, not a parent path.
- [x] **T26** `PowerShellScriptTests.testDispatcherPayloadIsUTF16LEBase64` — built script payloads decode back to the expected UTF-16LE PowerShell source and set UTF-8 output encoding.
- [x] **T27** `PowerShellScriptTests.testArgumentsAreDataNotConcatenated` — names containing spaces, single and double quotes, semicolons, backticks, and `$(...)` are carried as data and cannot alter the script's command structure (injection-safety).
- [x] **T28** `WindowsRepliesTests.testParsesGetChildItemJson` — a representative `Get-ChildItem | ConvertTo-Json` document (including non-ASCII names, sizes, dates, directory/hidden/reparse flags, and the single-item-not-array case) decodes into the expected entries.
- [x] **T29** `WindowsRepliesTests.testParsesDriveListAndErrorEnvelope` — drive-list JSON and a PowerShell error envelope decode into the expected models.
- [x] **T30** `PowerShellChannelTests.testFramesRequestsAndCorrelatesReplies` — against a scripted stand-in transport, framed requests and replies correlate in order and a reply with embedded newlines/Unicode is reassembled intact.
- [x] **T31** `PowerShellChannelTests.testMalformedFrameRestartsSessionAndFailsRequest` — a malformed dispatcher response fails the in-flight request, restarts the channel, and allows a later request to succeed.
- [x] **T32** `RemoteHostKindRoutingTests.testWindowsProbeSkipsDeployAndPicksWindowsProvider` — a Windows probe result routes to `WindowsRemoteProvider` and never calls `deployIfNeeded`; a Unix result routes to the existing deploy + `RemoteFileProvider` path; the kind is cached on `RemoteHost` and reused on reconnect.
- [x] **T33** `WindowsFindContractTests.testStreamsCappedTimeBoxedCurrentDriveMatches` — `find` yields streamed batches, stops at 1,000 results or 20 seconds, starts from the active directory, and prunes `Windows`, `Program Files`, `ProgramData`, and `AppData` noise unless the active directory is inside one of those trees (validated against a temp tree with the same traversal logic).
- [x] **T34** `WindowsArchiveScriptTests.testZipArchiveIncludesHiddenEntries` — the built-in ZIP script enumerates selected hidden files and folders with `-Force`, preserves relative paths, and does not call `Compress-Archive`.
- [x] **T35** `WindowsTransferChannelTests.testSFTPUnavailableFallbackThreshold` — when SFTP is unavailable, a transfer at 1,048,576 bytes uses the PowerShell fallback and a larger transfer returns the unsupported-large-transfer error.

### Integration Tests (`Tests/`, live Windows host — `win-carriercall`)

- [x] **T36** `WindowsRemoteLiveTests.testConnectListsProfileAndDrives` — connecting recognizes Windows, lands in the profile folder, lists it correctly, and the synthetic root lists drives (A1, A2, A3); skips unless `DETOURS_WINDOWS_TEST_TARGET` is set.
- [x] **T37** `WindowsRemoteLiveTests.testCreateRenameCopyMoveDelete` — create folder, rename, copy, move, and delete-to-Detours-trash succeed and are reflected in listings; the deleted item is not permanently removed (A4, A5); skips unless `DETOURS_WINDOWS_TEST_TARGET` is set.
- [x] **T38** `WindowsRemoteLiveTests.testTrashRestoreBestEffort` — trash returns trash locations; restore returns the item to its original path when the trash item is available, and returns a clear error otherwise (A5); skips unless `DETOURS_WINDOWS_TEST_TARGET` is set.
- [x] **T39** `WindowsRemoteLiveTests.testZipCreateExtractAndToolGating` — ZIP create and extract round-trip, hidden selected entries survive the round trip, and 7z/tar are offered only when present on the host (A6); skips unless `DETOURS_WINDOWS_TEST_TARGET` is set.
- [x] **T40** `WindowsRemoteLiveTests.testDownloadUploadLargeBinary` — download and upload of a large binary file preserve byte-exact contents (A7); skips unless `DETOURS_WINDOWS_TEST_TARGET` is set.
- [x] **T41** `WindowsRemoteLiveTests.testQuickLookAndFind` — Quick Look downloads and previews a file; `find` streams matching names from the active directory (A8); skips unless `DETOURS_WINDOWS_TEST_TARGET` is set.
- [x] **T42** `WindowsRemoteLiveTests.testWatchEmitsChangeOnServerSideModification` — a folder open via the provider receives a change event when its contents change on the host (A9); skips unless `DETOURS_WINDOWS_TEST_TARGET` is set.

### UI Tests (`Tests/UITests/DetoursUITests/`, run on Foundry)

- [x] **T43** `WindowsRemoteUITests.testReconnectBannerForWindowsHost` — a dropped Windows host shows the dismissable "Connection lost" banner and reconnect affordance identical to other remote hosts (A10), and a local/Unix tab is unaffected (A11).
