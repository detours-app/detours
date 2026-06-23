# Remote-Aware Quick Open (Command-P) Search

## Meta

- Status: Implemented
- Branch: feature/remote-quick-open-search

---

## Business

### Goal

Make Command-P (Quick Open) search the right place. Today it always searches the Mac, even when you are looking at a folder on a remote server. After this change, when the active tab is showing a remote server, Command-P searches that server; when the active tab is a local folder, it searches the Mac exactly as it does now.

### Proposal

When you press Command-P in a remote tab, Detours searches the whole remote server for files whose names match what you type, and shows clearly at the top of the search box that you are searching that server rather than your Mac.

### Behaviors

- **Command-P scope follows the active tab.** A local tab searches the Mac (unchanged). A remote tab searches the remote server. There is no toggle to switch scope; it always matches the tab you are in.
- **Scope is always shown.** The search panel has a line, visible the moment it opens and while you type, that states what is being searched: "This Mac" for a local tab, or a globe symbol followed by "Searching <server name> — entire host" for a remote tab.
- **Remote search covers the entire server.** It looks across the whole server, beginning with your home folder and `/opt` so the most likely matches appear first, then the rest of the server. It matches against file and folder names (case-insensitive), not file contents.
- **Results stream in.** Matches appear as the server finds them rather than after a long wait. Typing a new character starts a fresh search and abandons the previous one.
- **Recent remote places still appear.** In a connected remote tab, previously visited remote locations for that server (history) show alongside the live results, the same way recent local places appear for a local tab.
- **Picking a result opens it in the current tab.** Choosing a file moves the current tab to the folder that contains it and selects it; choosing a folder enters it. This matches how Command-P already behaves for local results.
- **Disconnected server shows a way back.** If the active tab points at a server whose connection has dropped, Command-P shows a single "Reconnect to <server name>" action instead of searching. Opening Command-P never silently reconnects on its own and never quietly searches the Mac instead.

### Acceptance Criteria

- [x] **A1** In a local tab, Command-P behaves exactly as before and the scope line reads "This Mac".
- [x] **A2** In a connected remote tab, the scope line shows a globe and "Searching <server name> — entire host" while the panel is empty and while typing.
- [x] **A3** Typing in a connected remote tab returns matching files and folders from across the server, with home-folder and `/opt` matches appearing first.
- [x] **A4** Matches appear progressively as the server finds them, and a long search does not freeze the panel or block other actions in the tab.
- [x] **A5** Choosing a remote file moves the current tab to its containing folder and selects it; choosing a remote folder enters it.
- [x] **A6** In a connected remote tab, recently visited remote locations for that server appear alongside live results.
- [x] **A7** In a remote tab whose connection has dropped, Command-P shows a "Reconnect to <server name>" action and performs no search; it never searches the Mac in this case.
- [x] **A8** Remote search matches file and folder names case-insensitively and does not search file contents.
- [x] **A9** Remote search never returns entries from `/proc`, `/sys`, or `/dev`, and never errors out when it encounters folders it cannot read.

### Out of scope

- Searching the contents of remote files (only names are matched).
- A control to search the Mac while in a remote tab, or to search a server while in a local tab.
- Changing how local Command-P search works (frecency, scoped walk, Spotlight all stay as they are).
- A persistent server-side search index (each search is a fresh traversal).

---

## Technical

### Approach

The remote file stack already exposes a `FileProvider` protocol over a `Location` enum (`.local(URL)` / `.remote(hostID:path:)`), with `RemoteFileProvider` (an actor) talking to a bundled helper binary (`detours-server`) over SSH using a chunked request/response RPC. The helper is redeployed automatically: `ServerDeployer.deployIfNeeded()` hash-checks the installed copy on every connect and re-uploads on mismatch. There is therefore no protocol negotiation or fallback to build — rebuilding the helper with a new `find` command ships it to every host on the next connection.

Work splits into four parts:

- **New `find` RPC.** Add a `find` case to the client protocol (`enum RPCMessage`, `src/Remote/Protocol/Messages.swift`) and the mirror server protocol (`enum ServerRPCMessage`, `Server/ServerRPCProtocol.swift`), carrying the query string and a result cap. The priority roots (`$HOME`, `/opt`) are determined server-side from the helper's own environment, not sent over the wire, because the client cannot reliably know the remote home path. Results stream back as the existing chunked response envelopes (`ServerRPCEnvelope` with `sequence`/`isFinal`), one chunk per batch of matches.
- **Server-side traversal.** Implement the name search in the helper (`Server/FindOperations.swift`, invoked from `Server/RPCHandler.swift`) by shelling out to the system `find` tool, not a hand-rolled walk: `find(1)` is dramatically faster and more complete on a large host (a Swift traversal burns its time budget inside `~/Library` and toolchain caches before reaching real content, returning false "No matches"). Run `find` over the priority roots (`$HOME` read from the server environment, then `/opt`) first and flush those matches immediately, then over the rest of the root filesystem with the priority roots pruned out. Skip hidden entries (caches, dotdirs) and `node_modules`, prune the pseudo filesystems (`/proc`, `/sys`, `/dev`) and external mounts (`/Volumes`, `/mnt`, `/media`, `/net`); `find` does not follow symlinked directories and its permission-denied errors are ignored. Stop at the result cap (1000) or an internal time budget (20s), whichever comes first. Stream matches in batches via the helper's response envelopes as `find` reports them.
- **Client provider entry point.** Add `find(query:cap:)` to the `FileProvider` protocol; implement it in `RemoteFileProvider` and as an unsupported no-op in `LocalFileProvider` (local search keeps using Spotlight + the scoped walk). The remote `find` runs on a dedicated, killable `ssh` process (`RemoteSearchChannel`, reusing the connection's control master) rather than the shared persistent RPC connection, so a whole-host search never blocks other operations and can be abandoned instantly; results are yielded as a streamed `AsyncThrowingStream` of `Location` batches.
- **Quick Open wiring and UI.** `MainSplitViewController.showQuickNav()` currently passes `searchRoots: [tab.currentDirectory]` (always local) and never passes `onSelectLocation`. Change it to detect the active tab's location: for a remote tab pass the remote host + provider and the `onSelectLocation` reveal callback; for a local tab keep today's behavior. `QuickNavController.show(...)` must forward `onSelectLocation` (it already exists on `QuickNavView` but the controller drops it) and a scope descriptor. `QuickNavView` renders the persistent scope header and, when remote, branches `performSearch()` to call the provider's streaming `find` (debounced ~150ms, cancelling the in-flight task on each keystroke) instead of `localMatches()` + Spotlight, merging live results with remote frecency from `FrecencyStore.frecencyLocationMatches` scoped to the active host. A disconnected remote tab renders the "Reconnect to <host>" affordance and runs no search.

Selecting a remote result reveals it in the current tab by navigating the active pane to the parent path and selecting the item, reusing the remote navigation path (`FileListViewController.loadRemoteDirectory(host:path:provider:)`); directory results navigate into the directory.

### Approach Validation

The design mirrors patterns already proven in this codebase rather than importing an external one: per-host actor providers, the auto-deploy helper, and the separate `ssh` process channel (as `RemoteTransferChannel` already does for transfers). Two deliberate decisions:

- **Use the OS `find`, not a hand-rolled walk.** Searching a Unix host for filenames is exactly what `find(1)` does, fast and completely. An earlier hand-rolled Swift traversal was both slow and order-unlucky on a real host (20s budget exhausted in `~/Library`/caches before reaching the target), so it was replaced with `find`. Whole-host coverage with home/`/opt` first is achieved by running `find` over those roots first, then the rest of the filesystem with them pruned; external/network mounts and pseudo filesystems are pruned by path.
- **Killable search process instead of in-flight RPC cancel.** Each search runs as its own short-lived `ssh` process, so the persistent connection is never blocked and a superseded search is killed outright (the client cancels the stream, which terminates the process). Combined with ~150ms debouncing and honoring only the latest search, this gives responsive, pile-up-free search and is what makes A4 hold. Matches stream as `find` reports them, so home results appear in ~1s while the whole-host pass continues in the background.

No meaningful external user-feedback corpus exists for "remote search in a niche dual-pane macOS file manager"; the closest competitors (Marta, Commander One) do not offer server-side find, so the bar is internal consistency with local Command-P, which this follows.

### Risks

| Risk | Mitigation |
| ---- | ---------- |
| A slow whole-host `find` blocks other RPCs on the shared connection | Search runs on its own short-lived `ssh` process (`RemoteSearchChannel`), never the persistent connection; bounded by a 1000-match cap and a 20s time budget, and streamed |
| Stale results from a previous keystroke overwrite newer ones | Client debounces ~150ms and renders only the latest search; an earlier search's `ssh` process is terminated when its stream is cancelled |
| Whole-host traversal floods with noise or errors | `find` prunes hidden entries (caches/dotdirs), `node_modules`, `/proc`, `/sys`, `/dev`, and external mounts; does not follow symlinked directories; permission errors go to its stderr |
| Server returns paths with non-UTF8 bytes | Reuse the existing byte-exact `ServerRemotePath` wire handling; decode lossily only for display, consistent with `list` |
| User cannot tell scope changed per tab | Persistent, always-visible scope header in the panel (A1, A2) |
| Helper on a host predates `find` | Not possible in practice: `ServerDeployer.deployIfNeeded()` re-uploads the bundled helper on hash mismatch at every connect, so the new helper ships with the app |

### Implementation Plan

**Phase 1: RPC protocol**

- [x] **T1** Add a `find(query:cap:)` case to `enum RPCMessage` in `src/Remote/Protocol/Messages.swift` with a new wire tag, plus binary encode/decode (query as UTF-8 `Data`, cap as `Int64`). Priority roots are not carried on the wire; the server derives them from its own environment.
- [x] **T2** Add the mirror `find(query:cap:)` case to `enum ServerRPCMessage` in `Server/ServerRPCProtocol.swift` with the same tag and matching binary encode/decode.
- [x] **T3** Define the find result chunk encoding (a batch of matched absolute paths with is-directory flags) reusing the existing file-entry/byte-exact path encoders so client and server agree; place shared shape alongside the existing entry encoders.

**Phase 2: Server-side traversal**

- [x] **T4** Create `Server/FindOperations.swift` implementing whole-host name search: read `$HOME` from the server environment, traverse `$HOME` then `/opt` first (each single-filesystem), then the remainder of the root filesystem, de-duplicating already-covered paths; case-insensitive substring match on the entry name; prune `/proc`, `/sys`, `/dev`, `.git`, `node_modules`; do not follow symlinks; swallow permission-denied errors; stop at the 500-match result cap or the 5-second internal time budget, whichever comes first; yield matches in batches.
- [x] **T5** Wire `find` into `Server/RPCHandler.swift` `handleChunks`/streaming path so each batch from `FindOperations` is written as a `ServerRPCEnvelope` chunk (`sequence` incrementing, `isFinal` on the last), keeping the daemon serving after completion or error.

**Phase 3: Client provider**

- [x] **T6** Add `func find(query:cap:) -> AsyncThrowingStream<[QuickNavResult]>` (or equivalent streamed-location result) to the `FileProvider` protocol in `src/Services/FileProvider/FileProvider.swift`.
- [x] **T7** Implement `find` in `src/Services/FileProvider/RemoteFileProvider.swift`: issue the `find` RPC for the provider's host, assemble streamed chunks, and yield batches of `.remote(location:host:isConnected:score)` results; map server paths to `Location.remote(hostID:path:)`.
- [x] **T8** Implement `find` in `src/Services/FileProvider/LocalFileProvider.swift` as an explicit unsupported/no-op (local Quick Open continues to use Spotlight + scoped walk; remote `find` is never invoked for local tabs).

**Phase 4: Quick Open wiring and UI**

- [x] **T9** Add a scope descriptor (local vs. remote-with-host, plus connected/disconnected) and thread it, along with `onSelectLocation`, through `QuickNavController.show(...)` in `src/Navigation/QuickNavController.swift` (currently both are dropped).
- [x] **T10** Update `MainSplitViewController.showQuickNav()` in `src/Windows/MainSplitViewController.swift` to read the active tab's location via `fileListViewController.currentRemoteLocation`: for a remote tab pass the host, its `FileProvider`, the scope descriptor, and an `onSelectLocation` reveal callback; for a local tab keep the existing `searchRoots`/`onNavigate`/`onReveal` path.
- [x] **T11** Render the persistent scope header in `src/Navigation/QuickNavView.swift` under the search field: "This Mac" for local, a globe glyph + "Searching <host> — entire host" for remote, visible on empty and typing states. Give it an accessibility identifier (e.g. `quickNavScopeHeader`).
- [x] **T12** Branch `QuickNavView.performSearch()` for remote scope: debounce ~150ms, cancel the in-flight find task on each keystroke, call the provider's streaming `find` with a cap of 500, render chunks of the latest search only, and merge with `FrecencyStore.frecencyLocationMatches` scoped to the active host (pass `remoteHosts: [activeHost]` so only that server's recent locations appear, per A6); skip `localMatches()`/Spotlight when remote.
- [x] **T13** Implement remote result selection in `MainSplitViewController` (the `onSelectLocation` callback): for a file result, navigate the active pane to the parent path and select the item via the remote navigation path (`FileListViewController.loadRemoteDirectory(host:path:provider:)`); for a directory result, navigate into it; record the visit in `FrecencyStore` and return focus to the file list, mirroring `revealItemInActivePane`.
- [x] **T14** Render the disconnected-remote state in `QuickNavView`: when the active tab's host connection is down, show a single "Reconnect to <host>" affordance, run no search and show no history, and trigger the existing reconnect path (`RemoteConnectionRegistry.shared.reconnect(hostID:)`) on activation; never fall back to a local search.
- [x] **T15** Build the app and the helper with `resources/scripts/build.sh` and resolve all `swiftlint lint --quiet` findings.

---

## Testing

Tests are implementation tasks. Numbering continues the `**T<n>**` sequence. Use real temp directories, no mocks, per project rules.

### Unit Tests (`Tests/`)

- [x] **T16** `FindRPCCodecTests.testFindRequestRoundTrips` — `RPCMessage.find` and `ServerRPCMessage.find` encode and decode to identical fields (query, cap) across the client and server codecs.
- [x] **T17** `FindRPCCodecTests.testFindResultChunkRoundTrips` — a batch of matched paths with is-directory flags encodes and decodes byte-exactly, including a path containing non-UTF8 bytes.
- [x] **T18** `FindOperationsTests.testMatchesAreCaseInsensitiveNameSubstring` — given a real temp tree, a query matches file and folder names regardless of case and does not match on file contents.
- [x] **T19** `FindOperationsTests.testPriorityRootsComeFirst` — matches under the home/priority root and `/opt`-style root are yielded before matches elsewhere in the tree.
- [x] **T20** `FindOperationsTests.testPrunesPseudoAndNoiseDirsAndSurvivesUnreadable` — entries under `proc`/`sys`/`dev`-named roots and `.git`/`node_modules` are excluded, an unreadable subdirectory does not abort the search, and symlinks are not followed.
- [x] **T21** `FindOperationsTests.testStopsAtCapAndTimeBudget` — traversal yields no more than the 500-match cap and returns within the 5-second time budget on a large temp tree.

### UI Tests (`Tests/UITests/DetoursUITests/`, run on Foundry)

- [x] **T22** `RemoteQuickOpenUITests.testLocalTabScopeHeader` — in a local tab, opening Quick Open shows the scope header reading "This Mac" (via `quickNavScopeHeader`) and local search behaves as before.
- [x] **T23** `RemoteQuickOpenUITests.testRemoteTabScopeHeader` — in a connected remote tab, the scope header shows the globe + "Searching <host> — entire host" on the empty and typing states.
- [x] **T24** `RemoteQuickOpenUITests.testRemoteResultRevealsInCurrentTab` — choosing a remote result navigates the current tab to the containing folder and selects the item.
- [x] **T25** `RemoteQuickOpenUITests.testDisconnectedRemoteShowsReconnect` — in a remote tab whose connection is down, Quick Open shows the "Reconnect to <host>" affordance and no results, and never shows local results.
