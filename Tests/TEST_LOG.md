# Test Log

## Latest Run
- Started: 2026-01-06 10:55:21
- Ended: 2026-01-06 10:55:22
- Command: `xcodebuild test -scheme Detour -destination 'platform=macOS'`
- Status: PASS
- Total tests: 71

### ClipboardManagerTests
| Test | Status | Duration | Last Run |
| --- | --- | --- | --- |
| testClearResetsState | PASS | 0.010s | 2026-01-06 10:55:21 |
| testCopyClearsIsCutFlag | PASS | 0.003s | 2026-01-06 10:55:21 |
| testCopyWritesToPasteboard | PASS | 0.002s | 2026-01-06 10:55:21 |
| testCutPopulatesCutItemURLs | PASS | 0.002s | 2026-01-06 10:55:21 |
| testCutSetsIsCutFlag | PASS | 0.002s | 2026-01-06 10:55:21 |
| testHasItemsFalse | PASS | 0.001s | 2026-01-06 10:55:21 |
| testHasItemsTrue | PASS | 0.002s | 2026-01-06 10:55:21 |
| testIsItemCut | PASS | 0.002s | 2026-01-06 10:55:21 |

### FileItemTests
| Test | Status | Duration | Last Run |
| --- | --- | --- | --- |
| testFormattedDateDifferentYear | PASS | 0.001s | 2026-01-06 10:55:21 |
| testFormattedDateSameYear | PASS | 0.001s | 2026-01-06 10:55:21 |
| testFormattedSizeBytes | PASS | 0.001s | 2026-01-06 10:55:21 |
| testFormattedSizeGB | PASS | 0.000s | 2026-01-06 10:55:21 |
| testFormattedSizeKB | PASS | 0.000s | 2026-01-06 10:55:21 |
| testFormattedSizeMB | PASS | 0.001s | 2026-01-06 10:55:21 |
| testInitFromDirectory | PASS | 0.002s | 2026-01-06 10:55:21 |
| testInitFromFile | PASS | 0.001s | 2026-01-06 10:55:21 |
| testSortFoldersFirst | PASS | 0.001s | 2026-01-06 10:55:21 |

### FileListDataSourceTests
| Test | Status | Duration | Last Run |
| --- | --- | --- | --- |
| testLoadDirectory | PASS | 0.002s | 2026-01-06 10:55:21 |
| testLoadDirectoryExcludesHidden | PASS | 0.001s | 2026-01-06 10:55:21 |
| testLoadDirectoryHandlesEmptyDirectory | PASS | 0.001s | 2026-01-06 10:55:21 |
| testLoadDirectorySortsAlphabetically | PASS | 0.002s | 2026-01-06 10:55:21 |
| testLoadDirectorySortsFoldersFirst | PASS | 0.001s | 2026-01-06 10:55:21 |

### FileListResponderTests
| Test | Status | Duration | Last Run |
| --- | --- | --- | --- |
| testHandleKeyDownHandlesCmdDDuplicate | PASS | 0.104s | 2026-01-06 10:55:21 |
| testHandleKeyDownHandlesCmdRRefresh | PASS | 0.007s | 2026-01-06 10:55:21 |
| testHandleKeyDownHandlesCopyShortcut | PASS | 0.005s | 2026-01-06 10:55:21 |
| testHandleKeyDownHandlesCutShortcut | PASS | 0.005s | 2026-01-06 10:55:21 |
| testHandleKeyDownHandlesF2RenameShortcut | PASS | 0.007s | 2026-01-06 10:55:21 |
| testHandleKeyDownHandlesF5CopyShortcut | PASS | 0.004s | 2026-01-06 10:55:21 |
| testHandleKeyDownHandlesF6MoveToOtherPaneShortcut | PASS | 0.004s | 2026-01-06 10:55:21 |
| testHandleKeyDownHandlesF7NewFolder | PASS | 0.056s | 2026-01-06 10:55:21 |
| testHandleKeyDownHandlesF8Delete | PASS | 0.061s | 2026-01-06 10:55:21 |
| testHandleKeyDownHandlesPasteShortcutMovesItems | PASS | 0.061s | 2026-01-06 10:55:21 |
| testHandleKeyDownHandlesShiftEnterRenameShortcut | PASS | 0.006s | 2026-01-06 10:55:21 |
| testMenuValidationForCopyDeleteAndPaste | PASS | 0.006s | 2026-01-06 10:55:21 |
| testPasteNotifiesRefreshSourceDirectoriesAfterCut | PASS | 0.061s | 2026-01-06 10:55:21 |
| testTableViewNextResponderIsViewController | PASS | 0.007s | 2026-01-06 10:55:21 |

### FileOperationQueueTests
| Test | Status | Duration | Last Run |
| --- | --- | --- | --- |
| testCopyDirectory | PASS | 0.004s | 2026-01-06 10:55:21 |
| testCopyFile | PASS | 0.003s | 2026-01-06 10:55:21 |
| testCopyMultipleConflicts | PASS | 0.003s | 2026-01-06 10:55:21 |
| testCopyToSameDirectory | PASS | 0.002s | 2026-01-06 10:55:21 |
| testCreateFolderNameCollision | PASS | 0.002s | 2026-01-06 10:55:21 |
| testCreateFolder | PASS | 0.001s | 2026-01-06 10:55:21 |
| testDeleteFile | PASS | 0.002s | 2026-01-06 10:55:21 |
| testDuplicateFile | PASS | 0.002s | 2026-01-06 10:55:21 |
| testDuplicateMultiple | PASS | 0.002s | 2026-01-06 10:55:21 |
| testMoveFile | PASS | 0.002s | 2026-01-06 10:55:21 |
| testRenameFile | PASS | 0.001s | 2026-01-06 10:55:21 |
| testRenameInvalidCharacters | PASS | 0.001s | 2026-01-06 10:55:21 |
| testRenameToExistingName | PASS | 0.001s | 2026-01-06 10:55:21 |

### PaneTabTests
| Test | Status | Duration | Last Run |
| --- | --- | --- | --- |
| testCanGoBackWhenStackEmpty | PASS | 0.001s | 2026-01-06 10:55:21 |
| testCanGoBackWhenStackHasItems | PASS | 0.001s | 2026-01-06 10:55:21 |
| testGoBackMovesToForwardStack | PASS | 0.001s | 2026-01-06 10:55:21 |
| testGoForwardMovesFromForwardStack | PASS | 0.001s | 2026-01-06 10:55:21 |
| testGoUpAtRootReturnsFalse | PASS | 0.001s | 2026-01-06 10:55:21 |
| testGoUpNavigatesToParent | PASS | 0.001s | 2026-01-06 10:55:21 |
| testInitialState | PASS | 0.001s | 2026-01-06 10:55:21 |
| testNavigateAddsToBackStack | PASS | 0.001s | 2026-01-06 10:55:21 |
| testNavigateClearsForwardStack | PASS | 0.001s | 2026-01-06 10:55:21 |
| testTitleReturnsLastComponent | PASS | 0.001s | 2026-01-06 10:55:21 |

### PaneViewControllerTests
| Test | Status | Duration | Last Run |
| --- | --- | --- | --- |
| testCloseLastTabCreatesNewHome | PASS | 0.530s | 2026-01-06 10:55:21 |
| testCloseTabRemovesFromArray | PASS | 0.029s | 2026-01-06 10:55:22 |
| testCloseTabSelectsLeftWhenNoRight | PASS | 0.029s | 2026-01-06 10:55:22 |
| testCloseTabSelectsRightNeighbor | PASS | 0.024s | 2026-01-06 10:55:22 |
| testCreateTabAddsToArray | PASS | 0.015s | 2026-01-06 10:55:22 |
| testCreateTabSelectsNewTab | PASS | 0.015s | 2026-01-06 10:55:22 |
| testSelectNextTabWraps | PASS | 0.023s | 2026-01-06 10:55:22 |
| testSelectPreviousTabWraps | PASS | 0.024s | 2026-01-06 10:55:22 |

### SystemKeyHandlerTests
| Test | Status | Duration | Last Run |
| --- | --- | --- | --- |
| testGlobalKeyDownF5TriggersCopy | PASS | 0.019s | 2026-01-06 10:55:22 |
| testSystemDefinedDictationKeyTriggersCopy | PASS | 0.017s | 2026-01-06 10:55:22 |
| testSystemDefinedF5KeyTriggersCopy | PASS | 0.018s | 2026-01-06 10:55:22 |
| testSystemMediaKeyCodeParsingDetectsKeyDown | PASS | 0.001s | 2026-01-06 10:55:22 |

## Notes
- 2026-01-06 10:25:43: Added system-defined media key handling for the dictation key (F5 on many keyboards) and tests for the path.
- 2026-01-06 10:25:43: Per-test timestamps are derived from the run start time plus reported durations in xcresult order.
- 2026-01-06 10:55:22: Added F5 system-defined and global key-down coverage in SystemKeyHandlerTests.
- 2026-01-06 10:55:22: SystemMediaKey parsing now uses unsigned data1 to avoid sign issues.
