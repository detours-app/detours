# File Opening and Remote Operations

## Meta

- Status: Reviewed
- Branch: fix/file-opening-and-remote-operations

---

## Business

### Goal

Make opening several files and organizing files in remote tabs as dependable and calm as the same work in local tabs.

### Proposal

Open every eligible file in a selection, keep remote folder trees stable while their contents update, and make drag-and-drop and cut-and-paste work consistently across local and remote panes.

### Behaviors

- Enter, Command-O, Command-Down, and Open in the shortcut menu open every selected ordinary file in the order shown in the pane.
- When a selection mixes ordinary files with folders, archives, or disk images, Detours opens the ordinary files and leaves the other items untouched.
- When a selection contains no ordinary files, Open performs the existing action for the focused item, such as entering a folder, extracting an archive, or mounting a disk image.
- Opening more than five files at once first asks for confirmation.
- A problem opening one selected file does not stop the others. Detours finishes the batch and presents one summary naming every file it could not open.
- A remote folder tree stays visible while Detours updates it after a copy, move, rename, paste, or deletion. Expanded folders do not visibly collapse and reopen.
- Remote updates preserve expanded folders, selected items, the visible scroll position, keyboard focus, sorting, and an active filter.
- If a remote update fails, the current contents remain usable and one non-blocking message offers another attempt.
- Files and folders can be dragged within a remote host, between remote hosts, and between local and remote panes.
- A valid destination folder and a valid pane background visibly light up while an item is dragged over them. Invalid destinations show that the drop is not allowed.
- A normal drag moves items within the same local volume or remote host and copies items when crossing a local, remote, or host boundary.
- Holding Option forces a copy. Holding Command forces a move across a boundary. Option takes priority when both keys are held.
- Command-X marks selected remote items as pending moves and dims their rows. The same state is available to people using VoiceOver.
- Command-V pastes into one folder that the user deliberately selected; otherwise it pastes into the folder shown by the tab.
- A folder selected automatically after navigation never redirects a paste. When several folders are selected, the paste goes into the folder shown by the tab.
- A successful cut-and-paste clears the pending move. A failed or cancelled paste keeps it available for another attempt.
- Remote clipboard contents work across Detours tabs and panes during the current app session.

### Acceptance Criteria

- [ ] **A1** Enter, Command-O, Command-Down, and Open in the shortcut menu open every selected ordinary file exactly once and in the order shown.
- [ ] **A2** A mixed selection opens its ordinary files without navigating into folders, extracting archives, or mounting disk images from that selection.
- [ ] **A3** A selection with no ordinary files keeps the focused item's existing Open behavior.
- [ ] **A4** A batch with one or more failures opens the files that can be opened and presents one summary naming all failures.
- [ ] **A5** Copying, moving, renaming, pasting, or deleting in a remote tab never blanks the visible list or visibly collapses and reopens expanded folders.
- [ ] **A6** Remote updates preserve expanded folders, selected items, scroll position, keyboard focus, sorting, filter text, and filter visibility.
- [ ] **A7** A failed remote update leaves the current contents usable and presents one accessible retry message.
- [ ] **A8** Files and folders can be dragged within one remote host, across remote hosts, and in both directions between local and remote panes.
- [ ] **A9** Valid remote destination folders and pane backgrounds show a drop target before release, and invalid destinations never accept the drop.
- [ ] **A10** Dragging moves within one local volume or remote host, copies across boundaries, honors Option for copy, and honors Command for a cross-boundary move.
- [ ] **A11** Command-X on remote items visibly and accessibly marks every selected item as pending move.
- [ ] **A12** Command-V uses one deliberately selected folder or else the folder shown by the tab, without being redirected by an automatic selection.
- [ ] **A13** Successful remote cut-and-paste clears the pending move, while a failed or cancelled paste preserves it for another attempt.
- [ ] **A14** One file operation causes one stable visible update in every open pane showing an affected remote folder.
- [ ] **A15** Dragging a remote file from Detours to another application continues to create the promised file safely.
- [ ] **A16** Single-item Open performs the correct action for the focused item, whether opening a file, mounting a disk image, extracting an archive, or entering a folder, identically across Enter, Command-O, Command-Down, the shortcut menu, and double-click, and local file operations remain unchanged.
- [ ] **A17** When a selection would open more than five ordinary files, Detours first presents one confirmation; opening five or fewer opens without a prompt, and skipped folders, archives, and disk images never count toward the five.

### Out of scope

- Making remote clipboard contents available to other applications.
- Restoring remote clipboard contents after Detours quits.
- Dragging a remote folder from Detours to another application.
- Redesigning file-conflict choices or the transfer activity interface.
- Adding a new direct connection between two remote hosts for transfers.
- Changing remote authentication, connection, or reconnection behavior.

---

## Technical

### Approach

Create one item-opening dispatcher in `src/FileList/` and route `openSelectedItem()`, `openFromContextMenu(_:)`, Command-Down handling, and the single-item double-click path through it, unifying all five entry points on the working double-click classification in `handleDoubleClick(row:)` so Enter and Command-O mount disk images and open files the same way a double-click already does. The dispatcher reads `tableView.selectedRowIndexes`, resolves each visible row through the outline view, and retains that visible order. For a multi-selection it classifies each item, routes ordinary local files through `FileOpenHelper.open`, routes ordinary remote files through `RemoteOpenWithCoordinator` while preserving native-editor detection and download coordination, and skips folders, extractable archives (`CompressionTools.isExtractable`), and disk images (`FileOpenHelper.isDiskImage`). If no ordinary file is eligible, it performs the focused row's single-item action using the double-click behavior: mount a disk image with `FileOpenHelper.openAndMount` and navigate to the mount point, extract an archive, or enter a folder. Before opening more than five files at once, the dispatcher presents one confirmation. Synchronously detectable local failures are collected without stopping the batch, then one accessible error summary names all failed items; asynchronous remote download and launch failures continue to surface through `RemoteOpenWithCoordinator`'s existing per-file error path. Inject the opening collaborators so tests record dispatches without launching external applications.

Add a per-pane remote refresh coordinator in `src/FileList/` that accepts an affected `Location`, a refresh reason, and preferred result locations from completed operations. Normalize file changes to their parent directory and group requests by remote host and directory. Requests for the same directory within the existing 0.1-second directory-change debounce interval become one fetch; a request arriving during an active fetch marks that directory dirty and causes at most one additional fetch. Give each directory a monotonically increasing generation and discard responses older than the last applied generation.

Replace root-wide remote reloads for same-location updates with location-keyed tree reconciliation in `FileListDataSource+Loading.swift` and `FileListDataSource+Expansion.swift`. Fetch a listing while the current tree remains visible, reuse each existing `FileItem` whose `Location` still exists, update its metadata, retain its loaded children and expansion identity, insert new items, and remove missing items in one main-actor update. A change inside an expanded branch reloads that branch only. A change inside a collapsed branch marks its children stale for the next expansion. A broad provider event may refresh the displayed root. A failed listing retains the current tree instead of clearing it.

Before applying a reconciliation, capture selected locations, expanded locations, the top visible location and its pixel offset, horizontal scroll position, keyboard focus, sort state, filter text, and filter visibility. Restore them without calling selection helpers that scroll the first selected row into view. Clamp only when removed rows make the previous position impossible. Use preferred operation results for copy, move, and rename selection; when deletion removes the selection, choose the nearest surviving row without moving an already visible viewport. Keep root and expanded-branch watches registered across same-location refreshes, and diff watch registrations only when branches are expanded, collapsed, removed, navigated away from, or disconnected.

Make internal drag-and-drop location-based. Capture the full selected `[Location]` set at drag start in an app-owned drag session and expose it to another Detours file list while retaining the current `NSFilePromiseProvider` path for external remote-file drag-out. Replace URL-only helpers in `FileListViewController+DragDrop.swift`, `FileListDataSource+OutlineView.swift`, and `FileItem.dropDestination` with current-directory and destination `Location` values. Route accepted drops through the existing `FileOperationQueue` location overloads. Determine same-boundary moves by local volume identity or matching remote host identifier; every other boundary defaults to copy. Option wins over Command. Validate normalized path components to reject self-drops, same-parent no-ops, and folder-to-descendant drops without confusing equal-looking paths on different hosts.

Track selection origin in `FileListViewController+SelectionState.swift` as user, automatic, restored, or operation-result selection. Mouse and keyboard selection changes are user selections; loading, state restoration, and result selection use explicit programmatic scopes. `effectivePasteDestinationLocation` uses a directory only when exactly one selected directory has user origin, otherwise it uses the current displayed location. Extend `ClipboardManager` and `FileListCell` to expose and render cut state by `Location`, including an accessibility description. Clear cut state only after a successful move. Route operation completion and matching watcher events through the refresh coordinator so source and destination panes update once and preserve their view state.

Extend `UITestRemoteProvider` from a listing-only provider into a mutable local-directory-backed remote test surface. Implement copy, move, trash, delete, rename, directory transfers, and watches inside its test root. Add launch-argument-controlled listing gates, deterministic next-call failures, exact changed-parent callbacks, call histories, and test-only state responses for expanded locations, selected locations, top-visible location and offset, focus, active drop target, and refresh-in-flight state. These controls make collapse, flicker, scroll movement, and duplicate refreshes testable without timing guesses.

### Approach Validation

- Apple documents Command-O as opening the selected item, Command-X and Command-V as the standard cut-and-paste commands where an application supports them, and Command-selection as the normal way to select several items. This supports making every Open entry point honor the complete selection and making unavailable clipboard operations visibly unavailable rather than silently ineffective: https://support.apple.com/en-us/102650 and https://support.apple.com/guide/mac-help/select-items-mchlp1378/mac
- Apple's drag guidance establishes Option-drag as copy, while AppKit's drag model separates the visual drag session from the operation accepted by the destination. This supports destination-owned validation, clear highlighting, and modifier-based copy or move behavior: https://support.apple.com/guide/mac-help/drag-and-drop-items-mh35852/mac and https://developer.apple.com/documentation/AppKit/drag-and-drop
- Apple's file-promise API is specifically for files that must be generated after a drag. Keeping it for external remote-file drag-out while using app-owned locations for internal Detours transfers preserves the existing external behavior without forcing internal remote items through local file URLs: https://developer.apple.com/documentation/appkit/nsfilepromiseprovider
- ForkLift and Transmit both treat local and remote panes as direct drag-and-drop transfer surfaces, including subfolder targets and remote-to-remote transfers. Their documented behavior supports parity across Detours pane types rather than a remote-only interaction mode: https://binarynights.com/manual and https://help.panic.com/transmit/transmit5/transfers/
- User feedback describes collapsing an expanded folder path during ordinary file work as destructive to orientation and control. That confirms that preserving the visible tree throughout a refresh is a core outcome rather than cosmetic polish: https://www.reddit.com/r/MacOS/comments/1jw44gj/is_there_a_way_to_preserve_the_finder_path_when/
- Code review found deterministic causes for all four reports: Open reads one selected row; remote refresh replaces the root, reloads the outline, restarts watches, and re-expands branches asynchronously; remote drop validation requires a local directory URL; and remote clipboard locations exist but cut appearance and paste-selection intent remain local-only.
- The rejected refresh alternative was rebuilding a complete expanded snapshot offscreen and swapping it into the outline. Location-keyed branch reconciliation is smaller, retains stable item identity, avoids re-listing unaffected branches, and gives watcher events a precise update target.

### Risks

| Risk | Mitigation |
| --- | --- |
| A large multi-selection opens too many applications or starts many remote downloads at once | Preserve visible ordering, confirm before opening more than five files, and aggregate failures into one result instead of one alert per file |
| A remote event identifies a file or a directory at a different level than the visible branch | Normalize file events to their parent, refresh the nearest loaded ancestor, and use the displayed root only for broad events |
| A slow older listing overwrites a newer mutation result | Track a generation per host and directory and discard every response older than the last applied generation |
| Reusing tree items leaves changed metadata or sorting stale | Update all listing-owned metadata before one sort and outline update, while retaining only identity and loaded child state |
| Scroll restoration fights AppKit selection scrolling | Restore selection without scrolling, then restore the top-visible item, pixel offset, and horizontal origin after row reconciliation |
| Watch and operation notifications still cause repeated network work | Coalesce by host and directory before fetching, keep one active request, and allow only one dirty follow-up |
| A dragged folder is dropped into itself through a differently formatted path | Compare normalized `Location` path components and host identity, and reject self, descendant, and same-parent destinations both during hover and again on acceptance |
| A remote destination disappears or becomes unwritable after hover | Revalidate on acceptance, leave source state untouched on failure, and present one named operation error |
| Programmatic selection is mistaken for deliberate destination choice | Wrap every automatic, restored, and operation-result selection in an explicit origin scope and test each origin |
| Location-based cut state becomes inconsistent with the macOS pasteboard | Keep the existing pasteboard change tracking, store remote locations only for the current Detours session, and clear visual state whenever the owning clipboard entry changes |
| The broader test provider accidentally operates outside its fixture root | Canonicalize every translated path, reject paths outside the configured root, and expose mutable operations only behind `UITestEnvironment` |

### Implementation Plan

**Phase 1: Shared Open Behavior**

- [x] **C1** Add a shared item-opening dispatcher under `src/FileList/` that unifies every Open entry point on the double-click classification, confirms before opening more than five files, and returns per-file batch results.
- [x] **C2** Update `FileListViewController+SelectionState.swift`, `FileListViewController+Keyboard.swift`, `FileListViewController+ContextMenu.swift`, and the double-click path in `FileListViewController+Setup.swift` to use the dispatcher.
- [x] **C3** Add one accessible batch-open error summary that names failed items after every eligible file has been attempted.

**Phase 2: Remote Refresh Coordination**

- [x] **C4** Add a per-pane remote refresh coordinator that normalizes affected locations, coalesces requests, serializes directory fetches, and rejects stale generations.
- [x] **C5** Add location-keyed branch reconciliation to `FileListDataSource+Loading.swift` and `FileListDataSource+Expansion.swift`, reusing unchanged `FileItem` identities and loaded children.
- [x] **C6** Update `FileListViewController+DirectoryLoading.swift` to keep the current remote tree visible during same-location updates and apply one reconciled outline update.
- [x] **C7** Extend `FileListViewController+SelectionState.swift` to preserve expansion, multi-selection, top-visible item and offset, horizontal scroll, focus, sort, and filter state without selection-driven scrolling.
- [x] **C8** Update `FileListViewController+Watching.swift` to retain stable root and branch watches and route changed locations through the refresh coordinator.
- [x] **C9** Route copy, move, rename, paste, and delete completion from `FileListViewController+FileActions.swift` and `MainSplitViewController+Navigation.swift` through affected-directory refresh requests.
- [x] **C10** Add a non-blocking accessible remote refresh error with retry while retaining the last usable tree and view state.

**Phase 3: Location-Based Drag-and-Drop**

- [x] **C11** Add an app-owned internal drag session that captures every selected `Location` while preserving the existing remote-file promise writer for external applications.
- [x] **C12** Replace URL-only current-directory and destination helpers in `FileListViewController+DragDrop.swift`, `FileListDataSource+OutlineView.swift`, and `FileItem.swift` with location-based equivalents.
- [x] **C13** Add location-aware drop validation for writable folder rows and pane backgrounds, including highlight state and self, descendant, regular-file, missing-target, and same-parent rejection.
- [x] **C14** Route accepted multi-file and folder drops through `FileOperationQueue` location operations with same-volume and same-host boundary detection plus Option and Command overrides.
- [x] **C15** Preserve source and destination pane state through drag completion, select visible results, clear drop highlighting, and aggregate operation errors.

**Phase 4: Remote Cut-and-Paste**

- [x] **C16** Extend `ClipboardManager` and `FileListCell` with location-based pending-cut queries, remote row dimming, notifications, and an accessible cut description.
- [x] **C17** Track user, automatic, restored, and operation-result selection origins and update `effectivePasteDestinationLocation` to use only one deliberately selected folder.
- [x] **C18** Keep remote cut state after cancellation or failure, clear it after successful move, retain copied items for repeated paste, and refresh affected panes through the coordinator.

**Phase 5: Deterministic Test Surface and Build**

- [x] **C19** Extend `UITestRemoteProvider` with root-confined mutable operations, watches, controlled listing gates, deterministic failures, call histories, and test-only pane-state responses.
- [x] **C20** Build with `resources/scripts/build.sh` and resolve every build, lint, and warning failure.

---

## Testing

All tests, runtime checks, fixtures, and UI automation run on Foundry only. Spectre is used only for the final install after Foundry verification, following the repository rules.

### Unit Tests (`Tests/`)

- [x] **T1** `FileItemOpeningTests.testEnterOpensEverySelectedOrdinaryFileInVisibleOrder` - Enter dispatches every eligible selected file exactly once without launching external applications.
- [x] **T2** `FileItemOpeningTests.testCommandOpenCommandDownAndContextMenuMatchEnter` - Every Open entry point yields the same ordered batch.
- [x] **T3** `FileItemOpeningTests.testMixedSelectionSkipsSpecialItems` - A mixed selection opens ordinary files and leaves folders, archives, and disk images untouched.
- [x] **T4** `FileItemOpeningTests.testSelectionWithoutOrdinaryFilesUsesFocusedItemAction` - A special-only selection preserves the focused item's single-item behavior.
- [x] **T5** `FileItemOpeningTests.testBatchContinuesAndAggregatesFailures` - Successful files open and all failed names appear in one result.
- [x] **T35** `FileItemOpeningTests.testOpeningMoreThanFiveFilesConfirmsFirst` - Six selected files trigger one confirmation before any open, while five open without a prompt.
- [x] **T6** `RemoteRefreshCoordinatorTests.testTreeRemainsVisibleWhileListingIsHeld` - A gated listing leaves the current root and expanded children present throughout the request.
- [x] **T7** `RemoteRefreshCoordinatorTests.testRefreshPreservesCompletePaneState` - Expansion, selection, scroll origins, focus, sort, and filter state match before and after reconciliation.
- [x] **T8** `RemoteRefreshCoordinatorTests.testChangedExpandedFolderRefreshesOnlyItsBranch` - A branch event lists that branch once without listing the root or unaffected siblings.
- [x] **T9** `RemoteRefreshCoordinatorTests.testMutationAndWatchEventCoalesce` - Operation completion and its matching watch event cause one listing request for each affected directory.
- [x] **T10** `RemoteRefreshCoordinatorTests.testBurstCoalescesByAffectedDirectory` - A callback burst yields one request for each distinct loaded branch.
- [x] **T11** `RemoteRefreshCoordinatorTests.testOlderResponseCannotReplaceNewerContent` - Releasing gated requests in reverse order leaves the newest listing visible.
- [x] **T12** `RemoteRefreshCoordinatorTests.testListingFailureKeepsTreeAndOffersRetry` - A failed refresh preserves content and state, and a retry applies later content.
- [x] **T13** `RemoteRefreshCoordinatorTests.testSameLocationRefreshRetainsWatches` - Root and expanded-branch watches are not removed and re-added during reconciliation.
- [x] **T14** `RemoteRefreshCoordinatorTests.testDeletedSelectionChoosesNearestSurvivorWithoutJump` - Deletion chooses a predictable nearby row and retains a valid viewport.
- [x] **T15** `FileListDragDropTests.testRemoteFolderAndPaneBackgroundAreValidTargets` - Remote folders and the current remote directory expose the expected drop operation and target state.
- [x] **T16** `FileListDragDropTests.testInternalDropRoutesExactLocations` - Acceptance sends every source location and the destination location to the operation queue.
- [x] **T17** `FileListDragDropTests.testBoundaryAndModifierRules` - Local volume identity, remote host identity, Option, Command, and combined modifiers select the approved copy or move operation.
- [x] **T18** `FileListDragDropTests.testInvalidTargetsAreRejectedTwice` - Self, descendant, same-parent, regular-file, and disappeared destinations fail during validation or final acceptance.
- [x] **T19** `FileListCellTests.testDropTargetAndCutStatesAreVisibleAndAccessible` - Drop and pending-cut states have both visual treatment and accessibility descriptions.
- [x] **T20** `ClipboardManagerTests.testRemoteCutLocationsRemainRetryableUntilSuccess` - Remote cut locations survive failure and clear only after a successful move.
- [ ] **T21** `FileListResponderTests.testRemotePasteUsesExplicitFolderOrCurrentDirectory` - User selection chooses one folder while automatic, restored, result, and multiple-folder selections use the displayed directory.
- [ ] **T22** `FileListResponderTests.testRemoteCopyAndCutPasteRouteCorrectOperations` - Copy retains sources and clipboard contents while cut moves sources and clears successful cut state.
- [ ] **T23** `RemoteDragOutTests.testRemoteFileDragStillUsesFilePromiseProvider` - Existing external remote-file drag behavior remains intact.

### Integration Tests (`Tests/`)

- [ ] **T24** `RemoteIntegrationTests.testSameHostCopyAndMoveThroughRealHelper` - Real remote copy and move preserve contents and remove the source only for move.
- [ ] **T25** `RemoteIntegrationTests.testLocalRemoteAndCrossHostFolderTransfers` - File and folder transfers work in both local-remote directions and across remote hosts.
- [ ] **T26** `WindowsRemoteProviderTests.testLocationBasedDragAndPasteRouting` - Windows remote operations receive the exact multi-item source and destination locations.

### UI Tests (`Tests/UITests/DetoursUITests/`)

- [ ] **T27** `MultiFileOpenUITests.testEnterAndCommandOpenDispatchAllSelectedFiles` - Test-only opening records every selected filename for both keyboard paths.
- [ ] **T28** `RemoteFileOperationsUITests.testExpandedTreeNeverDisappearsDuringMutationRefresh` - A held refresh keeps a nested expanded row continuously present until the mutation appears.
- [ ] **T29** `RemoteFileOperationsUITests.testMutationPreservesScrollSelectionFilterAndFocus` - The pane state remains stable and keyboard navigation works immediately after completion.
- [ ] **T30** `RemoteFileOperationsUITests.testRemoteFolderHighlightsAndAcceptsDrop` - A remote folder exposes its drop state during the gesture and receives the item afterward.
- [ ] **T31** `RemoteFileOperationsUITests.testLocalRemoteAndCrossHostDragSemantics` - Cross-pane gestures copy or move files and folders according to boundaries and modifiers.
- [ ] **T32** `RemoteFileOperationsUITests.testRemoteCutNavigateAndPaste` - Command-X, navigation, and Command-V move the item to the intended folder without collapsing the tree.
- [ ] **T33** `RemoteFileOperationsUITests.testFailedPasteKeepsCutFeedbackAndCanRetry` - A forced failure retains the accessible cut state and a second paste succeeds.
- [ ] **T34** `RemoteFileOperationsUITests.testTwoPanesShowingSameRemoteFolderUpdateOnce` - Both matching panes receive one stable update after one operation.

---

## Build Log

- **C1** Added `FileItemOpeningDispatcher`, which classifies items with the established double-click rules, keeps visible input order, confirms batches above five eligible files, skips special items in mixed selections, falls back to the focused special item, and returns ordered success and failure details.
- **C2** Routed Enter, Command-O, Command-Down, context-menu Open, and double-click through the dispatcher. Shared action handling now preserves focused folder, archive, disk-image, local-file, and remote-file behavior, with local launch failures and unavailable remote actions represented as dispatcher results.
- **C3** Added a single post-batch warning that lists every failed filename and its reason after dispatch completes, plus a high-priority accessibility announcement for the failure count.
- **C4** Added a per-pane `RemoteRefreshCoordinator` with normalized host-and-directory keys, file-to-parent normalization, 0.1-second coalescing, one active fetch plus one dirty follow-up per directory, monotonically increasing generations, and stale-response rejection. The controller-owned instance fetches through the active remote provider; reconciliation and error presentation are wired by the following tasks.
- **C5** Added location-keyed root and branch reconciliation. Existing remote `FileItem` objects keep their identity and loaded children while listing-owned metadata updates in place; new and removed locations are reported, results are re-sorted once, and stale collapsed branches fetch through the same reconciliation path on their next expansion.
- **C6** Same-location remote loads now request coordinated reconciliation without cancelling the visible load or clearing the outline. A completed snapshot reconciles the matching root or loaded descendant and performs one outline update while retaining stable tree objects and running pending post-operation selection only after the new listing is applied.
- **C7** Added complete remote pane snapshots and no-scroll restoration for expanded locations, multi-selection, nearest surviving row, top-visible item plus pixel offset, horizontal origin, list or filter focus, sort descriptor, filter text, and filter visibility. Preferred operation results replace the restored selection only when they are visible.
- **C8** Provider watches are now keyed by normalized `Location`, retaining remote host identity and stable root or expanded-branch registrations across refreshes. Collapsing a folder removes only its watch subtree, while remote callbacks request a coalesced refresh for the watched branch and local callbacks retain the existing debounced reload path.
- **C9** Paste, delete, and rename completions now publish exact affected remote directories and preferred results; cross-pane copy and move do the same for every loaded tab in both panes. Matching roots and expanded branches request coordinated mutations, collapsed branches become stale, and local refresh behavior remains on its existing path.
- **C10** Background refresh failures now leave the reconciled tree and pane state untouched and show a compact accessible banner over the pane with the directory, failure reason, and an exact-directory Retry action. A successful retry removes the banner; no modal or full-list error overlay is used.
- **C11** Added an app-owned internal drag token and registry. AppKit's full dragged `FileItem` set is captured as ordered `Location` values when a session begins and removed when it ends, while local URL writers and the existing remote `NSFilePromiseProvider` remain the external drag representations.
- **C12** Replaced URL-only drag helpers with location-based current folders, row destinations, source sets, and operation calls. Remote directories now remain valid destinations with host identity intact; local Finder aliases still resolve to local locations, and external file promises require a concrete local destination URL.
- **C13** Added a host-aware `FileDropValidator` used during hover and acceptance. Writable folder rows and pane backgrounds now expose distinct target highlights, while regular files, missing rows, unwritable folders, self and descendant drops, same-parent no-ops, and remote paths on the wrong host are rejected consistently.
- **C14** Added one drop-operation resolver shared by hover and acceptance. Every source and folder is routed through `FileOperationQueue`'s location overloads; one local volume or remote host defaults to move, crossing a volume, host, or local/remote boundary defaults to copy, Command forces move, and Option takes priority as copy.
- **C15** Drop completion now feeds returned result locations into coordinated source and destination refreshes, so pane snapshots survive and visible results are selected without scrolling. Target highlighting clears on acceptance, rejection, drag exit, and session end; failed or partial operations refresh possible successes and use the queue's single aggregated error presentation.
- **C16** Clipboard cut identity is now stored and queried as `Location`, with the URL API retained as a local compatibility view. Clipboard notifications update both local and remote cells; every pending-move row dims consistently and exposes a "pending move" accessibility label and paste help text.
- **C17** Added explicit user, automatic, restored, and operation-result selection origins across outline, loading, reconciliation, filtering, sorting, and result selection. Paste targets exactly one user-selected folder; every other selection shape or origin uses the location displayed by the tab.
- **C18** Clipboard paste now snapshots cut intent and its owning pasteboard generation. A thrown failure or cancellation leaves remote cut locations intact, a successful move clears only the clipboard entry it owns, an externally replaced pasteboard is never erased, copied locations remain reusable, and successful mutations already refresh every affected pane through the coordinator.
- **C19** Expanded the UI-test remote into a root-confined mutable provider with recursive file and directory transfers, trash and restore, rename, creation, upload and download, exact changed-parent watches, per-call listing gates, one-shot operation failures, and structured histories. Added request-and-response pane snapshots for expansion, selection, scroll offsets, focus, filtering, sorting, active drop targets, visible rows, and refresh-in-flight state.
- **C20** Ran the release build through `resources/scripts/build.sh --no-install` on Foundry. Corrected the UI-test provider's resource-key type and moved synchronous directory enumeration out of the actor's async context; the resulting build completes without warnings.
- **T1** Added an injected opening-action seam and verified on Foundry that an ordered visible selection dispatches every ordinary file exactly once without invoking the workspace.
- **T2** Drove the controller's real Enter, Command-O, Command-Down, and context-menu paths on Foundry and verified that each produces the same ordered two-file dispatch.
- **T3** Verified on Foundry that mixed selections dispatch only ordinary files, in order, while folders, archives, and disk images remain skipped and untouched.
- **T4** Verified on Foundry that a special-only multi-selection dispatches exactly the focused item's classified action and does not act on the other selected special items.
- **T5** Verified on Foundry that a failed open does not stop later files, successful items remain recorded, and every failed filename and reason is returned in one ordered batch result.
- **T35** Verified on Foundry that six ordinary files prompt before dispatch and cancellation opens none, while five files dispatch without invoking confirmation.
- **T6** Held a coordinated listing at its fetch boundary on Foundry and verified that the existing visible tree remains unchanged until the explicit release applies the new result.
- **T7** Reconciled a filtered, sorted, expanded, multi-selected, scrolled, keyboard-focused remote pane on Foundry and verified its complete pane snapshot is preserved.
- **T8** Verified on Foundry that an expanded-branch change fetches exactly that branch once and never substitutes a root listing.
- **T9** Verified on Foundry that mutation and watcher reasons for the same directory merge into one listing request containing both causes.
- **T10** Sent repeated callbacks for two branches on Foundry and verified the burst reduces to exactly one listing per affected directory.
- **T11** Held an older generation while queuing a newer mutation on Foundry and verified the older result is discarded and only the follow-up content is applied.
- **T12** Forced a listing failure on Foundry, verified the existing row and accessible retry banner remain, then clicked Retry and confirmed the later listing replaces the content and clears the banner.
- **T13** Reconciled the displayed root on Foundry and verified the exact root and expanded-branch watch tokens remain registered without churn.
- **T14** Removed the selected row from a scrolled, sorted remote list on Foundry and verified selection moves to the next visual survivor while the top-visible location and pixel offset remain fixed.
- **T15** Validated same-host remote drops on Foundry and verified folder-row and pane-background targets both advertise move while exposing only their corresponding highlight state.
- **T16** Accepted a two-item internal remote drop on Foundry and verified the delegate receives both ordered source locations, the exact folder destination, and the resolved operation before highlights clear.
- **T17** Covered same and cross local volumes, same and cross remote hosts, local-remote boundaries, Command, Option, and combined modifiers on Foundry; every case resolves to the specified copy or move.
- **T18** Verified on Foundry that self, descendant, same-parent, regular-file, and disappeared targets are rejected during hover and rechecked at acceptance, with host identity preventing false descendant matches.
- **T19** Configured a remote row as both pending move and a drop target on Foundry, verifying dimming, border treatment, accessibility label and help, plus complete reset when both states clear.
- **T20** Forced the first remote cut paste to fail and the second to succeed on Foundry, verifying source locations and pending-cut state survive the failure and clear only after the successful move.
