# Test Log

## Latest Run
- Started: 2026-01-06 08:42:22
- Ended: 2026-01-06 08:42:28
- Command: `xcodebuild test -scheme Detour -destination 'platform=macOS'`
- Status: PASS
- Total tests: 53

### ClipboardManagerTests
| Test | Status | Duration | Last Run |
| --- | --- | --- | --- |
| testClearResetsState | PASS | 0.011s | 2026-01-06 08:42:22 |
| testCopyClearsIsCutFlag | PASS | 0.004s | 2026-01-06 08:42:22 |
| testCopyWritesToPasteboard | PASS | 0.002s | 2026-01-06 08:42:22 |
| testCutPopulatesCutItemURLs | PASS | 0.002s | 2026-01-06 08:42:22 |
| testCutSetsIsCutFlag | PASS | 0.002s | 2026-01-06 08:42:22 |
| testHasItemsFalse | PASS | 0.001s | 2026-01-06 08:42:22 |
| testHasItemsTrue | PASS | 0.002s | 2026-01-06 08:42:22 |
| testIsItemCut | PASS | 0.002s | 2026-01-06 08:42:22 |

### FileItemTests
| Test | Status | Duration | Last Run |
| --- | --- | --- | --- |
| testFormattedDateDifferentYear | PASS | 0.001s | 2026-01-06 08:42:22 |
| testFormattedDateSameYear | PASS | 0.001s | 2026-01-06 08:42:22 |
| testFormattedSizeBytes | PASS | 0.001s | 2026-01-06 08:42:22 |
| testFormattedSizeGB | PASS | 0.001s | 2026-01-06 08:42:22 |
| testFormattedSizeKB | PASS | 0.001s | 2026-01-06 08:42:22 |
| testFormattedSizeMB | PASS | 0.001s | 2026-01-06 08:42:22 |
| testInitFromDirectory | PASS | 0.002s | 2026-01-06 08:42:22 |
| testInitFromFile | PASS | 0.001s | 2026-01-06 08:42:22 |
| testSortFoldersFirst | PASS | 0.001s | 2026-01-06 08:42:22 |

### FileListDataSourceTests
| Test | Status | Duration | Last Run |
| --- | --- | --- | --- |
| testLoadDirectory | PASS | 0.002s | 2026-01-06 08:42:22 |
| testLoadDirectoryExcludesHidden | PASS | 0.001s | 2026-01-06 08:42:22 |
| testLoadDirectoryHandlesEmptyDirectory | PASS | 0.001s | 2026-01-06 08:42:22 |
| testLoadDirectorySortsAlphabetically | PASS | 0.002s | 2026-01-06 08:42:22 |
| testLoadDirectorySortsFoldersFirst | PASS | 0.001s | 2026-01-06 08:42:22 |

### FileOperationQueueTests
| Test | Status | Duration | Last Run |
| --- | --- | --- | --- |
| testCopyDirectory | PASS | 0.003s | 2026-01-06 08:42:22 |
| testCopyFile | PASS | 0.002s | 2026-01-06 08:42:22 |
| testCopyMultipleConflicts | PASS | 0.002s | 2026-01-06 08:42:22 |
| testCopyToSameDirectory | PASS | 0.002s | 2026-01-06 08:42:22 |
| testCreateFolderNameCollision | PASS | 0.002s | 2026-01-06 08:42:22 |
| testCreateFolder | PASS | 0.001s | 2026-01-06 08:42:22 |
| testDeleteFile | PASS | 0.458s | 2026-01-06 08:42:23 |
| testDuplicateFile | PASS | 0.007s | 2026-01-06 08:42:23 |
| testDuplicateMultiple | PASS | 0.003s | 2026-01-06 08:42:23 |
| testMoveFile | PASS | 0.002s | 2026-01-06 08:42:23 |
| testRenameFile | PASS | 0.002s | 2026-01-06 08:42:23 |
| testRenameInvalidCharacters | PASS | 0.002s | 2026-01-06 08:42:23 |
| testRenameToExistingName | PASS | 0.002s | 2026-01-06 08:42:23 |

### PaneTabTests
| Test | Status | Duration | Last Run |
| --- | --- | --- | --- |
| testCanGoBackWhenStackEmpty | PASS | 0.001s | 2026-01-06 08:42:23 |
| testCanGoBackWhenStackHasItems | PASS | 0.024s | 2026-01-06 08:42:23 |
| testGoBackMovesToForwardStack | PASS | 0.002s | 2026-01-06 08:42:23 |
| testGoForwardMovesFromForwardStack | PASS | 0.001s | 2026-01-06 08:42:23 |
| testGoUpAtRootReturnsFalse | PASS | 0.001s | 2026-01-06 08:42:23 |
| testGoUpNavigatesToParent | PASS | 0.001s | 2026-01-06 08:42:23 |
| testInitialState | PASS | 0.001s | 2026-01-06 08:42:23 |
| testNavigateAddsToBackStack | PASS | 0.001s | 2026-01-06 08:42:23 |
| testNavigateClearsForwardStack | PASS | 0.001s | 2026-01-06 08:42:23 |
| testTitleReturnsLastComponent | PASS | 0.001s | 2026-01-06 08:42:23 |

### PaneViewControllerTests
| Test | Status | Duration | Last Run |
| --- | --- | --- | --- |
| testCloseLastTabCreatesNewHome | PASS | 0.606s | 2026-01-06 08:42:23 |
| testCloseTabRemovesFromArray | PASS | 0.018s | 2026-01-06 08:42:23 |
| testCloseTabSelectsLeftWhenNoRight | PASS | 0.026s | 2026-01-06 08:42:23 |
| testCloseTabSelectsRightNeighbor | PASS | 0.025s | 2026-01-06 08:42:24 |
| testCreateTabAddsToArray | PASS | 0.015s | 2026-01-06 08:42:24 |
| testCreateTabSelectsNewTab | PASS | 0.015s | 2026-01-06 08:42:24 |
| testSelectNextTabWraps | PASS | 0.022s | 2026-01-06 08:42:24 |
| testSelectPreviousTabWraps | PASS | 0.025s | 2026-01-06 08:42:24 |

## Notes
- Fixes during this run: pasteboard item cloning in clipboard tests; URL normalization and path-only comparison in PaneTab tests; tab selection expectations updated in PaneViewController tests.
- Per-test timestamps are derived from the run start time plus reported durations in xcresult order.
