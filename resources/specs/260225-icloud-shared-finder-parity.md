# iCloud Shared Split with Finder-Parity Listing

## Meta
- Status: Draft
- Branch: fix/icloud-shared-finder-parity

---

## Business

### Goal
Restore iCloud browsing so it behaves Finder-like while separating shared items into a dedicated `Shared` folder that includes both items shared to the user and items shared by the user.

### Proposal
Keep iCloud navigation and naming aligned with Finder, but remove shared items from the normal iCloud listing and surface them in a single top-level `Shared` folder. The `Shared` folder shows only top-level shared items and labels each as `Shared by <owner>` or `Shared by me`.

### Behaviors
- Clicking the iCloud button opens the iCloud root experience (Finder-like listing), not a raw container dump.
- Normal iCloud listing excludes top-level shared items.
- A dedicated `Shared` folder appears in iCloud root.
- Opening `Shared` shows one combined list containing:
  - top-level items shared to the user
  - top-level items shared by the user
- `Shared` list includes both files and folders.
- Shared labels:
  - participant role: `Shared by <owner name>`
  - owner role: `Shared by me`
- Shared list is top-level only (no recursive flattening).
- Hidden-files toggle behavior remains standard:
  - hidden off: hidden items suppressed
  - hidden on: hidden items shown (including internals)
- iCloud naming cleanup:
  - `com~apple~CloudDocs` must no longer be displayed as `Shared`
  - `Shared` is reserved for the dedicated shared view only

### Out of scope
- Recursive shared-item aggregation beyond top-level.
- Sectioned shared UI (`Shared with me` vs `Shared by me`).
- Changes to Sidebar behavior or Quick Open indexing.
- Changes to share operations (AirDrop/system share menu).

---

## Technical

### Approach
Implement a dedicated iCloud listing mode in the file-list pipeline so iCloud root can be composed from Finder-like items while shared items are split into a separate virtual folder. The implementation must avoid hard-renaming real filesystem folders to `Shared` and instead model `Shared` as an explicit Detours view state.

The data source will build iCloud root entries from real filesystem metadata, then partition top-level `com~apple~CloudDocs` children into shared vs non-shared using existing ubiquitous resource keys. Non-shared items remain in the normal listing; shared items are routed to the dedicated `Shared` view. Navigation and history must preserve whether the user is in normal iCloud view or shared view so Back/Forward and tab restore remain correct.

### Risks

| Risk | Mitigation |
|------|------------|
| Virtual `Shared` navigation may conflict with path-based logic and history restore | Add explicit iCloud listing mode state (normal vs shared) to tab/navigation state instead of relying only on URL path |
| Performance regression from composing iCloud root from multiple sources | Reuse `DirectoryLoader` async path and keep enumeration to top-level only |
| Ambiguous labels for owner-shared entries | Add explicit owner-role handling in `FileItem` metadata mapping and cell rendering |
| Duplicate-looking rows when merging iCloud sources | Canonicalize by standardized path and apply deterministic dedupe/ordering rules |
| Behavioral regressions in open/rename/paste operations from virtual view state | Scope file operations to real URLs only; cover with targeted tests and manual verification |

### Implementation Plan

**Phase 1: Remove incorrect naming and add role-complete labels**
- [ ] Update [src/FileList/FileItem.swift](/Users/marco/dev/detours/src/FileList/FileItem.swift) to stop renaming `com~apple~CloudDocs` to `Shared` in both initializers.
- [ ] Extend `FileItem` shared metadata mapping in [src/FileList/FileItem.swift](/Users/marco/dev/detours/src/FileList/FileItem.swift) to represent both participant and owner roles.
- [ ] Update shared-label rendering in [src/FileList/FileListCell.swift](/Users/marco/dev/detours/src/FileList/FileListCell.swift) to show `Shared by me` for owner role and `Shared by <owner>` for participant role.
- [ ] Update iCloud-friendly title/path mapping in [src/Panes/PaneTab.swift](/Users/marco/dev/detours/src/Panes/PaneTab.swift) and [src/Panes/PaneViewController.swift](/Users/marco/dev/detours/src/Panes/PaneViewController.swift) so real CloudDocs is never displayed as `Shared`.

**Phase 2: Add explicit iCloud listing modes**
- [ ] Introduce iCloud listing mode (`normal`, `sharedTopLevel`) in tab/navigation state in [src/Panes/PaneTab.swift](/Users/marco/dev/detours/src/Panes/PaneTab.swift), including Back/Forward/history entries.
- [ ] Thread listing mode through file-list loading in [src/FileList/FileListViewController.swift](/Users/marco/dev/detours/src/FileList/FileListViewController.swift) and [src/FileList/FileListDataSource.swift](/Users/marco/dev/detours/src/FileList/FileListDataSource.swift).
- [ ] Persist and restore iCloud listing mode with tab/session state in [src/Panes/PaneViewController.swift](/Users/marco/dev/detours/src/Panes/PaneViewController.swift) and [src/Windows/MainSplitViewController.swift](/Users/marco/dev/detours/src/Windows/MainSplitViewController.swift).

**Phase 3: Compose Finder-like iCloud root and dedicated Shared folder**
- [ ] Add iCloud root builder logic in [src/FileList/FileListDataSource.swift](/Users/marco/dev/detours/src/FileList/FileListDataSource.swift) to:
  - derive Finder-like visible root entries
  - partition top-level CloudDocs children by `ubiquitousItemIsShared` + role
  - exclude shared items from normal listing
  - inject dedicated `Shared` folder entry
- [ ] Add shared-view loader in [src/FileList/FileListDataSource.swift](/Users/marco/dev/detours/src/FileList/FileListDataSource.swift) for `sharedTopLevel` mode:
  - include only top-level shared items
  - include both files and folders
  - no recursive descent
- [ ] Ensure hidden-file behavior in both iCloud modes follows existing tab setting (`showHiddenFiles`) in [src/FileList/FileListDataSource.swift](/Users/marco/dev/detours/src/FileList/FileListDataSource.swift).
- [ ] Keep iCloud button target and root entrypoint consistent in [src/Panes/PaneViewController.swift](/Users/marco/dev/detours/src/Panes/PaneViewController.swift).

**Phase 4: Regression-proofing**
- [ ] Verify folder/container navigation rules remain intact (including `Documents` auto-resolution) in [src/Panes/PaneTab.swift](/Users/marco/dev/detours/src/Panes/PaneTab.swift).
- [ ] Verify file operations are disabled or correctly scoped where the view is virtual/shared-only in [src/FileList/FileListViewController.swift](/Users/marco/dev/detours/src/FileList/FileListViewController.swift).
- [ ] Update docs in [resources/docs/USER_GUIDE.md](/Users/marco/dev/detours/resources/docs/USER_GUIDE.md) and [resources/docs/CHANGELOG.md](/Users/marco/dev/detours/resources/docs/CHANGELOG.md).

---

## Testing

Tests in `Tests/`. Results logged in `Tests/TEST_LOG.md`.

### Unit Tests (`Tests/FileItemTests.swift`)
- [ ] `testSharedOwnerLabelIsSharedByMe` - Owner role maps to `Shared by me`.
- [ ] `testSharedParticipantLabelUsesOwnerName` - Participant role maps to `Shared by <owner>`.
- [ ] `testCloudDocsNotRenamedToShared` - `com~apple~CloudDocs` keeps real iCloud naming.

### Unit Tests (`Tests/FileListDataSourceTests.swift`)
- [ ] `testICloudRootExcludesTopLevelSharedItems` - Shared top-level items are removed from normal iCloud listing.
- [ ] `testICloudRootIncludesDedicatedSharedFolder` - Dedicated `Shared` folder is injected in iCloud root.
- [ ] `testSharedModeShowsTopLevelOnly` - Shared mode does not recurse into descendants.
- [ ] `testSharedModeIncludesFilesAndFolders` - Shared mode includes both item types.
- [ ] `testShowHiddenAffectsICloudModes` - Hidden toggle affects both normal and shared iCloud modes.

### Unit Tests (`Tests/PaneTabTests.swift`)
- [ ] `testHistoryPreservesICloudListingMode` - Back/Forward restores normal vs shared mode correctly.
- [ ] `testGoUpBehaviorUnchangedForICloudContainers` - Existing iCloud container go-up rules still hold.

### Unit Tests (`Tests/PaneViewControllerTests.swift`)
- [ ] `testICloudButtonOpensICloudRootMode` - iCloud button enters normal iCloud root mode.
- [ ] `testSessionRestorePreservesICloudMode` - Tab restore keeps shared vs normal mode.

### Manual Verification (Marco)
- [ ] In iCloud root, non-shared folders/files match Finder-like expectations and shared items are absent.
- [ ] `Shared` opens as one combined list containing top-level shared-to-me and shared-by-me items, with correct labels.
- [ ] Toggling hidden files on/off updates both normal iCloud view and `Shared` view correctly.
- [ ] No duplicate nested-folder regressions (no repeated folder-in-folder artifacts).

