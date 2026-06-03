# Remote VM Browsing

## Meta

- Status: Draft
- Branch: feature/remote-vm-browsing

---

## Business

### Goal

Detours users can browse and operate on files on their remote Linux machines (development VMs, lab hosts, servers reached over SSH) from inside Detours with the same feel and the same features as a local pane. Connecting uses the SSH keys and configuration the user already has on their Mac, with no new passwords to manage. Once connected, the remote machine behaves as much like a local volume as is technically possible: file listings, folder sizes, git status markers, real-time updates when files change, copy and move with progress, rename, archive create and extract, and safe deletion that can be undone. The feature is built for the case Marco actually uses every day: dev VMs on a fast local network, reached through the SSH agent and SSH config already on his Mac.

### Proposal

Add a Remote section to the sidebar where the user lists their SSH hosts. Selecting a host opens that host in a Detours pane with the same look, the same shortcuts, and the same features as the local panes, including safe delete, undo, and git status markers. The remote feel is achieved by deploying a small helper program onto the host the first time the user connects, which Detours then talks to over the existing SSH connection.

### Behaviors

- Adding a remote host asks only for a display name and the SSH target (for example `my-dev-vm` or `marco@cognel-dev`). It does not ask for a password or a key path; it uses the user's SSH agent and SSH configuration the same way the terminal does.
- The sidebar shows each remote host with a coloured status dot: green for connected, yellow for connecting or reconnecting, grey for not connected, red for an error such as authentication failure or unreachable host.
- On the first connect to a host, Detours shows the SSH fingerprint of the host and asks the user to confirm it before continuing. If the fingerprint changes on a later connect, the connection is blocked and the user is shown the old and new fingerprint with two choices: trust the new key or disconnect.
- After the user confirms the host on the first connect, Detours installs a small helper program on the remote host and starts it. The user sees a progress sheet describing each step (connecting, installing helper, starting). On every subsequent connect, the helper is started directly with no install step.
- Browsing a remote folder feels like browsing a local folder. File listings appear within a moment on a fast local network. Folder sizes, git status markers, file icons, sort order, hidden file toggling, and folder expansion all work.
- When a file is added, changed, or removed on the remote host (for example by a terminal session or a build script), the Detours pane updates within a moment, the same way it updates for local changes.
- Copy, move, rename, duplicate, archive, and extract all work for remote files. Operations that cross between local and remote run as transfers in the operations queue with progress and cancel.
- Delete on a remote host is safe by default. Deleted items go to a hidden trash directory on the same host and can be restored with Undo from inside Detours. The first time the user deletes a remote item, a one-time explainer notes that the host's trash is separate from the Mac's Trash. The explainer can be retrieved from the Help menu at any time.
- Cmd-P quick navigation includes recently visited remote folders. Remote paths show the host name as a label so the user can tell them apart from local paths at a glance. Entries from hosts that are not currently connected are dimmed.
- If a connection is lost mid-operation (network change, sleep, idle timeout), the affected pane shows a non-blocking banner with a Reconnect button. In-progress operations show their final outcome rather than disappearing silently.
- Open With on a remote file downloads the file to a local cache, opens it, and watches the local copy. When the user saves, the new version is uploaded back to the host. If the remote file has also changed since the download, the user is asked which version to keep.
- Drag from a remote pane to Finder or another app streams the file to a temporary local location with visible progress; cancelling drops the partial file.
- The fast lane for trivial file operations stays local-only. Remote operations always go through the operations queue with progress.

### Acceptance Criteria

- [ ] **A1** The user can add a dev VM in the sidebar in under thirty seconds by typing a display name and an SSH alias, and can connect successfully without entering a password or a key path, using their existing SSH agent and SSH configuration.
- [ ] **A2** On a fast local network, a remote folder listing appears in the pane within one second of clicking the host or navigating into a folder.
- [ ] **A3** Git status markers, folder sizes, file icons, sort, filter, and folder expansion all work in a remote pane and behave the same way they do in a local pane.
- [ ] **A4** When a file is added, modified, or removed on the remote host by another process, the Detours pane reflects the change within two seconds without the user having to refresh.
- [ ] **A5** Deleting a file from a remote pane moves it to a trash directory on the same host and can be undone with Cmd-Z, restoring the file to its original location.
- [ ] **A6** The user is shown the SSH fingerprint on the first connect to a new host and is asked to confirm it before any directory listing is shown. A fingerprint change on a later connect blocks access until the user explicitly accepts the new key or disconnects.
- [ ] **A7** A network drop, laptop sleep, or idle disconnect produces a visible non-blocking banner naming the host with a Reconnect button, and never leaves the pane silently stale or causes Detours' main window to hang.
- [ ] **A8** Cmd-P quick navigation returns recently visited remote folders, shows the host name as a label, and dims entries from hosts that are not currently connected.
- [ ] **A9** Detours never reads the contents of an SSH private key file and never prompts the user for an SSH key passphrase inside the app. An encrypted key without a running SSH agent produces a clear error telling the user to start their agent.
- [ ] **A10** Connecting to an Intel Linux host (x86_64) works on the first try. Connecting to a host running an unsupported architecture (for example ARM Linux) produces a clear, plain-language error naming the architecture and stating that only x86_64 Linux is supported in this release.
- [ ] **A11** Local file management continues to work exactly as it did before this feature shipped. Every existing test for local browsing, operations, folder watching, and git status passes unchanged.

### Out of scope

- Remote-to-remote copy between two different hosts. Initial release supports remote-to-local and local-to-remote streamed transfers only.
- Mac App Store distribution. The auto-deployed helper binary is incompatible with App Store sandboxing; distribution remains direct download only.
- Mounting the remote host as a Finder-visible volume (File Provider extension or FUSE-T). Detours' remote panes are visible only inside Detours.
- Remote git operations beyond the status overlay. No remote commit, push, pull, or stage from inside Detours.
- Connecting to non-Linux remotes (BSD, macOS, embedded sshd). The helper binary is Linux-only for the first release.
- Connecting to ARM Linux hosts. Only x86_64 Linux is supported in the first release. ARM support is a future release.
- Password authentication. Key-based auth only, delegated to the SSH agent. The app never prompts for an SSH key passphrase.
- Quick Look on files larger than one hundred megabytes on remote hosts. Large previews show a plain-language message that the file is too large to preview over a remote connection.
- Spotlight indexing of remote files.

---

## Technical

### Approach

The core change is introducing a `FileProvider` protocol that abstracts the filesystem behind every read and every write in Detours. Today every call site reaches directly for `FileManager` and the `file://` URLs on `FileItem`. After this spec, `FileItem.url` becomes a `Location` (either `local(URL)` or `remote(hostID, posixPath)`) and the data source, the operations queue, the rename controller, the archive and extract operations, and the git status provider all route through whichever `FileProvider` implements the current `Location`.

The remote `FileProvider` talks RPC to a small Swift program running on the remote host, multiplexed over a single SSH channel. The connection is established by spawning the system `/usr/bin/ssh` as a child process, which gives us the user's `~/.ssh/config`, ssh-agent, ed25519, ProxyJump, and `known_hosts` for free. A `ServerDeployer` runs on first connect: it runs `uname -sm` over SSH, compares the hash of the bundled helper binary to the one already on the host, and atomically `scp`s the right binary to `~/.detours-server/` if it is missing or out of date. Subsequent connects to the same host start the helper directly with no install step.

The helper program lives in a new top-level `Server/` directory and is built for Linux x86_64 via Swift Package Manager cross-compiled in a reproducible Docker container on `dockerhost`. The binary is bundled inside `Detours.app/Contents/Resources/Servers/` so it inherits the app's code signature; the build script refuses to ship if the binary is missing. On the remote, the helper handles file listings (streamed in chunks for large directories), file stat, copy, move, rename, archive create and extract, folder size, git status, FreeDesktop-spec trash with restore, and inotify-based file watching pushed back over the same RPC channel.

The reference architecture is Redmargin (`~/dev/redmargin/`), which has shipped this pattern in production for over a year. Redmargin's `SSHConnection`, `ServerDeployer`, RPC framing, and inotify watcher are directly portable to Detours, adapted to Detours' larger RPC surface (full file management vs Redmargin's read/write/watch).

The refactor in Phase 1 is the highest-risk part of this work because it touches almost every file under `src/FileList`, `src/Operations`, and `src/Services`. Phase 1 must land with every existing test green and zero behaviour change for local browsing before any remote code begins.

### Approach Validation

The decision to ship the helper-daemon pattern (over pure-Swift Citadel SFTP or FUSE-T sshfs mount) was made after parallel design of all three approaches, audited by UI, security, and test-engineering lenses. The findings:

- Citadel SFTP (pure-Swift) ships fastest but silently drops git status, folder sizes, and real-time watching because SFTP has no inotify equivalent and no recursive size primitive. Polling for changes makes the remote pane feel half-broken next to the local pane.
- FUSE-T sshfs mount inherits every feature for free because the mount is a real POSIX path, but it requires shipping a kernel-adjacent system extension to every user, breaks the no-permanent-deletion rule (rm on a mount is final and macOS Trash cannot recover it), and depends on a third-party project (FUSE-T) whose long-term availability is uncertain. macFUSE itself is no longer fully open-source and is dropped from Homebrew core; users would need to boot into Recovery and enable Reduced Security to install it.
- The helper-daemon pattern preserves every Detours feature on remote panes, inherits `~/.ssh/config` semantics, has been battle-tested in Redmargin, and is the only approach where the No Permanent Deletion rule can be honoured on remote hosts via a FreeDesktop trash directory.

The system `/usr/bin/ssh` shell-out path was chosen over the pure-Swift NIOSSH path because ForkLift's public post-mortem (4.2.5 release notes, Feb 2025) documents the same migration away from libssh2 for the same reasons: `Include`, `Match`, `ProxyJump`, and per-host `IdentityFile` resolution are first-match-wins, tokenised, and full of edge cases. Reimplementing OpenSSH's `ssh_config` parser is a security boundary we should not own when the system already has a vetted one.

Sources: Citadel (`github.com/orlandos-nl/Citadel`), SwiftNIO SSH (`swift.org/blog/swiftnio-ssh/`), ForkLift 4.2.6 release notes (`blog.binarynights.com/2025/02/26/forklift-4-2-6-is-available/`), FUSE-T (`xhinker.medium.com/a-better-way-to-use-sshfs-in-macos-finder-in-2026-479b3b79bdf7`), macFUSE wiki (`github.com/macfuse/macfuse/wiki/Getting-Started`).

### Risks

| Risk | Mitigation |
| --- | --- |
| The helper binary auto-deployed to remote hosts is a supply-chain pivot: a compromised Detours could push arbitrary code to every host the user has ever connected to. A subtle hash-check bug or non-atomic deploy could let an attacker on a shared dev VM replace the binary between deploys. | Bundle the helper binary inside the codesigned `Detours.app` so it inherits the app's signature. Deploy atomically (write to a temp name, fsync, rename). Re-hash and check owner and permissions immediately before every exec, not only at deploy time. Refuse to launch if the binary is owned by another user or is group- or world-writable. Prompt the user the first time a hash change would cause a redeploy. |
| The refactor to introduce `FileProvider` and `Location` touches almost every file under `src/FileList`, `src/Operations`, and `src/Services`. A wrong move breaks local file management for everyone, which is the app's core function. | Land Phase 1 as a pure refactor with no behaviour change and every existing test green before any remote code is written. Keep a `url` accessor on `Location` for the local case so existing call sites compile incrementally. Land Phase 1 in a single commit on the feature branch and verify visually with the local build before continuing. |
| Large directory listings (50,000+ entries, common in `node_modules` or `/var/log`) exceed the size of a single RPC frame and stall the pane. | The RPC protocol streams directory listings in chunks from the first message, not as a single response. The data source renders chunks as they arrive so the pane shows the first entries within a few hundred milliseconds even on huge directories. A maximum frame size is enforced and exceeded frames are split. |
| The just-landed fast-lane operations spec assumes `FileManager` copy latency under tens of milliseconds. Routing a remote operation through the fast lane would stall the main actor. | The fast-lane classifier in `FileOperationQueue` excludes any operation whose source or destination is a remote `Location`, regardless of declared size. A unit test in `FileOperationQueueTests` asserts the exclusion. |
| Idle drops on long-lived connections kill the SSH channel after 60-300 seconds on corporate NATs and tunnels. Without keepalive and a reconnect state machine, the pane silently goes stale. | The `SSHConnection` actor sets `ServerAliveInterval=30` and `ServerAliveCountMax=3` on the spawned `ssh` process. A reconnect state machine re-establishes the daemon connection and re-registers watch tokens after a drop. The pane shows a non-blocking Reconnect banner when the state machine cannot recover automatically. |
| inotify on the remote can blow past `fs.inotify.max_user_watches` on large repos. The pane would silently miss events. | The watcher only registers inotify watches for directories that are currently visible (expanded or in the current directory listing) rather than recursive watches. When a watch fails because the inotify ceiling is reached, the daemon surfaces a typed RPC error and the client displays a one-time banner explaining the limit. |
| Remote trash is a new file management surface and is invisible to macOS Trash and Finder. A path traversal in the restore RPC, a race between trash and rename, or a tmpwatch-style cleanup on the host could silently lose user data. | Store the remote trash at `~/.local/share/Trash` on the host with mode `0700`, following the FreeDesktop spec. The restore RPC canonicalises the destination path and refuses to restore outside the user's home. A one-time explainer the first time the user deletes a remote item makes the separate trash visible; the explainer is also retrievable from the Help menu. |
| Drag-out to Finder or another app and the Open With round-trip both materialise files in `~/Library/Caches/Detours/remote/`. A hostname or path containing shell metacharacters used to construct a cache directory name could escape the cache root. | Cache directory names use the hash of the host alias and a sanitised path component, never raw user input. Per-session subdirectories are created with mode `0700`. Materialisation writes to a temp name and renames into place atomically. |

### Implementation Plan

**Phase 1: FileProvider refactor (no remote code yet)**

- [ ] **T1** Create `src/Services/FileProvider/FileProvider.swift` defining the protocol with async methods: `list`, `stat`, `copy`, `move`, `delete`, `trash`, `rename`, `archiveCreate`, `archiveExtract`, `watch`, `unwatch`, `gitStatus`, `folderSize`, `readSymlink`, `openForQuickLook`.
- [ ] **T2** Create `src/Services/FileProvider/Location.swift` defining `enum Location { case local(URL); case remote(hostID: UUID, path: String) }` with helpers for path manipulation that work for both cases. Add a `url` computed property that traps on the remote case so callers must update intentionally.
- [ ] **T3** Create `src/Services/FileProvider/LocalFileProvider.swift` that wraps every existing `FileManager` call site behind the protocol. Method-for-method mapping, no behaviour change.
- [ ] **T4** Migrate `src/FileList/FileItem.swift` so the bare `url: URL` field becomes `location: Location`. Add a `url` convenience for the local case to ease the migration. Update both initialisers and the iCloud / shared-folder paths.
- [ ] **T5** Route `src/FileList/FileListDataSource.swift` through `FileProvider`: `loadDirectory`, folder size lookups, git status overlay, sort. Preserve NSOutlineView identity across reloads by hashing on `Location` rather than `URL`.
- [ ] **T6** Route `src/FileList/FileListViewController.swift` through `FileProvider`. Replace the `MultiDirectoryWatcher` call sites with `provider.watch(location:onChange:)`.
- [ ] **T7** Update `src/FileList/MultiDirectoryWatcher.swift` to be the local-only implementation behind `LocalFileProvider.watch`. The remote implementation lands in Phase 3.
- [ ] **T8** Route `src/Operations/FileOperationQueue.swift` through `FileProvider`. Gate the fast lane to operations where both source and destination are `Location.local`, regardless of size or count. Add explicit refusal for any `Location.remote` operation in the fast-lane classifier.
- [ ] **T9** Route `src/Operations/RenameController.swift`, archive create, archive extract, and trash service through `FileProvider`.
- [ ] **T10** Route `src/Services/GitStatusProvider.swift` through `FileProvider`. The local path still runs `git status` via `Process`; the remote path will delegate to the remote helper in Phase 3.
- [ ] **T11** Verify every existing unit test, integration test, and UI test passes unchanged after Phase 1. No new failures, no new skips.

**Phase 2: SSH connection and remote helper**

- [ ] **T12** Add `src/Remote/SSHConnection.swift` as an actor wrapping `Process(executable: "/usr/bin/ssh")` with `ServerAliveInterval=30`, `ServerAliveCountMax=3`, `ControlMaster=auto`, `ControlPath=~/.detours/ssh-%C`. Length-prefixed framing over stdin/stdout.
- [ ] **T13** Add `src/Remote/SSHConnectionState.swift` with state machine: `disconnected`, `connecting`, `connected`, `reconnecting`, `failed(reason)`. Reconnect on transient network drop. Post `Notification.Name` events for state transitions so the sidebar can update the status dot.
- [ ] **T14** Add `src/Remote/Protocol/RPCMessage.swift` and `src/Remote/Protocol/RPCStreamHandler.swift` for length-prefixed binary framing, request/response ID tracking, and streamed multi-frame responses (used for directory chunks and inotify events).
- [ ] **T15** Add `src/Remote/Protocol/Messages.swift` defining every typed RPC message: `List`, `Stat`, `Copy`, `Move`, `Rename`, `Delete` (alias for trash), `Trash`, `RestoreFromTrash`, `MkDir`, `ReadSymlink`, `FolderSize`, `GitStatus`, `ArchiveCreate`, `ArchiveExtract`, `Watch`, `Unwatch`, `WatchEvent`.
- [ ] **T16** Create `Server/` top-level directory and a Swift Package target `detours-server` with `linux` platform constraint. Files: `main.swift`, `Daemon.swift`, `RPCHandler.swift`, `FileOperations.swift`, `UnixSocket.swift`.
- [ ] **T17** Add `resources/scripts/build-server-linux.sh` that cross-compiles the `detours-server` target inside a reproducible Swift Linux Docker container on `dockerhost`. Output: `Resources/Servers/detours-server-x86_64-linux`. Verify SHA256 in the script after build.
- [ ] **T18** Update `resources/scripts/build.sh` to copy the Linux helper binary into `Detours.app/Contents/Resources/Servers/` and to refuse to ship if the binary is missing. Codesign step picks up the new resource automatically.
- [ ] **T19** Add `src/Remote/ServerDeployer.swift`: detect `uname -sm` on remote, refuse with a typed error if the architecture is not `x86_64` Linux, hash-compare against the bundled binary, atomic `scp` to `~/.detours-server/detours-server.tmp` then rename to `~/.detours-server/detours-server`, owner-and-permission check before every exec.
- [ ] **T20** Add `src/Remote/RemoteHost.swift` (model: `id: UUID`, `displayName`, `sshTarget`, `knownHostKeyFingerprint`, `lastConnected`) and `src/Remote/RemoteHostStore.swift` persisting hosts in `UserDefaults`. No Keychain item: authentication is delegated to ssh-agent.

**Phase 3: Remote FileProvider and sidebar**

- [ ] **T21** Add `src/Services/FileProvider/RemoteFileProvider.swift` implementing `FileProvider` over RPC. `list` returns an `AsyncSequence` of directory chunks so the data source can render the first entries immediately.
- [ ] **T22** Add `Server/Watcher.swift` using Linux inotify. Register watches only for currently-visible directories. Surface `EMFILE` and `ENOSPC` as typed RPC errors.
- [ ] **T23** Add `Server/GitOperations.swift` shelling to `git status --porcelain` and parsing the result into the same `GitStatus` model the local path uses.
- [ ] **T24** Add `Server/FolderSizeOperations.swift` computing folder sizes via `du -sb` or equivalent. Results cached on the server side and invalidated on inotify events along the changed path (matching the local pattern).
- [ ] **T25** Add `src/Sidebar/RemoteHostsSection.swift` and update `src/Sidebar/SidebarViewController.swift` and `src/Sidebar/SidebarItem.swift` with a new Remote Hosts section placed above the Network section. Each host row shows display name, SSH target as a subtitle, and a status dot.
- [ ] **T26** Update `src/Sidebar/SidebarItemView.swift` to render the status dot in four colours: green (connected), yellow (connecting or reconnecting), grey (disconnected), red (error). Tooltip shows the last error message when red.
- [ ] **T27** Add `src/Sidebar/AddRemoteHostView.swift` (SwiftUI sheet) with fields for display name and SSH target, a Test Connection button, and the first-connect host-key fingerprint confirmation step.
- [ ] **T28** Add the host-key-change blocking dialog: on connect, if the server's host key fingerprint differs from the stored `knownHostKeyFingerprint`, show old and new fingerprints with two choices: Trust New Key (updates the stored fingerprint) or Disconnect.

**Phase 4: Remote operations, trash, watching, navigation**

- [ ] **T29** Add `Server/TrashOperations.swift` implementing FreeDesktop trash at `~/.local/share/Trash` with mode `0700`. Each trashed item writes a `.trashinfo` companion file. Restore RPC canonicalises the destination path and refuses to restore outside `$HOME`.
- [ ] **T30** Add `Server/ArchiveOperations.swift` that creates and extracts ZIP, TAR, and 7Z archives by shelling to `bsdtar` and `7z`. Mirror the local archive operations' progress reporting through streamed RPC frames.
- [ ] **T31** Wire Undo through the trash and restore RPCs in `src/Operations/`: a remote delete records the trash entry path and the original location; Cmd-Z restores via `RestoreFromTrash`.
- [ ] **T32** Add the one-time remote-trash explainer in `src/Operations/`. Dismissed via a checkbox. Retrievable from the Help menu via a new "About Remote Trash" item in `src/App/MainMenu.swift`.
- [ ] **T33** Add `src/Remote/RemoteWatcherClient.swift` that subscribes to streamed `WatchEvent` frames from the daemon and bridges them into the same `onChange(URL)` callback shape that local `FSEventStream` uses, so `MultiDirectoryWatcher` does not need to know remote events are different.
- [ ] **T34** Update `src/Navigation/` (Cmd-P quick nav, history, frecency) to store `Location` values instead of `URL`. Remote entries show the host display name as a label and are dimmed when the host is not connected.
- [ ] **T35** Implement Open With round-trip in `src/FileList/FileOpenHelper.swift`: download remote file to `~/Library/Caches/Detours/remote/<hostHash>/<sessionID>/` (mode `0700`), open via `NSWorkspace`, watch the local copy with `FSEventStream`, upload on save. On upload, if the remote file's modification timestamp has changed since the download, show a conflict dialog with Keep Mine, Keep Remote, and Cancel.
- [ ] **T36** Implement remote drag-out in `src/FileList/FileListViewController+DragDrop.swift` using `NSFilePromiseProvider` to materialise the file to a per-session `~/Library/Caches/Detours/remote/<hostHash>/<sessionID>/` directory with progress and cancel.

**Phase 5: Reconnect, error UX, polish**

- [ ] **T37** Add the reconnect banner UI in `src/Panes/PaneViewController.swift`: a non-blocking strip above the file list naming the host and a Reconnect button. Banner appears when the connection state transitions to `reconnecting` or `failed`.
- [ ] **T38** Update `src/Operations/FileOperationQueue.swift` so in-progress remote operations show a typed outcome on disconnect (cancelled, partial, complete) rather than disappearing from the queue.
- [ ] **T39** Add cache directory sanitisation helpers in `src/Remote/RemoteHost.swift` (hash-based directory naming) and use them everywhere a local cache directory is created from a host or path.
- [ ] **T40** Add `resources/docs/remote-vm-browsing.md` documenting supported `~/.ssh/config` directives, the remote trash location, the helper binary install location, and how to manually remove the helper from a host.

---

## Testing

Tests continue the `T<n>` sequence. Unit tests live in `Tests/`. UI tests live in `Tests/UITests/DetoursUITests/`. The Linux server tests run inside a Docker container on `dockerhost` via the cross-compile script. Integration tests against a real SSH host gate with `XCTSkipIf` when the host is unreachable and target `devtest` (the project's scratch VM, x86_64 Linux) by default.

### Unit Tests (`Tests/`)

- [ ] **T41** `LocationTests.testLocalRoundTrip` - `Location.local(URL)` round-trips through `Codable` and equality.
- [ ] **T42** `LocationTests.testRemoteRoundTrip` - `Location.remote(hostID, path)` round-trips through `Codable` and equality.
- [ ] **T43** `LocationTests.testPathManipulation` - `appendingPathComponent`, `deletingLastPathComponent`, and `parent` work identically for both cases.
- [ ] **T44** `FileItemTests.testIdentityAcrossReloads` - `FileItem` identity hash is stable across reloads for both local and remote `Location`s.
- [ ] **T45** `LocalFileProviderTests.testListReturnsExpectedEntries` - `LocalFileProvider.list` returns the same entries as the pre-refactor `FileManager` enumeration for a temp directory tree.
- [ ] **T46** `LocalFileProviderTests.testCopyAndMoveBehaviour` - copy and move through the provider behave identically to the pre-refactor implementation, including overlap and target-exists handling.
- [ ] **T47** `FileOperationQueueTests.testFastLaneRefusesRemoteSource` - any operation with a `Location.remote` source is routed to the queued path, never the fast lane.
- [ ] **T48** `FileOperationQueueTests.testFastLaneRefusesRemoteDestination` - any operation with a `Location.remote` destination is routed to the queued path, never the fast lane.
- [ ] **T49** `RPCStreamHandlerTests.testLengthPrefixEncoding` - frames encode and decode round-trip for empty, small, and 1MB payloads.
- [ ] **T50** `RPCStreamHandlerTests.testPartialReadReassembly` - frames delivered in arbitrary byte-chunk sizes reassemble correctly.
- [ ] **T51** `RPCStreamHandlerTests.testOversizedFrameRejected` - a frame above the configured maximum is rejected with a typed error and the connection is marked failed.
- [ ] **T52** `RPCStreamHandlerTests.testStreamedDirectoryChunks` - multi-frame responses for a single request ID assemble in order regardless of interleaved unrelated frames.
- [ ] **T53** `RPCStreamHandlerTests.testOutOfOrderResponseIDs` - responses arriving out of order match their original requests by ID.
- [ ] **T54** `MessagesTests.testEveryMessageRoundTrips` - every message type in `Messages.swift` round-trips through binary encoding, including filenames as length-prefixed byte arrays.
- [ ] **T55** `ServerDeployerTests.testHashCompareSkipsRedeploy` - deploy is skipped when the remote binary's hash matches the bundled binary.
- [ ] **T56** `ServerDeployerTests.testRefusesNonX86_64` - `uname -sm` returning an ARM or non-Linux architecture surfaces a typed error before any deploy.
- [ ] **T57** `ServerDeployerTests.testRefusesWrongOwner` - exec is refused when the binary on the remote is owned by a user other than the current SSH user.
- [ ] **T58** `ServerDeployerTests.testRefusesGroupOrWorldWritable` - exec is refused when permissions on the binary are group- or world-writable.
- [ ] **T59** `ServerDeployerTests.testAtomicRenameDeploy` - deploy writes to a temp name and renames into place; a deploy interrupted before the rename leaves no stale partial binary visible to a subsequent connect.
- [ ] **T60** `SSHConnectionStateTests.testReconnectAfterTransientDrop` - drive the state machine through `disconnected` to `connecting` to `connected` to `reconnecting` to `connected` with a stubbed `Process`; assert watch tokens re-register after reconnect.
- [ ] **T61** `SSHConnectionStateTests.testFailedStateOnAuthError` - auth failure transitions to `failed(reason: .authentication)` and does not retry.
- [ ] **T62** `RemoteHostStoreTests.testPersistAcrossRelaunch` - hosts added to the store survive an `UserDefaults` reset round-trip.
- [ ] **T63** `RemoteHostTests.testCacheDirSanitisation` - a host display name or SSH target containing shell metacharacters produces a cache directory name that never contains the raw characters.

### Linux Server Tests (`Server/Tests/`, run via Docker on dockerhost)

- [ ] **T64** `FileOperationsServerTests.testListReturnsExpectedEntries` - server `List` returns the same entries as `ls -la` for a fixture directory.
- [ ] **T65** `FileOperationsServerTests.testStreamedListChunks` - a 50,000-entry directory produces multiple chunks; the first chunk arrives before the last.
- [ ] **T66** `TrashOperationsServerTests.testTrashCreatesCorrectTrashInfo` - trashing a file creates `~/.local/share/Trash/files/<name>` and `~/.local/share/Trash/info/<name>.trashinfo` with the correct original path.
- [ ] **T67** `TrashOperationsServerTests.testRestoreRefusesPathOutsideHome` - a restore RPC with a target outside `$HOME` returns a typed error and does not move the file.
- [ ] **T68** `TrashOperationsServerTests.testRestoreToOriginalLocation` - restore puts the file back at the original path recorded in `.trashinfo`.
- [ ] **T69** `WatcherServerTests.testInotifyEventForCreate` - creating a file inside a watched directory produces a `WatchEvent` frame.
- [ ] **T70** `WatcherServerTests.testSurviveDirectoryRename` - renaming a watched directory does not crash the daemon and re-emits the watch on the new path.
- [ ] **T71** `WatcherServerTests.testInotifyCeilingSurfacesTypedError` - simulating an `ENOSPC` from `inotify_add_watch` surfaces a typed RPC error to the client.
- [ ] **T72** `GitOperationsServerTests.testGitStatusOverlay` - `git status` against a fixture repo returns the same set of marked paths the local implementation does.

### Integration Tests (`Tests/Integration/`, gated on devtest reachability)

- [ ] **T73** `RemoteIntegrationTests.testListDirectoryReturnsExpectedEntries` - connect to `devtest`, list `/etc`, assert at least one expected file is present.
- [ ] **T74** `RemoteIntegrationTests.testCopyRemoteToLocal` - copy a remote fixture file into a local temp directory; assert byte-equality.
- [ ] **T75** `RemoteIntegrationTests.testCopyLocalToRemote` - copy a local fixture file into a remote temp directory; assert byte-equality via the daemon's `Stat`.
- [ ] **T76** `RemoteIntegrationTests.testWatchDirectoryReceivesInotifyEvent` - watch a remote directory, touch a file inside it via the daemon, assert a `WatchEvent` arrives within two seconds.
- [ ] **T77** `RemoteIntegrationTests.testTrashAndRestore` - trash a remote file, assert it is no longer at the original path, run Undo, assert it is restored.
- [ ] **T78** `RemoteIntegrationTests.testGitStatusOverlay` - clone a fixture repo into a remote temp directory, modify a file, list the directory, assert the modified file carries a `modified` git status marker.
- [ ] **T79** `RemoteIntegrationTests.testReconnectAfterIdle` - establish a connection, force idle past `ServerAliveInterval * ServerAliveCountMax`, then perform a list; assert the reconnect state machine recovers and the list succeeds.
- [ ] **T80** `RemoteIntegrationTests.testHostKeyChangeBlocks` - connect once and record the fingerprint, swap the host's host key fixture, attempt to reconnect, assert the connection is blocked and the host-key-change dialog event is fired.
- [ ] **T81** `RemoteIntegrationTests.testUnsupportedArchitectureError` - connect to a fixture host reporting `uname -sm` as `aarch64`, assert a typed error naming the architecture and no deploy attempt.

### UI Tests (`Tests/UITests/DetoursUITests/`)

- [ ] **T82** `RemoteHostUITests.testAddRemoteHostFlow` - open the Add Remote Host sheet, fill in display name and SSH target, press Test Connection, confirm fingerprint, assert the host appears in the sidebar with a green status dot.
- [ ] **T83** `RemoteHostUITests.testRemotePaneShowsListing` - select an existing remote host in the sidebar, assert a directory listing renders in the pane within two seconds.
- [ ] **T84** `RemoteHostUITests.testReconnectBannerAppearsOnDrop` - simulate a connection drop via the test hook, assert the reconnect banner appears with the host name and a Reconnect button.
- [ ] **T85** `RemoteHostUITests.testCmdPDimsDisconnectedRemoteEntries` - disconnect a host, open Cmd-P, assert remote entries from that host render dimmed.
