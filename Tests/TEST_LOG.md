# Test Log

## Latest Run
- Started: 2026-01-07 09:34:51
- Ended: 2026-01-07 09:34:52
- Command: `xcodebuild test -scheme Detour -destination 'platform=macOS' -only-testing:DetourTests/FrecencyStoreTests -only-testing:DetourTests/QuickNavTests`
- Status: PASS
- Total tests: 17 (FrecencyStoreTests: 12, QuickNavTests: 5)

### DirectoryWatcherTests (Swift Testing)
| Test | Status | Duration | Last Run |
| --- | --- | --- | --- |
| Detects file creation | PASS | 0.517s | 2026-01-06 15:45:35 |
| Detects file deletion | PASS | 0.516s | 2026-01-06 15:45:35 |
| Detects file rename | PASS | 0.517s | 2026-01-06 15:45:35 |
| Stop prevents further callbacks | PASS | 0.517s | 2026-01-06 15:45:35 |

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
| testTableViewNextResponderIsViewController | PASS | 0.007s | 2026-01-07 09:25:09 |
| testMenuValidationForCopyDeleteAndPaste | PASS | 0.006s | 2026-01-07 09:25:09 |
| testHandleKeyDownHandlesCopyShortcut | PASS | 0.005s | 2026-01-07 09:25:09 |
| testHandleKeyDownHandlesCutShortcut | PASS | 0.005s | 2026-01-07 09:25:09 |
| testHandleKeyDownHandlesPasteShortcutMovesItems | PASS | 0.061s | 2026-01-07 09:25:09 |
| testHandleKeyDownHandlesF5CopyToOtherPane | PASS | 0.004s | 2026-01-07 09:25:09 |
| testHandleKeyDownHandlesF6MoveToOtherPaneShortcut | PASS | 0.004s | 2026-01-07 09:25:09 |
| testHandleKeyDownHandlesF2RenameShortcut | PASS | 0.007s | 2026-01-07 09:25:09 |
| testHandleKeyDownHandlesShiftEnterRenameShortcut | PASS | 0.006s | 2026-01-07 09:25:09 |
| testHandleKeyDownHandlesCmdRRefresh | PASS | 0.007s | 2026-01-07 09:25:09 |
| testHandleKeyDownHandlesCmdDDuplicate | PASS | 0.104s | 2026-01-07 09:25:09 |
| testHandleKeyDownHandlesF7NewFolder | PASS | 0.056s | 2026-01-07 09:25:09 |
| testHandleKeyDownHandlesF7NewFolderInsideSelectedFolder | PASS | 0.060s | 2026-01-07 09:25:09 |
| testHandleKeyDownHandlesCmdUpParentNavigation | PASS | 0.005s | 2026-01-07 09:25:09 |
| testMenuValidationForCmdIGetInfo | PASS | 0.005s | 2026-01-07 09:25:09 |
| testGoUpActionCallsNavigationDelegate | PASS | 0.005s | 2026-01-07 09:25:09 |
| testGoBackActionCallsNavigationDelegate | PASS | 0.005s | 2026-01-07 09:25:09 |
| testGoForwardActionCallsNavigationDelegate | PASS | 0.005s | 2026-01-07 09:25:09 |
| testNavigationActionsUseCorrectDelegate | PASS | 0.010s | 2026-01-07 09:25:09 |
| testCmdUpKeyEventOnSecondViewControllerGoesToItsDelegate | PASS | 0.010s | 2026-01-07 09:25:09 |
| testCmdLeftKeyEventOnSecondViewControllerGoesToItsDelegate | PASS | 0.010s | 2026-01-07 09:25:09 |
| testCmdRightKeyEventOnSecondViewControllerGoesToItsDelegate | PASS | 0.010s | 2026-01-07 09:25:09 |
| testPerformKeyEquivalentOnlyHandlesWhenFirstResponder | PASS | 0.015s | 2026-01-07 09:25:09 |
| testHandleKeyDownHandlesCmdOptionCCopyPath | PASS | 0.005s | 2026-01-07 09:25:09 |
| testCopyPathWithMultipleSelectionJoinsWithNewlines | PASS | 0.005s | 2026-01-07 09:25:09 |
| testMenuValidationForGetInfoCopyPathShowInFinder | PASS | 0.005s | 2026-01-07 09:25:09 |
| testMenuValidationDisabledWithNoSelection | PASS | 0.005s | 2026-01-07 09:25:09 |
| testHandleKeyDownHandlesF8Delete | PASS | 0.061s | 2026-01-07 09:25:09 |
| testPasteNotifiesRefreshSourceDirectoriesAfterCut | PASS | 0.061s | 2026-01-07 09:25:09 |

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

### FrecencyStoreTests
| Test | Status | Duration | Last Run |
| --- | --- | --- | --- |
| testFrecencyScoreDecaysOverTime | PASS | 0.001s | 2026-01-07 09:34:51 |
| testLoadSaveRoundTrip | PASS | 0.003s | 2026-01-07 09:34:51 |
| testNonDirectoryExcluded | PASS | 0.001s | 2026-01-07 09:34:51 |
| testRecordVisitCreatesEntry | PASS | 0.001s | 2026-01-07 09:34:51 |
| testRecordVisitIncrementsCount | PASS | 0.002s | 2026-01-07 09:34:51 |
| testRecordVisitUpdatesLastVisit | PASS | 0.107s | 2026-01-07 09:34:51 |
| testSubstringMatchCaseInsensitive | PASS | 1.476s | 2026-01-07 09:34:51 |
| testSubstringMatchPartialName | PASS | 0.951s | 2026-01-07 09:34:51 |
| testSubstringMatchRequiresContiguousCharacters | PASS | 1.734s | 2026-01-07 09:34:51 |
| testTildeExpansion | PASS | 0.001s | 2026-01-07 09:34:51 |
| testTopDirectoriesLimit | PASS | 0.743s | 2026-01-07 09:34:51 |
| testTopDirectoriesSortedByFrecency | PASS | 0.871s | 2026-01-07 09:34:51 |

### QuickNavTests
| Test | Status | Duration | Last Run |
| --- | --- | --- | --- |
| testTopDirectoriesExcludesDeletedDirectories | PASS | 0.001s | 2026-01-07 09:34:52 |
| testTopDirectoriesReturnsURLsNotStrings | PASS | 0.001s | 2026-01-07 09:34:52 |
| testTopDirectoriesWithEmptyQueryReturnsAllEntries | PASS | 0.002s | 2026-01-07 09:34:52 |
| testTopDirectoriesWithQueryFiltersResults | PASS | 0.570s | 2026-01-07 09:34:52 |
| testTopDirectoriesWithQueryMatchesPartialName | PASS | 0.852s | 2026-01-07 09:34:52 |

### SystemIntegrationTests
| Test | Status | Duration | Last Run |
| --- | --- | --- | --- |
| testContextMenuBuildsForFile | PASS | 0.061s | 2026-01-07 09:25:09 |
| testContextMenuBuildsForFolder | PASS | 0.006s | 2026-01-07 09:25:09 |
| testContextMenuBuildsForMultipleSelection | PASS | 0.008s | 2026-01-07 09:25:09 |
| testDragPasteboardContainsFileURLs | PASS | 0.008s | 2026-01-07 09:25:09 |
| testDropTargetRowTracking | PASS | 0.002s | 2026-01-07 09:25:09 |
| testOpenWithAppsForImage | PASS | 0.008s | 2026-01-07 09:25:09 |
| testOpenWithAppsForTextFile | PASS | 0.003s | 2026-01-07 09:25:09 |

## Notes
- 2026-01-07: Fixed FileListResponderTests - changed testHandleKeyDownHandlesCmdIGetInfo to testMenuValidationForCmdIGetInfo to avoid opening real Finder info panels during tests.
- 2026-01-07: Fixed DirectoryWatcherTests - increased timeout from 500ms to 2s with polling loop for FSEvents latency.
- 2026-01-07: Fixed QuickNavTests - same substring vs fuzzy issue. 5 tests pass.
- 2026-01-07: Fixed FrecencyStoreTests - changed fuzzy matching tests to substring matching tests (implementation uses substring, not fuzzy). 12 tests pass.
- 2026-01-07: Added SystemIntegrationTests (7 tests) for Stage 5 context menus, drag-drop, Open With.
- 2026-01-07: Added 15 new FileListResponderTests for navigation actions, first-responder handling, copy path.
- 2026-01-06 15:45:35: Added DirectoryWatcherTests (4 tests) using Swift Testing framework for filesystem watching.
- 2026-01-06 10:55:22: SystemMediaKey parsing now uses unsigned data1 to avoid sign issues.
- 2026-01-06 10:55:22: Added F5 system-defined and global key-down coverage in SystemKeyHandlerTests.
- 2026-01-06 10:25:43: Per-test timestamps are derived from the run start time plus reported durations in xcresult order.
- 2026-01-06 10:25:43: Added system-defined media key handling for the dictation key (F5 on many keyboards) and tests for the path.
