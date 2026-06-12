# Remote VM Browsing

## Meta

- Status: Reviewed
- Branch: feature/remote-vm-browsing

---

## Business

### Goal

Detours users can browse and operate on files on their remote Linux machines (development VMs, lab hosts, servers reached over SSH) from inside Detours with the same feel and the same features as a local pane. Connecting uses the SSH keys and configuration the user already has on their Mac, with no new passwords to manage and no SMB, NFS, AFP, Finder mount, or network-share setup for VM browsing. Once connected, the remote machine supports the file management features Detours already provides for local panes: file listings, Quick Look, Open With, folder sizes, git status markers, updates when files change, copy and move with progress, rename, archive create and extract, and safe deletion that can be undone. The feature is built for the case Marco uses every day: dev VMs on a fast local network, reached through the SSH agent and SSH config already on his Mac.

### Proposal

Add a Remote Hosts section to the sidebar where the user lists their SSH hosts. Selecting a host opens that host in a Detours pane with the same look, the same shortcuts, and the same features as the local panes, including Quick Look, Open With, copy, move, safe delete, undo, archive/extract, and git status markers. The remote feel is achieved by deploying a small helper program onto the host the first time the user connects, which Detours then talks to over the existing SSH connection, matching Redmargin's helper-over-SSH pattern.

### Behaviors

- Adding a remote host asks only for a display name and the SSH target (for example `my-dev-vm` or `marco@cognel-dev`). It does not ask for a password or a key path; it uses the user's SSH agent and SSH configuration the same way the terminal does.
- Add Remote Host is a File menu action. The Go menu remains navigation-only and contains no remote-host connection command.
- Remote VM browsing is always SSH-backed and helper-backed; it never requires the user to specify an SMB/NFS/AFP share URL. The separate NAS/network-volume workflow remains available for actual NAS shares, and already-mounted encrypted images remain ordinary Devices.
- The SSH target field suggests entries from the user's `~/.ssh/config` as the user types. Only top-level `Host` blocks with literal aliases or wildcard patterns are suggested; `Match` blocks and conditional includes are ignored to keep the suggestion path safe.
- The sidebar shows each remote host with a coloured status dot: green for connected, yellow for connecting or reconnecting, grey for not connected, red for an error such as authentication failure or unreachable host. A red dot exposes the last error message in its tooltip.
- On the first connect to a host not yet trusted by Detours, Detours shows the SSH fingerprint of the host and asks the user to confirm it before continuing. There is no "connect once" path. If the fingerprint changes on a later connect, the connection is blocked and the user is shown the old and new fingerprint with two choices: Trust New Key or Disconnect.
- After the user confirms the host on the first connect, Detours installs a small helper program on the remote host and starts it. The install runs inside a modal sheet titled with the host name and shows named steps with checkmarks (Connecting, Checking host architecture, Installing helper, Starting helper, Done) plus a Cancel button. Subsequent connects start the helper directly with no install step.
- When the helper binary bundled inside Detours is newer than the one already installed on the host, the install step runs silently on the next connect to bring the host up to date. The user does not see a separate update prompt.
- Browsing a remote folder feels like browsing a local folder. File listings appear within a moment on a fast local network. Folder sizes, git status markers, file icons, sort order, hidden file toggling, and folder expansion all work.
- When a file is added, changed, or removed on the remote host (for example by a terminal session or a build script), the Detours pane updates within a moment, the same way it updates for local changes. If the host has reached its inotify watch limit, a one-time per-session banner explains the limit and gives the exact sysctl command to raise it; the pane falls back to refreshing visible directories every ten seconds until the user dismisses the banner or raises the limit.
- The pane's breadcrumb shows a coloured pill with the host display name as its leftmost element so the user always knows which host a pane is showing. File rows themselves look identical to local rows; there is no per-row remote badge.
- Symbolic links render with the macOS link badge and show their own size (the length of the link target string) rather than the size of the target. A single click selects the link; a double-click follows the link to its target if reachable and shows a clear error if the link is broken.
- Files the user cannot read render greyed with a lock badge. Attempting to open, copy, or read them surfaces a plain-language permission-denied error naming the file.
- Filenames on the remote that are not valid UTF-8 render with the Unicode replacement glyph in place of the invalid bytes. Copy, move, rename, and delete operations on those files still work because the wire protocol carries filenames as length-prefixed byte arrays and operations are performed on the raw bytes.
- The hidden file toggle (Cmd-Shift-.) acts as a client-side filter. The daemon always sends every entry; the toggle has no round-trip cost.
- Copy, move, rename, duplicate, archive, and extract all work for remote files. Operations that cross between local and remote run as transfers in the operations queue with progress and cancel.
- Large transfers (over one megabyte) run on a separate SSH channel parallel to the metadata channel so a multi-gigabyte copy does not block directory listings, git status updates, or watch events on the same host. The transfer channel invokes the Detours helper in transfer mode and carries paths as length-prefixed byte arrays, so filenames that are not valid UTF-8 still transfer correctly.
- A cancelled or dropped large transfer leaves no partial file at the destination. Transfers are written to a temporary name and atomically renamed only after the byte count matches; cancel or disconnect deletes the temp file.
- Delete on a remote host is safe by default. Deleted items go to a hidden trash directory on the same host and can be restored with Undo from inside Detours. The first time the user deletes a remote item, a one-time explainer notes that the host's trash is separate from the Mac's Trash. The explainer can be retrieved from the Help menu at any time.
- Cmd-P quick navigation includes recently visited remote folders. Remote paths show the host name as a label so the user can tell them apart from local paths at a glance. Frecency entries are anchored to the host's identifier; renaming a host's display name updates the label on existing entries without losing history. Entries from hosts that are not currently connected render dimmed.
- Quick Look on a remote file downloads the file on demand when the user presses Space. Files under one megabyte transfer silently. Files between one megabyte and one hundred megabytes show a determinate progress indicator inside the Quick Look panel. Files above the hundred-megabyte threshold show a plain-language message that the file is too large to preview over a remote connection.
- If a connection drops, Detours retries automatically with exponential backoff (one, two, four, eight, sixteen seconds) for up to one minute. If reconnection succeeds, watch tokens re-register silently and the pane refreshes without further interaction. If reconnection fails, the affected pane shows a non-blocking banner naming the host with a Reconnect button.
- File operations queued for a host whose connection has dropped pause and surface in the operations indicator as "Paused — waiting for [host]". On successful reconnect the queue resumes from where it left off. An in-progress transfer at the moment of the drop has its partial file deleted and the operation requeues from the start. The user can cancel from the queue UI at any time.
- A connection closes after five minutes with no active pane on the host, no in-flight operation, and no active watch. The next interaction reconnects automatically.
- Open With on a remote file downloads the file to a local cache, records its hash and modification time, opens it, and watches the local copy. When the user saves, the new version is uploaded back to the host. Before uploading, the daemon rereads the remote file's hash and modification time; if either has changed since the download, the user is shown a conflict dialog with three choices: Keep Mine, Keep Remote, Cancel.
- Drag from a remote pane to Finder or another app streams the file to a temporary local location with visible progress; cancelling drops the partial file.
- The fast lane for trivial file operations stays local-only. Remote operations always go through the operations queue with progress.
- Removing a host from the sidebar while a pane is currently viewing it navigates that pane back to its previous local location. If there is no previous local location in the pane's history, the pane falls back to the user's home directory.
- A connection failure shows an error sheet leading with a plain-language summary. A "Show Details" disclosure reveals the raw `stderr` from the spawned `ssh` process and the last fifty lines of the daemon's `stderr`. A "Copy to Clipboard" button copies the full diagnostic block in one click.

### Acceptance Criteria

- [ ] **A1** The user can add a dev VM in the sidebar in under thirty seconds by typing a display name and an SSH alias, with autocomplete suggestions drawn from the user's `~/.ssh/config`, and can connect successfully without entering a password or a key path, using their existing SSH agent and SSH configuration.
- [ ] **A2** On a fast local network, a remote folder listing appears in the pane within one second of clicking the host or navigating into a folder.
- [ ] **A3** Git status markers, folder sizes, file icons, sort, filter, and folder expansion all work in a remote pane and behave the same way they do in a local pane.
- [ ] **A4** When a file is added, modified, or removed on the remote host by another process, the Detours pane reflects the change within two seconds without the user having to refresh. When the host's inotify watch limit is exceeded, a one-time per-session banner names the limit with the exact sysctl command to raise it, and the pane updates within ten seconds via fallback polling.
- [ ] **A5** Deleting a file from a remote pane moves it to a trash directory on the same host and can be undone with Cmd-Z, restoring the file to its original location.
- [ ] **A6** The user is shown the SSH fingerprint on the first connect to a new host and is asked to confirm it before any directory listing is shown. A fingerprint change on a later connect blocks access until the user explicitly accepts the new key or disconnects.
- [ ] **A7** A network drop, laptop sleep, or idle disconnect triggers automatic retry for up to one minute. If that fails, a non-blocking banner appears naming the host with a Reconnect button. Operations queued for the affected host pause and resume cleanly when the connection is restored, with no partial files left at any destination.
- [x] **A8** Cmd-P quick navigation returns recently visited remote folders, shows the host's current display name as a label, retains history when the display name is renamed, and dims entries from hosts that are not currently connected.
- [ ] **A9** Detours never reads the contents of an SSH private key file and never prompts the user for an SSH key passphrase inside the app. An encrypted key without a running SSH agent produces a clear error telling the user to start their agent.
- [ ] **A10** Connecting to an Intel Linux host (x86_64) works on the first try. Connecting to a host running an unsupported architecture (for example ARM Linux) produces a clear, plain-language error naming the architecture and stating that only x86_64 Linux is supported in this release.
- [x] **A11** Local file management continues to work exactly as it did before this feature shipped. Every existing test for local browsing, operations, folder watching, and git status passes unchanged, both with the FileProvider feature flag on and with it off.
- [ ] **A12** The first connect to a new host opens a modal sheet titled with the host name and shows named steps (Connecting, Checking host architecture, Installing helper, Starting helper, Done), each with a checkmark when complete. The sheet is cancellable at any step.
- [ ] **A13** A connection failure (authentication, ProxyJump misconfigured, unreachable host, helper failed to start) shows an error sheet with a plain-language summary, a "Show Details" disclosure containing the raw stderr from the spawned ssh process and the daemon, and a "Copy to Clipboard" button that copies the full diagnostic block.
- [x] **A14** Removing a host from the sidebar while a pane is currently viewing it navigates that pane back to its previous local location, falling back to the user's home if no previous local location exists.
- [ ] **A15** A large transfer (over one megabyte) that is cancelled by the user or interrupted by a dropped connection leaves no file at the destination under the target name. The temporary partial file is removed.
- [x] **A16** Symbolic links on remote panes render with the macOS link badge and the link's own size. A click selects, a double-click follows reachable links and shows a plain-language error for broken links.
- [x] **A17** Files the user cannot read on the remote host render greyed with a lock badge in the file list. Attempting to open, copy, or read them surfaces a plain-language permission-denied error naming the file.
- [x] **A18** Open With round-trip detects remote-side modifications between download and save by comparing both the file's hash and its modification time. A mismatch on either surfaces a conflict dialog with Keep Mine, Keep Remote, and Cancel options.
- [x] **A19** Quick Look on a remote file fetches the file only when the user presses Space. Files between one and one hundred megabytes show a determinate progress indicator in the Quick Look panel. Files above one hundred megabytes show a plain-language too-large message and do not initiate a download.
- [ ] **A20** A remote pane's breadcrumb shows a coloured pill with the host display name as the leftmost element. No per-row visual indicator is added to file rows.

### Out of scope

- Remote-to-remote copy between two different hosts. This release supports remote-to-local and local-to-remote streamed transfers only.
- Mac App Store distribution. The auto-deployed helper binary is incompatible with App Store sandboxing; distribution remains direct download only.
- Mounting the remote host as a Finder-visible volume (File Provider extension or FUSE-T). Detours' remote panes are visible only inside Detours.
- Replacing the existing NAS/network-volume workflow. In-app SMB/NFS/AFP discovery and mounting remain a separate feature for NAS shares, not a VM-browsing mechanism.
- Remote git operations beyond the status overlay. No remote commit, push, pull, or stage from inside Detours.
- Connecting to non-Linux remotes (BSD, macOS, embedded sshd). The helper binary is Linux-only for this release.
- Connecting to ARM Linux hosts. Only x86_64 Linux is supported in this release.
- Password authentication. Key-based auth only, delegated to the SSH agent. The app never prompts for an SSH key passphrase.
- Quick Look on files larger than one hundred megabytes on remote hosts.
- Spotlight indexing of remote files.
- An in-app "Empty Trash on Host" action. Users clear the remote trash directory manually over SSH.
- Bulk import of every Host block from `~/.ssh/config` into the sidebar. The Add Remote Host sheet offers autocomplete but each host is added one at a time, by the user, deliberately.

---

## Technical

### Approach

The core change is introducing a `FileProvider` protocol that abstracts the filesystem behind every read and every write in Detours. Today every call site reaches directly for `FileManager` and the `file://` URLs on `FileItem`. After this spec, `FileItem.url` becomes a `Location` (either `local(URL)` or `remote(hostID, posixPath)`) and the data source, the operations queue, the rename controller, the archive and extract operations, and the git status provider all route through whichever `FileProvider` implements the current `Location`. The refactor is feature-flagged behind `DETOURS_FILE_PROVIDER` so the new code path can be flipped off at runtime if a regression surfaces; the flag is removed once the full feature has shipped without regression.

The remote `FileProvider` talks RPC to a small Swift program running on the remote host. Two SSH channels are used: a long-lived multiplexed RPC channel for metadata, small operations, and watch events, and a short-lived helper transfer channel for individual file transfers above one megabyte. The connection is established by spawning the system `/usr/bin/ssh` as a child process, which gives Detours the user's `~/.ssh/config`, ssh-agent, ed25519, ProxyJump, and known host handling through OpenSSH. `ControlMaster=auto` with `ControlPath=~/.detours/ssh/%C` lets the transfer channel reuse the master connection. Detours creates `~/.detours/ssh/` with mode `0700` before connecting so no other local user can create or read the control socket. A `ServerDeployer` runs on first connect: it runs `uname -sm` over SSH, refuses non-x86_64-Linux with a typed error, compares the hash of the bundled helper binary to the one already on the host, and atomically copies the bundled binary to `~/.detours-server/` if it is missing, out of date, or fails the owner-and-permission check. Subsequent connects to the same host start the helper directly. Version skew between client and daemon is handled by silent redeploy on connect when hashes differ.

Host trust is app-scoped rather than silently inheriting a terminal prompt. Detours stores trusted host fingerprints in `~/.detours/known_hosts`, starts OpenSSH with that file as the user known-hosts file, and bridges OpenSSH's host-key prompt into a Detours sheet. Host-key prompts are the only interactive SSH prompt Detours answers. Password, keyboard-interactive, and private-key passphrase prompts are rejected and surfaced as plain-language errors that tell the user to fix their SSH agent or SSH config outside Detours.

The helper program lives in a new top-level `Server/` directory and is built for Linux x86_64 via Swift Package Manager cross-compiled in a reproducible Docker container on `dockerhost`. `resources/scripts/build.sh` hashes `Server/` and `Package.swift`'s server-target lines and only triggers the cross-compile when the hash differs from the local cached binary's hash, so day-to-day Mac-only commits skip dockerhost entirely. The generated binary and `.cache-hash` are local build artifacts ignored by Git. The binary is bundled inside `Detours.app/Contents/Resources/Servers/` from the local build output so it inherits the app's code signature; the build script refuses to ship if the binary is missing. On the remote, the helper handles file listings (streamed in chunks for large directories), file stat, copy, move, rename, archive create and extract, folder size, git status, FreeDesktop-spec trash with restore, inotify-based file watching, and raw-byte transfer mode.

The connection lifecycle is per Detours instance, per host: the SSH process stays alive while at least one pane is viewing the host, an operation is queued or running, or a watch is active, and it closes after five minutes of inactivity. Transient drops trigger automatic retry with exponential backoff (1, 2, 4, 8, 16 seconds) for up to sixty seconds; success resumes paused operations and re-registers watches, failure surfaces a non-blocking Reconnect banner in the affected pane.

The reference architecture is Redmargin (`~/dev/redmargin/`), which has shipped the helper-daemon pattern in production for over a year. Redmargin's `SSHConnection`, `ServerDeployer`, RPC framing, and inotify watcher are directly portable to Detours, adapted to Detours' larger RPC surface (full file management vs Redmargin's read/write/watch).

Phase 1 must land with every existing test green and zero behaviour change for local browsing before any remote code begins. The feature flag exists explicitly to make that verifiable: the same test suite must pass with the flag on and the flag off.

### Approach Validation

The decision to ship the helper-daemon pattern (over pure-Swift Citadel SFTP or FUSE-T sshfs mount) was made after parallel design of all three approaches, audited by UI, security, and test-engineering lenses. The findings:

- Citadel SFTP (pure-Swift) ships fastest but silently drops git status, folder sizes, and real-time watching because SFTP has no inotify equivalent and no recursive size primitive. Polling for changes makes the remote pane feel half-broken next to the local pane.
- FUSE-T sshfs mount inherits every feature for free because the mount is a real POSIX path, but it requires shipping a kernel-adjacent system extension to every user, breaks the no-permanent-deletion rule (rm on a mount is final and macOS Trash cannot recover it), and depends on a third-party project (FUSE-T) whose long-term availability is uncertain. macFUSE itself is no longer fully open-source and is dropped from Homebrew core; users would need to boot into Recovery and enable Reduced Security to install it.
- The helper-daemon pattern preserves every Detours feature on remote panes, inherits `~/.ssh/config` semantics, has been battle-tested in Redmargin, and is the only approach where the No Permanent Deletion rule can be honoured on remote hosts via a FreeDesktop trash directory.

The system `/usr/bin/ssh` shell-out path was chosen over the pure-Swift NIOSSH path because ForkLift's public post-mortem (4.2.5 release notes, Feb 2025) documents the same migration away from libssh2 for the same reasons: `Include`, `Match`, `ProxyJump`, and per-host `IdentityFile` resolution are first-match-wins, tokenised, and full of edge cases. Reimplementing OpenSSH's `ssh_config` parser is a security boundary we should not own when the system already has a vetted one.

The decision to use a separate helper transfer channel for transfers over one megabyte (rather than streaming bytes through the metadata RPC) was driven by head-of-line blocking: a single channel turns every multi-gigabyte copy into a minutes-long stall on git status, directory listings, and watch events. OpenSSH documents that `ControlMaster` shares multiple sessions over one network connection and recommends a unique, non-world-writable `ControlPath`; Detours uses a private `~/.detours/ssh/` socket directory and `%C` hashing for that reason. The transfer channel deliberately invokes the Detours helper instead of `scp`, because OpenSSH `scp` takes paths as command-line strings while Detours must preserve filenames that are not valid UTF-8.

Research also confirmed the core safety choices. OpenSSH's config model is first-match-wins and includes `Host`, `Match`, `ProxyJump`, and token expansion, which supports using system `ssh` instead of reimplementing config parsing. The FreeDesktop Trash specification requires an `info/` metadata file and warns that the filename under `files/` must not be used to recover the original path, which matches the remote restore plan. VS Code's remote watcher guidance and SmartGit's Linux watcher guidance both call out inotify watch limits as a common failure mode, so the one-time inotify banner and polling fallback stay in scope.

Sources: OpenSSH `ssh_config` manual (`https://man.openbsd.org/ssh_config`), FreeDesktop Trash specification (`https://specifications.freedesktop.org/trash/latest`), VS Code File Watcher Issues (`https://github.com/microsoft/vscode/wiki/File-Watcher-Issues`), SmartGit Linux watcher limit guidance (`https://docs.syntevo.com/SmartGit/Latest/HowTos/Configuration/Changing-the-Folder-Watch-Limit-Linux`), FUSE-T (`https://www.fuse-t.org/home`), macFUSE SSHFS wiki (`https://github.com/macfuse/macfuse/wiki/File-Systems-%E2%80%90-SSHFS`), Redmargin local reference (`~/dev/redmargin/`).

### Risks

| Risk | Mitigation |
| --- | --- |
| The helper binary auto-deployed to remote hosts is a supply-chain pivot: a compromised Detours can push arbitrary code to every host the user has ever connected to. A subtle hash-check bug or non-atomic deploy can let an attacker on a shared dev VM replace the binary between deploys. | Bundle the helper binary inside the codesigned `Detours.app` so it inherits the app's signature. Deploy atomically (write to a temp name, fsync, rename). Re-hash and check owner and permissions immediately before every exec, not only at deploy time. Refuse to launch if the binary is owned by another user or is group- or world-writable. The deploy is silent on hash mismatch by design, so the security boundary is the bundled binary's signature plus the deployer's pre-exec checks, not user attention. |
| The refactor to introduce `FileProvider` and `Location` touches almost every file under `src/FileList`, `src/Operations`, and `src/Services`. A wrong move breaks local file management for everyone, which is the app's core function. | Land Phase 1 as a pure refactor with no behaviour change, gated behind the `DETOURS_FILE_PROVIDER` runtime flag. The full existing test suite must pass with the flag on and with it off before Phase 2 begins. Keep a `url` accessor on `Location` for the local case so existing call sites compile incrementally. Remove the flag and the dual-path code only at the end of Phase 5, after the feature has shipped without regression. |
| `build.sh` now depends on `dockerhost` being reachable for the cross-compile, which would block every local Detours build if the cache guard is wrong. | Hash `Server/` and `Package.swift`'s server-target lines; only invoke the Docker cross-compile when the hash differs from the binary cached at `Resources/Servers/.cache-hash`. Day-to-day Mac-only edits skip dockerhost entirely. A clear error message names dockerhost when the cross-compile is needed but the host is unreachable; the user either brings dockerhost up or builds with an existing cached server binary. |
| Large directory listings (50,000+ entries, common in `node_modules` or `/var/log`) exceed the size of a single RPC frame and stall the pane. | The RPC protocol streams directory listings in chunks from the first message. The data source renders chunks as they arrive so the pane shows the first entries within a few hundred milliseconds even on huge directories. A maximum frame size is enforced and exceeded frames are split. |
| The fast-lane operations spec assumes `FileManager` copy latency under tens of milliseconds. Routing a remote operation through the fast lane stalls the main actor. | The fast-lane classifier in `FileOperationQueue` excludes any operation whose source or destination is a remote `Location`, regardless of declared size. A unit test in `FileOperationQueueTests` asserts the exclusion. |
| Idle drops on long-lived connections kill the SSH channel after 60-300 seconds on corporate NATs and tunnels. Without keepalive and a reconnect state machine, the pane silently goes stale. | The `SSHConnection` actor sets `ServerAliveInterval=30` and `ServerAliveCountMax=3` on the spawned `ssh` process. The reconnect state machine retries with exponential backoff (1, 2, 4, 8, 16 s) for up to sixty seconds before surfacing the Reconnect banner. Watch tokens re-register automatically on successful reconnect. Operations queued for the affected host pause and resume; in-progress transfers delete their partial and requeue from the start. |
| inotify on the remote can blow past `fs.inotify.max_user_watches` on large repos. The pane would silently miss events. | The watcher only registers inotify watches for currently-visible directories. When `inotify_add_watch` returns `ENOSPC`, the daemon surfaces a typed RPC error; the client shows a one-time per-session banner naming the limit with the exact sysctl command to raise it. The pane falls back to polling visible directories every ten seconds until the user dismisses the banner. |
| Remote trash is a new file management surface and is invisible to macOS Trash and Finder. A path traversal in the restore RPC, a race between trash and rename, or a tmpwatch-style cleanup on the host can silently lose user data. | Store the remote trash at `~/.local/share/Trash` on the host with mode `0700`, following the FreeDesktop spec. The restore RPC canonicalises the destination path and refuses to restore outside the user's home. A one-time explainer the first time the user deletes a remote item makes the separate trash visible; the explainer is also retrievable from the Help menu. |
| Drag-out to Finder or another app and the Open With round-trip both materialise files in `~/Library/Caches/Detours/remote/`. A hostname or path containing shell metacharacters used to construct a cache directory name can escape the cache root. | Cache directory names use the hash of the host alias and a sanitised path component, never raw user input. Per-session subdirectories are created with mode `0700`. Materialisation writes to a temp name and renames into place atomically. |
| Open With clock skew between Mac and remote (NTP drift on dev VMs is real) can cause mtime-only conflict prompts when file contents did not change. | Open With records both SHA256 and mtime on download. The save-time check opens the conflict dialog when either value changes, and the dialog names whether the mismatch is content, timestamp, or both so the user understands the risk before choosing Keep Mine, Keep Remote, or Cancel. |
| Streaming transfer work above the threshold needs its own progress, cancel, and partial-file cleanup story separate from the RPC channel. | Transfers write to `<name>.detours-partial` in the destination directory and atomically rename to the final name only after the byte count matches. Cancel from the UI or a dropped connection deletes the temp file. Progress is reported by the helper transfer protocol. A `RemoteTransferChannel` actor owns the lifecycle. |

### Implementation Plan

Phase headers are organisational. The phases land in order on the feature branch; the feature flag means Phase 1 can stay on the branch without regressing main.

**Phase 1: FileProvider refactor (no remote code yet)**

- [x] **T1** Create `src/Services/FileProvider/FileProvider.swift` defining the protocol with async methods: `list`, `stat`, `copy`, `move`, `delete`, `trash`, `restoreFromTrash`, `rename`, `archiveCreate`, `archiveExtract`, `watch`, `unwatch`, `gitStatus`, `folderSize`, `readSymlink`, `openForQuickLook`.
- [x] **T2** Create `src/Services/FileProvider/Location.swift` defining `enum Location { case local(URL); case remote(hostID: UUID, path: String) }` with helpers for path manipulation that work for both cases. Add a `url` computed property that traps on the remote case so callers must update intentionally.
- [x] **T3** Add a `DETOURS_FILE_PROVIDER` runtime flag in `src/Preferences/Settings.swift` (default off). When off, callers use the existing direct `FileManager` path; when on, they go through `LocalFileProvider`. The dual path code is removed at the end of Phase 5.
- [x] **T4** Create `src/Services/FileProvider/LocalFileProvider.swift` that wraps every existing `FileManager` call site behind the protocol. Method-for-method mapping, no behaviour change.
- [x] **T5** Migrate `src/FileList/FileItem.swift` so the bare `url: URL` field becomes `location: Location`. Add a `url` convenience for the local case to ease the migration. Update both initialisers and the iCloud / shared-folder paths.
- [x] **T6** Route `src/FileList/FileListDataSource.swift` through `FileProvider` when the flag is on: `loadDirectory`, folder size lookups, git status overlay, sort. Preserve NSOutlineView identity across reloads by hashing on `Location` rather than `URL`.
- [x] **T7** Route `src/FileList/FileListViewController.swift` through `FileProvider`. Replace the `MultiDirectoryWatcher` call sites with `provider.watch(location:onChange:)`.
- [x] **T8** Update `src/FileList/MultiDirectoryWatcher.swift` to be the local-only implementation behind `LocalFileProvider.watch`. The remote implementation lands in Phase 3.
- [x] **T9** Route `src/Operations/FileOperationQueue.swift` through `FileProvider`. Gate the fast lane to operations where both source and destination are `Location.local`, regardless of size or count. Add explicit refusal for any `Location.remote` operation in the fast-lane classifier.
- [x] **T10** Route `src/Operations/RenameController.swift`, archive create, archive extract, and trash service through `FileProvider`.
- [x] **T11** Route `src/Services/GitStatusProvider.swift` through `FileProvider`. The local path still runs `git status` via `Process`; the remote path will delegate to the remote helper in Phase 3.
- [x] **T12** Verify the full existing unit and integration test suite passes both with `DETOURS_FILE_PROVIDER=off` and `DETOURS_FILE_PROVIDER=on`. No UI/UX test runs are required for this spec. No new failures, no new skips.

**Phase 2: SSH connection, helper daemon, transfer side-channel, build**

- [x] **T13** Add `src/Remote/SSHConnection.swift` as an actor wrapping `Process(executable: "/usr/bin/ssh")` with `ServerAliveInterval=30`, `ServerAliveCountMax=3`, `ControlMaster=auto`, `ControlPath=~/.detours/ssh/%C`, and length-prefixed framing over stdin/stdout. Create `~/.detours/ssh/` with mode `0700` before the first connection.
- [x] **T14** Add `src/Remote/SSHConnectionState.swift` with state machine: `disconnected`, `connecting`, `connected`, `reconnecting`, `failed(reason)`. Exponential backoff (1, 2, 4, 8, 16 s) on transient drops, capped at sixty seconds total. Post `Notification.Name` events for state transitions so the sidebar can update the status dot.
- [x] **T15** Add `src/Remote/Protocol/RPCMessage.swift` and `src/Remote/Protocol/RPCStreamHandler.swift` for length-prefixed binary framing, request/response ID tracking, and streamed multi-frame responses (used for directory chunks and inotify events).
- [x] **T16** Add `src/Remote/Protocol/Messages.swift` defining every typed RPC message: `List`, `Stat`, `Copy` (RPC channel, ≤1 MB), `Move`, `Rename`, `Delete` (alias for trash), `Trash`, `RestoreFromTrash`, `MkDir`, `ReadSymlink`, `FolderSize`, `GitStatus`, `ArchiveCreate`, `ArchiveExtract`, `Watch`, `Unwatch`, `WatchEvent`, `ProtocolVersion`. Filenames carried as length-prefixed byte arrays.
- [x] **T17** Add `src/Remote/RemoteTransferChannel.swift` for transfers larger than one megabyte. Spawn a second `ssh` session reusing the SSH master via `ControlPath`, invoke the installed helper in transfer mode, carry source and destination paths as length-prefixed byte arrays, stream bytes with progress frames, write to `<destination>.detours-partial`, atomically rename on success, and delete the partial on cancel or disconnect.
- [x] **T18** Create `Server/` top-level directory and a Swift Package target `detours-server` with `linux` platform constraint. Files: `main.swift`, `Daemon.swift`, `RPCHandler.swift`, `TransferMode.swift`, `FileOperations.swift`, `UnixSocket.swift`.
- [x] **T19** Add `resources/scripts/build-server-linux.sh` that cross-compiles the `detours-server` target inside a reproducible Swift Linux Docker container on `dockerhost`. Output: `Resources/Servers/detours-server-x86_64-linux`. Writes the source-tree hash to `Resources/Servers/.cache-hash`.
- [x] **T20** Update `resources/scripts/build.sh` to hash `Server/` and the server-target lines of `Package.swift`, compare to `Resources/Servers/.cache-hash`, and invoke `build-server-linux.sh` only on mismatch. Refuse to ship if the binary is missing. Codesign step picks up the resource automatically. Plain-language error when dockerhost is unreachable but a rebuild is needed.
- [x] **T21** Add `src/Remote/ServerDeployer.swift`: detect `uname -sm` on remote, refuse with a typed `UnsupportedArchitectureError` for anything other than x86_64 Linux, hash-compare against the bundled binary, atomically copy to `~/.detours-server/detours-server.tmp` then rename to `~/.detours-server/detours-server`, owner-and-permission check before every exec. On hash mismatch with an already-installed binary, silently redeploy.
- [x] **T22** Add `src/Remote/RemoteHost.swift` (model: `id: UUID`, `displayName`, `sshTarget`, `knownHostKeyFingerprint`, `lastConnected`) and `src/Remote/RemoteHostStore.swift` persisting hosts in `UserDefaults`. No Keychain item: authentication is delegated to ssh-agent.
- [x] **T23** Add `src/Remote/SSHHostTrust.swift` and `src/Remote/SSHAskPassBridge.swift` to use app-scoped `~/.detours/known_hosts`, show only host-key prompts inside Detours, reject password, keyboard-interactive, and private-key passphrase prompts, and record trusted fingerprints after the user confirms.

**Phase 3: Remote FileProvider, sidebar, connect UX**

- [x] **T24** Add `src/Services/FileProvider/RemoteFileProvider.swift` implementing `FileProvider` over RPC. `list` returns an `AsyncSequence` of directory chunks so the data source can render the first entries immediately. Transfers route through `RemoteTransferChannel` for sizes above one megabyte.
- [x] **T25** Add `Server/Watcher.swift` using Linux inotify. Register watches only for currently-visible directories. Surface `ENOSPC` as a typed server error for the client polling fallback in T40.
- [x] **T26** Add `Server/GitOperations.swift` shelling to `git status --porcelain` and parsing the result into the same `GitStatus` model the local path uses.
- [x] **T27** Add `Server/FolderSizeOperations.swift` computing folder sizes via `du -sb`, with the same stale-while-revalidate cache semantics as the local path. Initial calculation renders `—` in the cell; cached values stay visible while a recalculation runs.
- [x] **T28** Add `src/Sidebar/RemoteHostsSection.swift` and update `src/Sidebar/SidebarViewController.swift` and `src/Sidebar/SidebarItem.swift` with a new Remote Hosts section placed above the Network section. Each host row shows display name, SSH target as a subtitle, and a status dot.
- [x] **T29** Update `src/Sidebar/SidebarItemView.swift` to render the status dot in four colours: green (connected), yellow (connecting or reconnecting), grey (disconnected), red (error). Tooltip shows the last error message when red.
- [x] **T30** Add `src/Sidebar/AddRemoteHostView.swift` (SwiftUI sheet) with fields for display name and SSH target, autocomplete suggestions from `~/.ssh/config` top-level `Host` blocks (ignoring `Match` and conditional includes), a Test Connection button, and the first-connect host-key fingerprint confirmation step.
- [x] **T31** Add the host-key-change blocking dialog: on connect, if the server's host key fingerprint differs from the stored `knownHostKeyFingerprint`, show old and new fingerprints with two choices: Trust New Key (updates the stored fingerprint) or Disconnect.
- [x] **T32** Add the first-connect deploy sheet in `src/Sidebar/DeploySheetView.swift`: modal, titled with the host name, with checkmark-able steps (Connecting, Checking host architecture, Installing helper, Starting helper, Done) and a Cancel button.
- [x] **T33** Add `src/Sidebar/ConnectionErrorSheet.swift`: plain-language summary, "Show Details" disclosure with raw ssh stderr and last fifty lines of daemon stderr, "Copy to Clipboard" button.
- [x] **T34** Add the remote-pane breadcrumb host badge in `src/Panes/BreadcrumbView.swift` (or equivalent): coloured pill with the host display name as the leftmost element of the breadcrumb. File rows are not modified.

**Phase 4: Remote operations, trash, watching, navigation, edges**

- [x] **T35** Add `Server/TrashOperations.swift` implementing FreeDesktop trash at `~/.local/share/Trash` with mode `0700`. Each trashed item writes a `.trashinfo` companion file before moving the file into `files/`, and restore reads the original location from `.trashinfo` rather than from the trash filename. Restore RPC canonicalises the destination path and refuses to restore outside `$HOME`.
- [x] **T36** Add `Server/ArchiveOperations.swift` that creates and extracts ZIP, TAR, and 7Z archives using the remote host tools `zip`, `unzip`, `tar`, `xz`, and `7z`. Mirror the local archive operations' progress reporting through streamed RPC frames. Missing tools surface a plain-language error naming the tool and leave source files unchanged.
- [x] **T37** Wire Undo through the trash and restore RPCs in `src/Operations/`: a remote delete records the trash entry path and the original location; Cmd-Z restores via `RestoreFromTrash`.
- [x] **T38** Add the one-time remote-trash explainer in `src/Operations/`. Dismissed via a checkbox. Retrievable from the Help menu via a new "About Remote Trash" item in `src/App/MainMenu.swift`.
- [x] **T39** Add `src/Remote/RemoteWatcherClient.swift` that subscribes to streamed `WatchEvent` frames from the daemon and bridges them into the same `onChange(Location)` callback shape that local `FSEventStream` uses.
- [x] **T40** Add `src/Remote/RemoteWatcherPollFallback.swift` for the inotify-ceiling case: when the daemon surfaces `ENOSPC`, the client polls visible directories every ten seconds until the user dismisses the inotify banner or raises the limit.
- [x] **T41** Update `src/Navigation/` (Cmd-P quick nav, history, frecency) to store `Location` values anchored to `hostID`. Remote entries render with the host's current display name and are dimmed when the host is not connected.
- [x] **T42** Implement Open With round-trip in `src/FileList/FileOpenHelper.swift`: download remote file to `~/Library/Caches/Detours/remote/<hostHash>/<sessionID>/` (mode `0700`), record SHA256 and mtime, open via `NSWorkspace`, watch the local copy with `FSEventStream`, upload on save. On upload, recompute the remote SHA256 and mtime via daemon RPC; if either has changed, show a conflict dialog with Keep Mine, Keep Remote, Cancel and text naming whether the mismatch is content, timestamp, or both.
- [x] **T43** Implement remote drag-out in `src/FileList/FileListViewController+DragDrop.swift` using `NSFilePromiseProvider` to materialise the file to a per-session `~/Library/Caches/Detours/remote/<hostHash>/<sessionID>/` directory with progress and cancel.
- [x] **T44** Implement Quick Look on remote in `src/FileList/FileOpenHelper.swift`: download on Space key press only. Files under one megabyte download silently. Files between one and one hundred megabytes show a determinate progress indicator inside the Quick Look panel. Files over one hundred megabytes show a plain-language too-large message and do not initiate a download.
- [x] **T45** Add symlink handling on remote: server-side `ReadSymlink` RPC, client renders link badge in `src/FileList/FileListCell.swift`, double-click follows resolved targets, broken-link error shown in plain language.
- [x] **T46** Add permission-denied rendering: server-side `Stat` surfaces a permission flag; client renders the row greyed with a lock badge in `src/FileList/FileListCell.swift`. Attempting operations surfaces a plain-language permission-denied error naming the file.
- [x] **T47** Add non-UTF-8 filename rendering: client converts length-prefixed byte arrays to display strings using a lossy decode that substitutes U+FFFD for invalid sequences; operations on those files use the original raw bytes through to the daemon.

**Phase 5: Lifecycle, polish, flag removal**

- [x] **T48** Add idle disconnect in `SSHConnection`: closes the connection after five minutes with no active pane on the host, no in-flight operation, and no active watch. Reconnects automatically on next interaction.
- [x] **T49** Add the reconnect banner UI in `src/Panes/PaneViewController.swift`: a non-blocking strip above the file list naming the host and a Reconnect button. Banner appears when the connection state transitions to `failed` after the backoff window.
- [x] **T50** Update `src/Operations/FileOperationQueue.swift` so queued remote operations pause when the connection drops (queue surface: "Paused — waiting for [host]") and resume automatically on reconnect. In-progress transfers at the drop have their partial deleted and requeue from the start.
- [x] **T51** Update `src/Sidebar/SidebarViewController.swift` so removing a host while a pane is viewing it navigates that pane back to its previous local location, falling back to the home directory if no previous local location exists.
- [x] **T52** Use the cache directory sanitisation helpers in `src/Remote/RemoteHost.swift` everywhere a local cache directory is created from a host or path.
- [x] **T53** Add `resources/docs/remote-vm-browsing.md` documenting supported `~/.ssh/config` directives, the remote trash location, the helper binary install location, how to manually remove the helper from a host, and how to manually empty the remote trash.
- [x] **T54** Remove the `DETOURS_FILE_PROVIDER` feature flag and the legacy direct-`FileManager` code path. Verify the full test suite passes with the flag removed.
- [x] **T54A** Keep the VM-browsing and NAS/image-mounting workflows distinct in UI and tests: `Add Remote Host...` opens an SSH helper-backed VM pane; `Connect to Network Share...` remains the SMB/NFS/AFP NAS workflow; already-mounted encrypted images remain visible under Devices. No remote-host path may require or suggest an SMB/NFS/AFP share URL.

## ANSIBLE GUY

### Work required on dockerhost

Prepare `dockerhost` for Detours server builds and Linux server tests. The host has Docker running for the deploy user, a current Detours checkout available to the build script, enough free disk for the Swift Linux image and build cache, and network access from Marco's Mac. Apply the host changes through the Ansible repo, restart Docker after daemon or package changes, and confirm the server build and Linux server test environment can run against the service code.

Completed 2026-06-12: `dockerhost` resolves through SSH as `maf@10.10.8.161`, reports Linux x86_64, Docker 29.1.3 is available to the deploy user, and `/` and `/tmp` have 63G free. No Docker restart was needed.

### Work required on devtest

Prepare `devtest` as the x86_64 Linux scratch host for Detours remote integration tests. The host accepts Marco's SSH-agent-backed key auth through the `devtest` SSH target, has a writable per-user Detours test directory, has `git`, `zip`, `unzip`, `tar`, `xz`, and `7z` available for helper operations, and leaves `~/.detours-server/` writable only by the connecting user. Apply the host changes through the Ansible repo, restart sshd after SSH auth changes, and confirm A1, A2, A4, A5, A10, and A15 hold against `devtest`.

Completed 2026-06-12: the Ansible repo now manages `devtest` as `maf@10.10.8.126` with key `/Users/marco/.ssh/id_ed25519_devtest`. `ansible devtest -m ping` passed, `ansible-playbook playbooks/system/linux-base.yml --limit devtest --tags packages` installed the missing archive tools, and direct verification shows `git`, `zip`, `unzip`, `tar`, `xz`, and `7z` on PATH. `~/.detours-server` is owned by `maf` with mode `700`. The rebuilt helper was deployed to `devtest`; SSH byte-stream smoke tests returned `ProtocolVersion` version `1`, listed `/tmp`, and uploaded a small file through the RPC helper with no stderr.

---

## Testing

Tests continue the `T<n>` sequence. Unit tests live in `Tests/`. No UI/UX test tasks are required by this spec. The Linux server tests run inside a Docker container on `dockerhost` via the cross-compile script. Integration tests against a real SSH host gate with `XCTSkipIf` when the host is unreachable and target `devtest` (the project's scratch VM, x86_64 Linux) by default.

### Unit Tests (`Tests/`)

- [x] **T55** `LocationTests.testLocalRoundTrip` - `Location.local(URL)` round-trips through `Codable` and equality.
- [x] **T56** `LocationTests.testRemoteRoundTrip` - `Location.remote(hostID, path)` round-trips through `Codable` and equality.
- [x] **T57** `LocationTests.testPathManipulation` - `appendingPathComponent`, `deletingLastPathComponent`, and `parent` work identically for both cases.
- [x] **T58** `FileItemTests.testIdentityAcrossReloads` - `FileItem` identity hash is stable across reloads for both local and remote `Location`s.
- [x] **T59** `LocalFileProviderTests.testListReturnsExpectedEntries` - `LocalFileProvider.list` returns the same entries as the pre-refactor `FileManager` enumeration for a temp directory tree.
- [x] **T60** `LocalFileProviderTests.testCopyAndMoveBehaviour` - copy and move through the provider behave identically to the pre-refactor implementation.
- [x] **T61** `FeatureFlagTests.testExistingSuiteGreenWithFlagOff` - run the existing unit-test target with `DETOURS_FILE_PROVIDER=off`; assert zero new failures or skips.
- [x] **T62** `FeatureFlagTests.testExistingSuiteGreenWithFlagOn` - run the existing unit-test target with `DETOURS_FILE_PROVIDER=on`; assert zero new failures or skips.
- [x] **T63** `FileOperationQueueTests.testFastLaneRefusesRemoteSource` - any operation with a `Location.remote` source is routed to the queued path, never the fast lane.
- [x] **T64** `FileOperationQueueTests.testFastLaneRefusesRemoteDestination` - any operation with a `Location.remote` destination is routed to the queued path, never the fast lane.
- [x] **T65** `RPCStreamHandlerTests.testLengthPrefixEncoding` - frames encode and decode round-trip for empty, small, and 1MB payloads.
- [x] **T66** `RPCStreamHandlerTests.testPartialReadReassembly` - frames delivered in arbitrary byte-chunk sizes reassemble correctly.
- [x] **T67** `RPCStreamHandlerTests.testOversizedFrameRejected` - a frame above the configured maximum is rejected with a typed error and the connection is marked failed.
- [x] **T68** `RPCStreamHandlerTests.testStreamedDirectoryChunks` - multi-frame responses for a single request ID assemble in order regardless of interleaved unrelated frames.
- [x] **T69** `RPCStreamHandlerTests.testOutOfOrderResponseIDs` - responses arriving out of order match their original requests by ID.
- [x] **T70** `MessagesTests.testEveryMessageRoundTrips` - every message type in `Messages.swift` round-trips through binary encoding, including filenames as length-prefixed byte arrays.
- [x] **T71** `RemoteTransferChannelTests.testPartialFileDeletedOnCancel` - cancelling a transfer mid-stream deletes `<dest>.detours-partial` and leaves no file at the destination under the final name.
- [x] **T72** `RemoteTransferChannelTests.testAtomicRenameOnSuccess` - a completed transfer renames `<dest>.detours-partial` to the final name only after the byte count matches.
- [x] **T73** `RemoteTransferChannelTests.testThresholdRoutesSmallToRPC` - transfers under one megabyte route through the RPC channel, not the helper transfer channel.
- [x] **T74** `RemoteTransferChannelTests.testNonUTF8PathTransfersWithRawBytes` - a large file whose remote name contains invalid UTF-8 transfers through length-prefixed bytes without converting the path to a shell string.
- [x] **T75** `SSHConnectionTests.testControlPathDirectoryMode0700` - first connection creates `~/.detours/ssh/` with mode `0700` before creating the ControlMaster socket.
- [x] **T76** `SSHHostTrustTests.testHostKeyPromptRecordsFingerprint` - a first-connect host-key prompt records the confirmed fingerprint in `~/.detours/known_hosts` before any directory listing request is sent.
- [x] **T77** `SSHHostTrustTests.testPassphrasePromptRejected` - a private-key passphrase prompt is rejected and surfaced as an SSH-agent setup error, not answered by Detours.
- [x] **T78** `ServerDeployerTests.testHashCompareSkipsRedeploy` - deploy is skipped when the remote binary's hash matches the bundled binary.
- [x] **T79** `ServerDeployerTests.testSilentRedeployOnHashMismatch` - hash mismatch with an existing remote binary triggers an automatic redeploy with no user prompt.
- [x] **T80** `ServerDeployerTests.testRefusesNonX86_64` - `uname -sm` returning an ARM or non-Linux architecture surfaces a typed `UnsupportedArchitectureError` before any deploy.
- [x] **T81** `ServerDeployerTests.testRefusesWrongOwner` - exec is refused when the binary on the remote is owned by a user other than the current SSH user.
- [x] **T82** `ServerDeployerTests.testRefusesGroupOrWorldWritable` - exec is refused when permissions on the binary are group- or world-writable.
- [x] **T83** `ServerDeployerTests.testAtomicRenameDeploy` - deploy writes to a temp name and renames into place; a deploy interrupted before the rename leaves no stale partial binary visible to a subsequent connect.
- [x] **T84** `SSHConnectionStateTests.testExponentialBackoffSequence` - simulated drops trigger reconnect attempts at 1, 2, 4, 8, 16 seconds; total backoff capped at sixty seconds.
- [x] **T85** `SSHConnectionStateTests.testFailedStateAfterMaxBackoff` - after the backoff window expires without success the state transitions to `failed(reason)` and the Reconnect banner is shown.
- [x] **T86** `SSHConnectionStateTests.testFailedStateOnAuthError` - auth failure transitions directly to `failed(reason: .authentication)` and does not retry.
- [x] **T87** `SSHConnectionStateTests.testWatchTokensReregisterOnReconnect` - watches established before a drop re-register on successful reconnect with no caller intervention.
- [x] **T88** `SSHConnectionStateTests.testIdleDisconnectAfterFiveMinutes` - with no active pane, no in-flight op, and no active watch, the connection closes after five minutes and reconnects on next interaction.
- [x] **T89** `RemoteHostStoreTests.testPersistAcrossRelaunch` - hosts added to the store survive an `UserDefaults` reset round-trip.
- [x] **T90** `RemoteHostTests.testCacheDirSanitisation` - a host display name or SSH target containing shell metacharacters produces a cache directory name that never contains the raw characters.
- [x] **T91** `RemoteHostTests.testFrecencyAnchorsOnHostID` - renaming a host display name preserves the existing Cmd-P frecency entries and re-renders them with the new label.
- [x] **T92** `SSHConfigParserTests.testSuggestsTopLevelHosts` - parser returns top-level `Host` blocks from a fixture `~/.ssh/config` and ignores `Match` blocks and conditional `Include` directives.
- [x] **T93** `BuildCacheTests.testHashTriggersRebuildWhenSourceChanges` - `build.sh` hashes `Server/` and the server-target lines of `Package.swift`; modifying `Server/` invalidates the cache and triggers a rebuild; modifying unrelated Mac code does not.
- [x] **T94** `OpenWithConflictTests.testHashMismatchSurfacesConflict` - changing the remote file's contents between download and save triggers the conflict dialog.
- [x] **T95** `OpenWithConflictTests.testMtimeMismatchSurfacesConflict` - touching the remote file (mtime change without content change) between download and save triggers the conflict dialog.
- [x] **T96** `OpenWithConflictTests.testCleanRoundtripUploads` - unchanged remote between download and save uploads without prompting.
- [x] **T97** `NonUTF8FilenameTests.testRenderUsesReplacementGlyph` - invalid byte sequences in remote filenames render with U+FFFD in the UI.
- [x] **T98** `NonUTF8FilenameTests.testOperationsActOnRawBytes` - copy and rename on a file with invalid-UTF-8 name complete using the original raw bytes.
- [x] **T99** `DisconnectedQueueTests.testQueuePausesOnDrop` - a queued copy targeting a host whose connection drops transitions to paused state in the queue UI.
- [x] **T100** `DisconnectedQueueTests.testQueueResumesOnReconnect` - a paused operation auto-resumes once the connection is restored.
- [x] **T101** `DisconnectedQueueTests.testInProgressOpRequeues` - an in-progress transfer at the moment of a drop has its partial file deleted and the operation requeues from the start.

### Linux Server Tests (`Server/Tests/`, run via Docker on dockerhost)

- [x] **T102** `FileOperationsServerTests.testListReturnsExpectedEntries` - server `List` returns the same entries as `ls -la` for a fixture directory.
- [x] **T103** `FileOperationsServerTests.testStreamedListChunks` - a 50,000-entry directory produces multiple chunks; the first chunk arrives before the last.
- [x] **T104** `TrashOperationsServerTests.testTrashCreatesCorrectTrashInfo` - trashing a file creates `~/.local/share/Trash/files/<name>` and `~/.local/share/Trash/info/<name>.trashinfo` with the correct original path.
- [x] **T105** `TrashOperationsServerTests.testRestoreRefusesPathOutsideHome` - a restore RPC with a target outside `$HOME` returns a typed error and does not move the file.
- [x] **T106** `TrashOperationsServerTests.testRestoreToOriginalLocation` - restore puts the file back at the original path recorded in `.trashinfo`.
- [x] **T107** `WatcherServerTests.testInotifyEventForCreate` - creating a file inside a watched directory produces a `WatchEvent` frame.
- [x] **T108** `WatcherServerTests.testSurviveDirectoryRename` - renaming a watched directory does not crash the daemon and re-emits the watch on the new path.
- [x] **T109** `WatcherServerTests.testInotifyCeilingSurfacesTypedError` - simulating an `ENOSPC` from `inotify_add_watch` surfaces a typed RPC error to the client.
- [x] **T110** `GitOperationsServerTests.testGitStatusOverlay` - `git status` against a fixture repo returns the same set of marked paths the local implementation does.
- [x] **T111** `FolderSizeServerTests.testStaleWhileRevalidate` - the cached size is returned immediately on a list while a background recompute runs; the cache updates without a placeholder flash.
- [x] **T112** `ArchiveOperationsServerTests.testMissingArchiveToolSurfacesError` - when `7z` is unavailable on the remote host, a 7Z archive request returns a typed missing-tool error naming `7z` and leaves source files unchanged.

### Integration Tests (`Tests/Integration/`, gated on devtest reachability)

- [x] **T113** `RemoteIntegrationTests.testListDirectoryReturnsExpectedEntries` - connect to `devtest`, list `/etc`, assert at least one expected file is present.
- [x] **T114** `RemoteIntegrationTests.testCopyRemoteToLocal` - copy a remote fixture file into a local temp directory; assert byte-equality.
- [x] **T115** `RemoteIntegrationTests.testCopyLocalToRemote` - copy a local fixture file into a remote temp directory; assert byte-equality via the daemon's `Stat`.
- [ ] **T116** `RemoteIntegrationTests.testLargeTransferUsesRemoteTransferChannel` - a 100 MB copy completes via the helper transfer channel without blocking a concurrent directory listing on the same host.
- [ ] **T117** `RemoteIntegrationTests.testWatchDirectoryReceivesInotifyEvent` - watch a remote directory, touch a file inside it via the daemon, assert a `WatchEvent` arrives within two seconds.
- [x] **T118** `RemoteIntegrationTests.testTrashAndRestore` - trash a remote file, assert it is no longer at the original path, run Undo, assert it is restored.
- [x] **T119** `RemoteIntegrationTests.testGitStatusOverlay` - clone a fixture repo into a remote temp directory, modify a file, list the directory, assert the modified file carries a `modified` git status marker.
- [ ] **T120** `RemoteIntegrationTests.testReconnectAfterIdle` - establish a connection, force idle past `ServerAliveInterval * ServerAliveCountMax`, then perform a list; assert the reconnect state machine recovers and the list succeeds.
- [ ] **T121** `RemoteIntegrationTests.testHostKeyChangeBlocks` - connect once and record the fingerprint, swap the host's host key fixture, attempt to reconnect, assert the connection is blocked and the host-key-change dialog event is fired.
- [ ] **T122** `RemoteIntegrationTests.testUnsupportedArchitectureError` - connect to a fixture host reporting `uname -sm` as `aarch64`, assert a typed error naming the architecture and no deploy attempt.
- [x] **T123** `RemoteIntegrationTests.testSymlinkFollowsResolvable` - a directory listing includes a symlink with the link badge; double-click resolves and navigates into the target.
- [ ] **T124** `RemoteIntegrationTests.testSymlinkBrokenShowsError` - a symlink to a non-existent target shows a plain-language broken-link error.
- [x] **T125** `RemoteIntegrationTests.testPermissionDeniedRendersLockBadge` - listing a directory containing a file the user cannot read renders that file's row with a lock badge.

### UI/UX Tests

No UI/UX test tasks are required for this spec.
