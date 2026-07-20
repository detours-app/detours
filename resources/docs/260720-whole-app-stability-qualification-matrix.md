# Whole-App Stability Qualification Matrix

## Contract

This matrix is the tracked capability contract for the one-time whole-app qualification campaign. The current implementation, `resources/docs/USER_GUIDE.md`, and the newest completed feature spec govern each row in that order when older descriptions conflict.

Each row has these fields:

- **ID:** stable campaign identifier.
- **Surface:** where a person or the app initiates the behavior.
- **Expected behavior:** observable contract.
- **Locations:** `L` local, `A` disposable APFS image, `I` iCloud Drive, `S` SMB, `D` Linux `devtest`, `M` Intel Mac `wraith`, `W` Windows `win-carriercall`, or `-` when storage-independent.
- **Contexts:** `P` in-process Swift test, `U` installed-app UI test, `R` relaunch/session, `X` external-change/failure injection.
- **Automated check:** existing check or the qualification workflow that owns the row. Names beginning `Q.` are implemented by this campaign.
- **Repetition:** `1` focused contract test, `100P` one hundred in-process iterations, `20U` twenty installed-app iterations per applicable location/context, and `Soak` continuous cycling during the 12-hour run.
- **Result:** `Pending` until generated from final run evidence. No retry, warning, manual assertion, or applicable skip can change a failure into a pass.
- **Defect/fix:** populated by result generation for every failure found during the campaign.

## Capability Matrix

| ID | Surface | Expected behavior | Locations | Contexts | Automated check | Repetition | Result | Defect/fix |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| APP-001 | Launch | A usable two-pane window opens with one active pane and one active tab per pane. | L | U,R | `SmokeTests`; `Q.activation` | 20U,Soak | Pending | - |
| APP-002 | Detours > About Detours | The About window reports the app identity and version and dismisses normally. | - | U | `Q.menuAndWindowCommands` | 20U | Pending | - |
| APP-003 | Detours > Preferences / Command-, | One preferences window opens with General, Appearance, Shortcuts, and Git sections. | - | U | `PreferencesTests`; `Q.menuAndWindowCommands` | 20U | Pending | - |
| APP-004 | Detours > Quit / Command-Q | Quit closes Detours cleanly and session policy is honored on relaunch. | L | U,R | `PaneStateRestoreTests`; `Q.sessionAppearance` | 20U,Soak | Pending | - |
| APP-005 | App activation | Returning from another app preserves the intended pane, tab, first responder, and selection. | L,A,I,S,D,M,W | P,U,R | `Q.activation` | 100P,20U,Soak | Pending | - |
| FILE-001 | File > New Folder; shortcut menu; F7; Command-Shift-N | A uniquely named folder is created in the intended directory, selected, and ready to rename; cancel creates nothing. | L,A,I,S,D,M,W | P,U | `NewFolderUITests`; `Q.fileMutations` | 100P,20U | Pending | - |
| FILE-002 | File > New File > Text File; shortcut menu; Command-Option-N | A new text file is created and selected in the intended directory. | L,A,I,S,D,M,W | P,U | `Q.fileMutations` | 100P,20U | Pending | - |
| FILE-003 | File > New File > Markdown File; shortcut menu | A new Markdown file is created and selected in the intended directory. | L,A,I,S,D,M,W | P,U | `Q.fileMutations` | 100P,20U | Pending | - |
| FILE-004 | File > New File > Empty File; shortcut menu | A file with the supplied valid name is created; invalid input or cancel changes nothing. | L,A,I,S,D,M,W | P,U | `Q.fileMutations` | 100P,20U | Pending | - |
| FILE-005 | File > Add Remote Host / Command-K | The host form validates and saves Linux, macOS, or Windows SSH targets without exposing credentials. | D,M,W | P,U | `RemoteHostTests`; `RemoteHostKindRoutingTests`; `Q.connections` | 100P,20U | Pending | - |
| FILE-006 | File > Connect to Network Share | The share form mounts an authenticated SMB location or presents a recoverable error. | S | P,U,X | `NetworkTests`; `NetworkUITests`; `Q.connections` | 100P,20U | Pending | - |
| FILE-007 | File/shortcut menu > Duplicate / Command-D | Files and folders duplicate beside the source using deterministic keep-both naming and select the result. | L,A,I,S,D,M,W | P,U | `FileOperationQueueTests`; `PasteSelectionUITests`; `Q.fileMutations` | 100P,20U | Pending | - |
| FILE-008 | Shortcut menu > Duplicate Structure | The chosen empty folder hierarchy is reproduced at the destination; cancel leaves no output. | L,A,I,S,D,M,W | P,U | `DuplicateStructureTests`; `DuplicateStructureUITests` | 100P,20U | Pending | - |
| FILE-009 | File/shortcut menu > Archive | ZIP or 7Z creation preserves names and bytes, supports valid passwords, resolves conflicts, and cancels without partial output. | L,A,I,S,D,M,W | P,U,X | `ArchiveOperationTests`; `ArchivePasswordValidationTests`; `ArchivePasswordUITests`; `Q.archives` | 100P,20U | Pending | - |
| FILE-010 | File/shortcut menu > Extract Here | Supported archives extract safely with password retry, conflict choices, cancellation, and no traversal outside the destination. | L,A,I,S,D,M,W | P,U,X | `ArchiveOperationTests`; `ServerArchiveOperationsTests`; `WindowsArchiveScriptTests`; `Q.archives` | 100P,20U | Pending | - |
| FILE-011 | File/shortcut menu > Get Info / Command-I | Local and remote selections show truthful name, kind, path, size, modification, hidden/readable, and link information. | L,A,I,S,D,M,W | P,U | `RemoteUISurfaceTests`; `Q.openAndInspect` | 100P,20U | Pending | - |
| FILE-012 | File/shortcut menu > Reveal in Finder | Each selected local item is revealed; the action is unavailable for remote items. | L,A,I,S | P,U | `SystemIntegrationTests`; `Q.openAndInspect` | 100P,20U | Pending | - |
| FILE-013 | File/shortcut menu > Show Package Contents | A local package is treated as a navigable folder without changing normal file behavior. | L,A,I,S | P,U | `FileItemOpeningTests`; `Q.openAndInspect` | 100P,20U | Pending | - |
| FILE-014 | File/shortcut menu > Share | Applicable system sharing services receive every selected local URL; remote selections do not expose the action. | L,A,I,S | P,U | `SystemIntegrationTests`; `Q.openAndInspect` | 100P,20U | Pending | - |
| FILE-015 | File/shortcut menu > Move to Trash / F8 / Command-Delete | Applicable items move to Trash and can be undone; remote behavior explains provider semantics. | L,A,I,S,D,M,W | P,U,X | `TrashOperationsTests`; `RemoteTrashUndoTests`; `UndoUITests`; `Q.fileMutations` | 100P,20U | Pending | - |
| FILE-016 | File/shortcut menu > Delete Immediately / Command-Option-Delete | Confirmation gates permanent deletion; cancel is inert and success is not undoable. | L,A,I,S,D,M,W | P,U,X | `PermanentDeleteWarningTests`; `Q.fileMutations` | 100P,20U | Pending | - |
| FILE-017 | Shortcut menu > Rename / F2 / Shift-Return | Exactly one aligned inline editor appears; commit updates and selects the item while cancel preserves it. | L,A,I,S,D,M,W | P,U | `RemoteInlineRenameRefreshTests`; `RefreshAuthorityUITests`; `RenameVisualUITests`; `Q.fileMutations` | 100P,20U | Pending | - |
| FILE-018 | File > Close Tab / Command-W | The active tab closes, a deterministic neighbor activates, and the last tab leaves a usable pane. | L,A,I,S,D,M,W | P,U,R | `PaneTabTests`; `Q.sessionAppearance` | 100P,20U | Pending | - |
| FILE-019 | File > Close Window / Command-Shift-W | The window closes without corrupting persisted pane, tab, or divider state and can be reopened. | L | U,R | `WindowPaneGeometryUITests`; `Q.sessionAppearance` | 20U | Pending | - |
| EDIT-001 | Edit > Undo / Command-Z | The active tab undoes supported mutations in order and exposes an accurate menu label. | L,A,I,S,D,M,W | P,U | `FileOperationQueueTests+Undo`; `UndoUITests`; `Q.fileMutations` | 100P,20U | Pending | - |
| EDIT-002 | Edit > Redo / Command-Shift-Z | A just-undone supported mutation is replayed once with correct filesystem and pane state. | L,A,I,S,D,M,W | P,U | `FileOperationQueueTests+Undo`; `UndoUITests`; `Q.fileMutations` | 100P,20U | Pending | - |
| EDIT-003 | Edit/shortcut menu > Cut / Command-X | Selected items enter a move transaction; paste moves them once and keeps source/destination panes coherent. | L,A,I,S,D,M,W | P,U | `ClipboardManagerTests`; `CrossProviderTransferTests`; `Q.crossPaneTransfer` | 100P,20U | Pending | - |
| EDIT-004 | Edit/shortcut menu > Copy / Command-C | Selected items enter a copy transaction without modifying the source. | L,A,I,S,D,M,W | P,U | `ClipboardManagerTests`; `Q.crossPaneTransfer` | 100P,20U | Pending | - |
| EDIT-005 | Edit/shortcut menu > Paste / Command-V | Paste targets the currently intended directory, resolves conflicts, selects results, and leaves no partial file. | L,A,I,S,D,M,W | P,U,X | `CopyMoveMatrixTests`; `CrossProviderTransferTests`; `PasteSelectionUITests`; `Q.crossPaneTransfer` | 100P,20U | Pending | - |
| EDIT-006 | Edit > Filter / Command-F / slash | The filter appears in-place, filters current and expanded rows, transfers focus correctly, and Escape clears then closes. | L,A,I,S,D,M,W | P,U | `FilterTests`; `FilterUITests`; `Q.refreshAndView` | 100P,20U | Pending | - |
| EDIT-007 | Edit/shortcut menu > Copy Path / Command-Option-C | Escaped paths for all selections are copied one per line. | L,A,I,S,D,M,W | P,U | `FileListResponderTests`; `Q.menuAndKeyboard` | 100P,20U | Pending | - |
| EDIT-008 | Edit > Select All / Command-A; Shift-Up/Down | Selection commands affect the visible list predictably without changing location or expansion. | L,A,I,S,D,M,W | P,U | `FileListResponderTests`; `Q.menuAndKeyboard` | 100P,20U | Pending | - |
| VIEW-001 | View > New Tab / Command-T | A new active tab opens in the intended pane with a valid location. | L,A,I,S,D,M,W | P,U,R | `PaneTabTests`; `Q.activation` | 100P,20U | Pending | - |
| VIEW-002 | View > numbered tab items | Dynamic tab menu entries match open tabs and activate the chosen tab in the active pane. | L,A,I,S,D,M,W | P,U | `PaneTabTests`; `Q.menuAndKeyboard` | 100P,20U | Pending | - |
| VIEW-003 | View > Toggle Hidden Files / Command-Shift-. | Hidden rows appear or disappear without losing location, valid selection, expansion, sort, or filter state. | L,A,I,S,D,M,W | P,U,X | `FileListDataSourceTests`; `Q.refreshAndView` | 100P,20U | Pending | - |
| VIEW-004 | View > Show/Hide Status Bar | Both status bars toggle together and report correct selected/visible/total counts when shown. | L,A,I,S,D,M,W | P,U | `StatusBarCountTests`; `Q.sessionAppearance` | 100P,20U | Pending | - |
| VIEW-005 | View > Toggle Sidebar / Command-0 | The sidebar fully collapses or restores, preserving equal content panes and persisted visibility. | L,A,I,S,D,M,W | P,U,R | `SidebarTests`; `WindowPaneGeometryUITests`; `Q.sessionAppearance` | 100P,20U | Pending | - |
| VIEW-006 | View > Equalize Panes / Control-Command-= | Content panes become equal width independent of sidebar width and persist usable geometry. | - | P,U,R | `EqualSplitIndicatorViewTests`; `WindowPaneGeometryUITests` | 100P,20U | Pending | - |
| NAV-001 | Go > Quick Open / Command-P | Search is scoped to the active local or remote tab, ranks results, handles hidden policy, and opens/navigates selected results. | L,A,I,S,D,M,W | P,U,X | `QuickNavTests`; `RemoteQuickOpenUITests`; `QuickNavCmdEnterUITests`; `Q.openAndInspect` | 100P,20U | Pending | - |
| NAV-002 | Go > Back / Command-Left | Back navigates the active tab history without changing pane or tab ownership. | L,A,I,S,D,M,W | P,U | `PaneViewControllerTests`; `Q.refreshAndView` | 100P,20U | Pending | - |
| NAV-003 | Go > Forward / Command-Right | Forward navigates the active tab history without changing pane or tab ownership. | L,A,I,S,D,M,W | P,U | `PaneViewControllerTests`; `Q.refreshAndView` | 100P,20U | Pending | - |
| NAV-004 | Go > Enclosing Folder / Command-Up | Parent navigation selects the directory just left when possible. | L,A,I,S,D,M,W | P,U | `FileListResponderTests+Navigation`; `Q.refreshAndView` | 100P,20U | Pending | - |
| NAV-005 | Go > Refresh / Command-R | Manual refresh reconciles exactly once while preserving location, relevant expansion, focus, and selection. | L,A,I,S,D,M,W | P,U,X | `PaneRefreshSchedulerTests`; `RefreshAuthorityUITests`; `Q.refreshAndView` | 100P,20U | Pending | - |
| NAV-006 | Go > Next/Previous Tab / Control-Tab | Tab cycling stays inside the active pane and wraps predictably. | L,A,I,S,D,M,W | P,U | `PaneTabTests`; `Q.activation` | 100P,20U | Pending | - |
| NAV-007 | Tab key / pane click | Pane switching yields exactly one active pane, preserves one active tab per pane, and moves focus visibly. | L,A,I,S,D,M,W | P,U,R | `PaneViewControllerTests`; `Q.activation` | 100P,20U,Soak | Pending | - |
| NAV-008 | Return / Command-Down / Command-O | All selected files open once; a folder navigates; remote files use the configured remote opening workflow. | L,A,I,S,D,M,W | P,U | `FileItemOpeningTests`; `RemoteQuickOpenUITests`; `Q.openAndInspect` | 100P,20U | Pending | - |
| NAV-009 | Command-Return | The containing folder opens and selects the originating item where applicable. | L,A,I,S,D,M,W | P,U | `QuickNavCmdEnterUITests`; `Q.openAndInspect` | 100P,20U | Pending | - |
| NAV-010 | Up/Down/Home/End/type-to-select | Keyboard movement, range extension, boundary selection, and prefix selection remain deterministic. | L,A,I,S,D,M,W | P,U | `FileListResponderTests+Navigation`; `Q.menuAndKeyboard` | 100P,20U | Pending | - |
| NAV-011 | Right/Left and Option-Right/Left | Folder expansion, collapse, recursive variants, parent/child movement, and selection repair behave coherently. | L,A,I,S,D,M,W | P,U,X | `FolderExpansionTests`; `FolderExpansionUITests` | 100P,20U | Pending | - |
| VIEW-007 | Column headers | Name, size, kind, and modified sorting toggles direction, respects folders-on-top, and preserves state through refresh. | L,A,I,S,D,M,W | P,U,X | `FileListDataSourceTests`; `Q.refreshAndView` | 100P,20U | Pending | - |
| VIEW-008 | Resizable columns | Column widths remain usable, persist where intended, and do not obscure rename or accessory state. | - | P,U,R | `FileListCellTests`; `Q.sessionAppearance` | 100P,20U | Pending | - |
| VIEW-009 | Quick Look / Space | Local and remote selections preview without stealing pane ownership; toggling and selection changes update or dismiss correctly. | L,A,I,S,D,M,W | P,U | `FileListResponderTests+QuickLook`; `DetoursPreviewGeneratorTests`; `Q.openAndInspect` | 100P,20U | Pending | - |
| VIEW-010 | Detours text preview | Markdown, source, structured text, plain text, unsupported, binary, large, and unsafe inputs render or fall back safely in the active theme. | L,A,I,S,D,M,W | P,U | `DetoursPreviewKindTests`; `DetoursPreviewGeneratorTests`; `Q.openAndInspect` | 100P,20U | Pending | - |
| VIEW-011 | F4 / Open With | Local items open in an application; remote items expose supported editors and transfer/open without duplicate launch. | L,A,I,S,D,M,W | P,U,X | `OpenWithConflictTests`; `FileOpenHelperTests`; `Q.openAndInspect` | 100P,20U | Pending | - |
| DRAG-001 | Drag within/between panes | Drop operation, insertion target, copy/move semantics, conflict result, and destination selection are correct. | L,A,I,S,D,M,W | P,U,X | `FileListDragDropTests`; `CopyMoveMatrixTests`; `Q.crossPaneTransfer` | 100P,20U | Pending | - |
| DRAG-002 | Drag to/from Finder or another app | Local export uses file URLs; remote export stages safely and retires temporary processes/files. | L,A,I,S,D,M,W | P,U,X | `RemoteDragOutTests`; `ProcessTerminationTests`; `Q.crossPaneTransfer` | 100P,20U | Pending | - |
| DRAG-003 | Drag folder to Favorites / reorder Favorites | Valid folders add once, reorder predictably, persist, and missing favorites fail gracefully. | L,A,I,S | P,U,R | `SidebarTests`; `Q.sidebarVolumes` | 100P,20U | Pending | - |
| DRAG-004 | Drag to path control | Valid local or remote destinations accept applicable transfers; invalid/self/descendant drops are rejected. | L,A,I,S,D,M,W | P,U,X | `DroppablePathControlTests`; `Q.crossPaneTransfer` | 100P,20U | Pending | - |
| XFER-001 | F5 Copy to Other Pane | Copy uses the destination captured at invocation, activates its pane, and selects the completed result. | L,A,I,S,D,M,W | P,U,X | `PaneOperationTransactionTests`; `RefreshAuthorityUITests`; `Q.crossPaneTransfer` | 100P,20U | Pending | - |
| XFER-002 | F6 Move to Other Pane | Move uses the captured destination, updates both panes once, and supports cancellation/recovery. | L,A,I,S,D,M,W | P,U,X | `PaneOperationTransactionTests`; `CrossProviderTransferTests`; `Q.crossPaneTransfer` | 100P,20U | Pending | - |
| XFER-003 | Cross-provider transfer | Every supported local, cloud, mounted, Linux, Intel Mac, and Windows boundary preserves bytes, metadata contract, conflict choice, and partial-transfer cleanup. | L,A,I,S,D,M,W | P,U,X | `CrossProviderTransferTests`; `WindowsTransferChannelTests`; `Q.crossPaneTransfer` | 100P,20U,Soak | Pending | - |
| XFER-004 | Fast-lane small operation | Trivial operations complete immediately without bypassing ordering, progress, errors, undo registration, or refresh authority. | L,A,I,S,D,M,W | P,U,X | `FileOperationQueueTests+FastLane`; `Q.fileMutations` | 100P,20U | Pending | - |
| XFER-005 | Operation progress | Queued and active work reports truthful item/byte progress, cancellation clears promptly, and the status bar never remains stuck. | L,A,I,S,D,M,W | P,U,X | `FileOperationQueueTests+Progress`; `StatusBarProgressTests`; `Q.crossPaneTransfer` | 100P,20U,Soak | Pending | - |
| CONFLICT-001 | Existing destination | Replace, keep both, skip, cancel, and apply-to-all affect exactly the named conflicts and never overwrite silently. | L,A,I,S,D,M,W | P,U,X | `CopyMoveMatrixTests`; `WindowsRemoteConflictTests`; `Q.fileMutations` | 100P,20U | Pending | - |
| REFRESH-001 | Filesystem watcher | Create, delete, rename, and content changes reconcile automatically without duplicate redraw or stale rows. | L,A,I,S,D,M,W | P,U,X | `DirectoryWatcherTests`; `PaneRefreshSchedulerTests`; `Q.refreshAndView` | 100P,20U,Soak | Pending | - |
| REFRESH-002 | Mutation completion | Operation-owned refresh is ordered, coalesced, and scoped to affected panes while preserving destination intent. | L,A,I,S,D,M,W | P,U,X | `RefreshArchitectureTests`; `RefreshRegressionProbeTests`; `Q.refreshAndView` | 100P,20U | Pending | - |
| REFRESH-003 | Filter/sort/hidden/expansion interaction | Background changes cannot leave stale filtered rows, wrong sort, collapsed branches, or invalid selection. | L,A,I,S,D,M,W | P,U,X | `LocalReconcileTests`; `FolderExpansionUITests`; `Q.refreshAndView` | 100P,20U,Soak | Pending | - |
| REFRESH-004 | Git status update | Modified, staged, untracked, and conflict markers update after filesystem or repository changes without stale badges. | L,A,I,S,D,M | P,U,X | `GitStatusTests`; `Q.refreshAndView` | 100P,20U | Pending | - |
| PREF-001 | General > Restore session on launch | The setting persists and controls restoration of windows, panes, tabs, locations, selection policy, and sidebar state. | L,A,I,S,D,M,W | P,U,R | `PreferencesTests`; `PaneStateRestoreTests`; `Q.sessionAppearance` | 100P,20U | Pending | - |
| PREF-002 | General > Show hidden files by default | New tabs adopt the persisted default without overwriting an existing tab's explicit state. | L,A,I,S,D,M,W | P,U,R | `PreferencesTests`; `Q.sessionAppearance` | 100P,20U | Pending | - |
| PREF-003 | General > Include hidden files in Quick Open | Search includes or excludes hidden entries according to the persisted setting. | L,A,I,S,D,M,W | P,U,R | `QuickNavTests`; `PreferencesTests`; `Q.sessionAppearance` | 100P,20U | Pending | - |
| PREF-004 | General > Enable folder expansion | Disclosure UI and expansion keyboard behavior turn off and restore without damaging navigation. | L,A,I,S,D,M,W | P,U,R | `FolderExpansionUITests+Persistence`; `Q.sessionAppearance` | 100P,20U | Pending | - |
| PREF-005 | General > Folders on top | Sorting places folders first or mixes by selected key consistently and persists. | L,A,I,S,D,M,W | P,U,R | `FileListDataSourceTests`; `PreferencesTests`; `Q.sessionAppearance` | 100P,20U | Pending | - |
| PREF-006 | Appearance > Theme | System, Light, Dark, Foolscap, Drafting, and Custom apply across panes, chrome, dialogs, previews, and relaunch. | - | P,U,R | `ThemeTests`; `ChromePolishUITests`; `Q.sessionAppearance` | 100P,20U | Pending | - |
| PREF-007 | Appearance > Custom theme | Eight colors plus file-list and UI fonts apply and persist with readable active/inactive chrome. | - | P,U,R | `ThemeTests`; `Q.sessionAppearance` | 100P,20U | Pending | - |
| PREF-008 | Appearance > Font size | Sizes 10 through 16 apply without clipping or overlap and persist. | - | P,U,R | `PreferencesTests`; `ChromePolishUITests`; `Q.sessionAppearance` | 100P,20U | Pending | - |
| PREF-009 | Appearance > File list density | Compact, comfortable, and spacious update rows, icons, markers, editors, and loading state without overlap and persist. | - | P,U,R | `FileListDensityTests`; `ChromePolishUITests`; `Q.sessionAppearance` | 100P,20U | Pending | - |
| PREF-010 | Appearance > Date formats | Valid current/other-year formats apply and persist; invalid or empty patterns show an error and do not replace the last valid setting. | - | P,U,R | `PreferencesTests`; `Q.sessionAppearance` | 100P,20U | Pending | - |
| PREF-011 | Shortcuts editor | All 15 customizable actions record, apply immediately, cancel, clear, reset individually, restore defaults, update menus, and persist. | - | P,U,R | `PreferencesTests`; `SystemKeyHandlerTests`; `Q.menuAndKeyboard` | 100P,20U | Pending | - |
| PREF-012 | Git > status indicators | The toggle and marker palette apply immediately and persist; non-repositories show no marker. | L,A,I,S,D,M | P,U,R | `GitStatusTests`; `PreferencesTests`; `Q.sessionAppearance` | 100P,20U | Pending | - |
| SIDEBAR-001 | Devices | Mounted local disks, disk images, iCloud, and shares appear with truthful labels/capacity and navigate the active pane. | L,A,I,S | P,U,X | `SidebarTests`; `ChromePolishUITests`; `Q.sidebarVolumes` | 100P,20U,Soak | Pending | - |
| SIDEBAR-002 | Device eject button/shortcut menu | Ejectable volumes unmount, disappear automatically, and expose recoverable errors; non-ejectable devices are protected. | A,S | P,U,X | `NetworkTests`; `ChromePolishUITests`; `Q.sidebarVolumes` | 100P,20U | Pending | - |
| SIDEBAR-003 | Favorites | Defaults, navigation, add, reorder, remove, missing-path handling, and persistence remain correct. | L,A,I,S | P,U,R,X | `SidebarTests`; `Q.sidebarVolumes` | 100P,20U | Pending | - |
| SIDEBAR-004 | Network servers | Discovered servers, connect actions, mounted shares, eject, saved-password forget, and disappearance update without stale state. | S | P,U,X | `NetworkTests`; `NetworkUITests`; `Q.connections` | 100P,20U,Soak | Pending | - |
| REMOTE-001 | Linux SSH host | Connect, deploy/probe helper, list, stat, navigate, watch, search, transfer, mutate, archive, trash, reconnect, and disconnect work on `devtest`. | D | P,U,X | `RemoteIntegrationTests`; `Q.connections` | 100P,20U,Soak | Pending | - |
| REMOTE-002 | Intel Mac SSH host | Connect, deploy/probe helper, list, stat, navigate, watch, search, transfer, mutate, archive, trash, reconnect, and disconnect work on `wraith`. | M | P,U,X | `RemoteIntegrationTests`; `Q.connections` | 100P,20U,Soak | Pending | - |
| REMOTE-003 | Windows SSH host | PowerShell-backed list, path, transfer, mutate, archive, trash contract, reconnect, and disconnect work on `win-carriercall`. | W | P,U,X | `WindowsRemoteLiveTests`; `WindowsRemoteUITests`; `Q.connections` | 100P,20U,Soak | Pending | - |
| REMOTE-004 | Authentication and host trust | Password/key prompts, saved credentials, rejection, retry, changed-host-key warning, forget, and process-private secrets behave safely. | S,D,M,W | P,U,X | `SSHHostTrustTests`; `KeychainCredentialStoreUITests`; `Q.connections` | 100P,20U | Pending | - |
| REMOTE-005 | Connection loss and recovery | Delay, auth failure, helper exit, network loss, reconnect, watcher restart, and location disappearance clear busy state and preserve a usable pane. | S,D,M,W | P,U,X | `RemoteConnectionTeardownTests`; `DisconnectedQueueTests`; `WindowsRemoteUITests`; `Q.connections` | 100P,20U,Soak | Pending | - |
| ICLOUD-001 | iCloud Drive listing | Finder-parity roots, shared items, download status, placeholder behavior, hidden rules, and pinned qualification contents list correctly. | I | P,U,X | `FileListDataSourceTests+ICloud`; `Q.refreshAndView` | 100P,20U,Soak | Pending | - |
| SESSION-001 | Relaunch and restoration | Only intended window, split, sidebar, tab, location, active-pane, active-tab, expansion, and setting state persists; corrupt state falls back safely. | L,A,I,S,D,M,W | P,U,R,X | `PaneStateRestoreTests`; `WindowPaneGeometryUITests`; `Q.sessionAppearance` | 100P,20U,Soak | Pending | - |
| WINDOW-001 | Window resize, divider drag, minimize, zoom | Native AppKit resizing stays stable, persists valid geometry, rejects poisoned defaults, and leaves both panes usable. | - | P,U,R,X | `AppKitGeometrySanitizerTests`; `SplitPositionTests`; `WindowPaneGeometryUITests` | 100P,20U | Pending | - |
| CHROME-001 | Active/inactive pane and tab chrome | Exactly one pane and one tab per pane are visually and accessibly active across themes, density, focus, activation, operations, and relaunch. | L,A,I,S,D,M,W | P,U,R,X | `EqualSplitIndicatorViewTests`; `ChromePolishUITests`; `Q.activation` | 100P,20U,Soak | Pending | - |
| CHROME-002 | Reference states | Light, Dark, Foolscap, Drafting, custom, three Dark densities, rename, drag target, progress, and connection loss match the finite reference set structurally and visually. | L,S,D,W | U,X | `Q.referenceImages` | 20U | Pending | - |
| ACCESS-001 | Installed-app accessibility | Pane, tab, list, menus, status, progress, errors, dialogs, settings, and sidebar retain roles, labels, values, enabled state, and dismiss/retry actions. | L,A,I,S,D,M,W | U,X | `Q.accessibility` | 20U,Soak | Pending | - |
| SAFETY-001 | Qualification run roots | Only canonical UUID children with matching sentinels under exact allowlisted parents can be mutated or cleaned. | L,A,I,S,D,M,W | P,X | `QualificationRunRootTests` | 1,100P | Pending | - |
| SAFETY-002 | Outside-root snapshots | Provider snapshots before and after every workflow prove siblings and parents outside run roots remain unchanged. | L,A,I,S,D,M,W | P,U,X | `QualificationProviderFailureTests`; `Q.allWorkflows` | 100P,20U,Soak | Pending | - |
| SAFETY-003 | Cleanup | Exact run folders, mounts, test credentials, processes, watches, preferences, caches, and session fixtures are removed on success, failure, interruption, and soak completion. | L,A,I,S,D,M,W | P,U,X | `QualificationProviderFailureTests`; `Q.cleanup` | 100P,20U,Soak | Pending | - |
| REL-001 | Immediate UI response | Focus, active indication, menu validation, and comparable feedback complete within one second. | L,A,I,S,D,M,W | P,U | `Q.reliability` | 100P,20U,Soak | Pending | - |
| REL-002 | Local operation response | Ordinary local listing and small-file work completes visibly within ten seconds or presents a clear recoverable failure. | L,A | P,U,X | `Q.reliability` | 100P,20U,Soak | Pending | - |
| REL-003 | Cloud/remote operation response | Ordinary cloud, mounted, and remote listing/small-file work completes visibly within thirty seconds or presents a recoverable failure. | I,S,D,M,W | P,U,X | `Q.reliability` | 100P,20U,Soak | Pending | - |
| REL-004 | Cancellation and stuck-work limits | Cancellation clears visible activity within five seconds; no operation remains active for sixty seconds without failure and recovery. | L,A,I,S,D,M,W | P,U,X | `Q.reliability` | 100P,20U,Soak | Pending | - |

## Source Census

The census is mechanically audited by `qualification.sh audit-matrix`: main-menu titles, shortcut-menu titles, `ShortcutAction.allCases`, preference controls, drag registrations, user-guide headings, automatic-behavior anchors, and every completed spec must appear below or in a matrix surface/source reference. The audit also requires every matrix row to name an automated check and every applicable row to have a repetition level.

### Direct implementation and guide sources

| Source | Governed rows |
| --- | --- |
| `src/App/MainMenu.swift` | APP-002..005, FILE-001..019, EDIT-001..008, VIEW-001..006, NAV-001..006, WINDOW-001 |
| `src/FileList/FileListViewController+ContextMenu.swift` | FILE-001..017, EDIT-003..007, VIEW-011 |
| `src/FileList/FileListViewController+Keyboard.swift` and `src/Preferences/Settings.swift` (`ShortcutAction`) | FILE-001, FILE-015..017, EDIT-003..008, VIEW-003, VIEW-009, VIEW-011, NAV-001..011, XFER-001..002, PREF-011 |
| `src/FileList/FileListViewController+DragDrop.swift`, `src/Panes/DroppablePathControl.swift`, and sidebar drag sources | DRAG-001..004, XFER-001..003, SIDEBAR-003 |
| `src/Preferences/*SettingsView.swift` | PREF-001..012 |
| `resources/docs/USER_GUIDE.md` (all headings from Interface Overview through Requirements) | APP-001, FILE-001..019, EDIT-001..008, VIEW-001..011, NAV-001..011, DRAG-001..004, XFER-001..005, CONFLICT-001, REFRESH-001..004, PREF-001..012, SIDEBAR-001..004, REMOTE-001..005, ICLOUD-001, SESSION-001, WINDOW-001, CHROME-001 |
| Automatic behavior anchors: watcher, refresh scheduler, Git provider, volume monitor, session restoration, iCloud listing, remote connection state, operation queue | REFRESH-001..004, SIDEBAR-001..004, REMOTE-001..005, ICLOUD-001, SESSION-001, XFER-004..005 |

### Completed feature-spec sources

| Completed spec | Governed rows |
| --- | --- |
| `260105-detour-overview` | APP-001, VIEW-001, NAV-007, FILE-001, EDIT-003..005, XFER-001..002 |
| `260105-stage1-foundation` | APP-001, NAV-007, VIEW-007, WINDOW-001 |
| `260105-stage2-tabs` | FILE-018, VIEW-001..002, NAV-006..007, SESSION-001 |
| `260106-stage3-operations` | FILE-001, FILE-007, FILE-015..017, EDIT-003..005, XFER-001..002 |
| `260106-stage4-quick-nav` | NAV-001 |
| `260106-stage6-folder-expansion` and `260111-stage8-folder-expansion` | NAV-011, REFRESH-003, PREF-004 |
| `260107-stage5-system-integration` | VIEW-009, FILE-011..014, VIEW-011 |
| `260107-stage6-preferences` | APP-003, PREF-001..012, REFRESH-004 |
| `260110-stage7-sidebar` | VIEW-005, DRAG-003, SIDEBAR-001..003 |
| `260112-configurable-date-format` | PREF-010 |
| `260112-optional-column-resizing` | VIEW-008 |
| `260121-xcuitest-infrastructure` | APP-001, ACCESS-001 |
| `260127-duplicate-folder-structure` | FILE-008 |
| `260127-filter-in-place` | EDIT-006, REFRESH-003 |
| `260129-operation-undo` | EDIT-001..002, FILE-015 |
| `260202-network-volumes` | FILE-006, SIDEBAR-002, SIDEBAR-004, REMOTE-004..005 |
| `260204-rename-field-indentation` | FILE-017, PREF-009, CHROME-002 |
| `260207-async-directory-loading` | REFRESH-001..003, REL-002..004 |
| `260212-archive-files` | FILE-009..010 |
| `260217-share-files` | FILE-014 |
| `260218-column-sorting` | VIEW-007 |
| `260223-status-bar-count-bugs` | VIEW-004, REFRESH-003 |
| `260225-activity-bar` and `260401-status-bar-progress` | XFER-005, REL-004 |
| `260225-icloud-shared-finder-parity` | ICLOUD-001 |
| `260225-visual-design-overhaul` | PREF-006..009, CHROME-001..002 |
| `260302-fix-folder-watching` | REFRESH-001..003 |
| `260409-fast-lane-operations` | XFER-004 |
| `260603-remote-vm-browsing` | FILE-005, REMOTE-001..002, REMOTE-004..005, XFER-003 |
| `260617-detours-native-text-previews` | VIEW-009..010 |
| `260621-standard-appkit-window-pane-resizing` | VIEW-006, WINDOW-001 |
| `260623-remote-quick-open-search` | NAV-001 |
| `260625-secure-password-archives` | FILE-009..010, REMOTE-004 |
| `260625-windows-remote-browsing` and `260626-windows-remote-hardening` | REMOTE-003..005, XFER-003, SAFETY-002..003 |
| `260707-chrome-polish` | PREF-009, SIDEBAR-001..002, CHROME-001..002, ACCESS-001 |
| `260715-file-opening-and-remote-operations` | NAV-008..009, VIEW-011, FILE-011, REMOTE-001..005 |
| `260717-pane-refresh-authority` | FILE-017, NAV-005, REFRESH-001..004, XFER-001..002 |

## Final Run Records

Generated by `resources/scripts/qualification.sh report` after the three clean cold runs and soak complete against one exact app commit. Until then, every row remains `Pending`.
