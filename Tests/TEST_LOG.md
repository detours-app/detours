# Test Log

## Latest Run
- Started: 2026-01-13 12:35:18
- Command: `swift test --filter SystemKeyHandlerTests`
- Status: PASS
- Tests: 4 passed
- Full suite: 19 test classes, 190 tests, ALL PASS

### DirectoryWatcherTests (Swift Testing)
| Test | Status | Duration | Last Run |
| --- | --- | --- | --- |
| Detects file creation | PASS | 0.008s | 2026-01-13 12:27:35 |
| Detects file deletion | PASS | 0.008s | 2026-01-13 12:27:35 |
| Detects file rename | PASS | 0.008s | 2026-01-13 12:27:35 |
| Stop prevents further callbacks | PASS | 0.534s | 2026-01-13 12:27:35 |

### ClipboardManagerTests
| Test | Status | Duration | Last Run |
| --- | --- | --- | --- |
| testClearResetsState | PASS | 0.009s | 2026-01-13 12:27:04 |
| testCopyClearsIsCutFlag | PASS | 0.002s | 2026-01-13 12:27:04 |
| testCopyWritesToPasteboard | PASS | 0.001s | 2026-01-13 12:27:04 |
| testCutPopulatesCutItemURLs | PASS | 0.001s | 2026-01-13 12:27:04 |
| testCutSetsIsCutFlag | PASS | 0.001s | 2026-01-13 12:27:04 |
| testHasItemsFalse | PASS | 0.000s | 2026-01-13 12:27:04 |
| testHasItemsTrue | PASS | 0.001s | 2026-01-13 12:27:04 |
| testIsItemCut | PASS | 0.001s | 2026-01-13 12:27:04 |

### FileItemTests
| Test | Status | Duration | Last Run |
| --- | --- | --- | --- |
| testFormattedDateDifferentYear | PASS | 0.005s | 2026-01-13 12:28:24 |
| testFormattedDateSameYear | PASS | 0.000s | 2026-01-13 12:28:24 |
| testFormattedDateUsesCurrentYearSetting | PASS | 0.000s | 2026-01-13 12:28:24 |
| testFormattedDateUsesOtherYearsSetting | PASS | 0.000s | 2026-01-13 12:28:24 |
| testFormattedSizeBytes | PASS | 0.000s | 2026-01-13 12:28:24 |
| testFormattedSizeGB | PASS | 0.000s | 2026-01-13 12:28:24 |
| testFormattedSizeKB | PASS | 0.000s | 2026-01-13 12:28:24 |
| testFormattedSizeMB | PASS | 0.000s | 2026-01-13 12:28:24 |
| testInitFromDirectory | PASS | 0.009s | 2026-01-13 12:28:24 |
| testInitFromFile | PASS | 0.001s | 2026-01-13 12:28:24 |
| testSortFoldersFirst | PASS | 0.000s | 2026-01-13 12:28:24 |

### FileListDataSourceTests
| Test | Status | Duration | Last Run |
| --- | --- | --- | --- |
| testLoadDirectory | PASS | 0.013s | 2026-01-13 12:28:51 |
| testLoadDirectoryExcludesHidden | PASS | 0.002s | 2026-01-13 12:28:51 |
| testLoadDirectoryHandlesEmptyDirectory | PASS | 0.001s | 2026-01-13 12:28:51 |
| testLoadDirectorySortsAlphabetically | PASS | 0.003s | 2026-01-13 12:28:51 |
| testLoadDirectorySortsFoldersFirst | PASS | 0.001s | 2026-01-13 12:28:51 |

### FileListResponderTests
| Test | Status | Duration | Last Run |
| --- | --- | --- | --- |
| testCmdLeftKeyEventOnSecondViewControllerGoesToItsDelegate | PASS | 0.099s | 2026-01-13 12:29:13 |
| testCmdRightKeyEventOnSecondViewControllerGoesToItsDelegate | PASS | 0.008s | 2026-01-13 12:29:13 |
| testCmdUpKeyEventOnSecondViewControllerGoesToItsDelegate | PASS | 0.008s | 2026-01-13 12:29:13 |
| testCopyPathWithMultipleSelectionJoinsWithNewlines | PASS | 0.005s | 2026-01-13 12:29:13 |
| testGoBackActionCallsNavigationDelegate | PASS | 0.005s | 2026-01-13 12:29:13 |
| testGoForwardActionCallsNavigationDelegate | PASS | 0.004s | 2026-01-13 12:29:13 |
| testGoUpActionCallsNavigationDelegate | PASS | 0.005s | 2026-01-13 12:29:13 |
| testHandleKeyDownHandlesCmdDDuplicate | PASS | 0.079s | 2026-01-13 12:29:13 |
| testHandleKeyDownHandlesCmdOptionCCopyPath | PASS | 0.005s | 2026-01-13 12:29:13 |
| testHandleKeyDownHandlesCmdRRefresh | PASS | 0.006s | 2026-01-13 12:29:13 |
| testHandleKeyDownHandlesCmdUpParentNavigation | PASS | 0.004s | 2026-01-13 12:29:13 |
| testHandleKeyDownHandlesCopyShortcut | PASS | 0.006s | 2026-01-13 12:29:13 |
| testHandleKeyDownHandlesCutShortcut | PASS | 0.006s | 2026-01-13 12:29:13 |
| testHandleKeyDownHandlesF2RenameShortcut | PASS | 0.007s | 2026-01-13 12:29:13 |
| testHandleKeyDownHandlesF5CopyToOtherPane | PASS | 0.004s | 2026-01-13 12:29:13 |
| testHandleKeyDownHandlesF6MoveToOtherPaneShortcut | PASS | 0.005s | 2026-01-13 12:29:13 |
| testHandleKeyDownHandlesF7NewFolder | PASS | 0.057s | 2026-01-13 12:29:13 |
| testHandleKeyDownHandlesF7NewFolderInCurrentDirectoryWithSelectedFolder | PASS | 0.057s | 2026-01-13 12:29:13 |
| testHandleKeyDownHandlesF8Delete | PASS | 0.059s | 2026-01-13 12:29:13 |
| testHandleKeyDownHandlesPasteShortcutMovesItems | PASS | 0.058s | 2026-01-13 12:29:13 |
| testHandleKeyDownHandlesShiftEnterRenameShortcut | PASS | 0.005s | 2026-01-13 12:29:13 |
| testMenuValidationDisabledWithNoSelection | PASS | 0.005s | 2026-01-13 12:29:13 |
| testMenuValidationForCmdIGetInfo | PASS | 0.005s | 2026-01-13 12:29:13 |
| testMenuValidationForCopyDeleteAndPaste | PASS | 0.005s | 2026-01-13 12:29:13 |
| testMenuValidationForGetInfoCopyPathShowInFinder | PASS | 0.005s | 2026-01-13 12:29:13 |
| testNavigationActionsUseCorrectDelegate | PASS | 0.008s | 2026-01-13 12:29:13 |
| testPasteNotifiesRefreshSourceDirectoriesAfterCut | PASS | 0.058s | 2026-01-13 12:29:13 |
| testPerformKeyEquivalentOnlyHandlesWhenFirstResponder | PASS | 0.029s | 2026-01-13 12:29:13 |
| testTableViewIsInViewControllerHierarchy | PASS | 0.004s | 2026-01-13 12:29:13 |

### FileOpenHelperTests
| Test | Status | Duration | Last Run |
| --- | --- | --- | --- |
| testDiskImageExtensionsContainsExpectedTypes | PASS | 0.002s | 2026-01-13 12:30:01 |
| testDiskImageExtensionsCount | PASS | 0.000s | 2026-01-13 12:30:01 |
| testIsDiskImageDMG | PASS | 0.000s | 2026-01-13 12:30:01 |
| testIsDiskImageDMGUppercase | PASS | 0.000s | 2026-01-13 12:30:01 |
| testIsDiskImageISO | PASS | 0.000s | 2026-01-13 12:30:01 |
| testIsDiskImageMixedCase | PASS | 0.000s | 2026-01-13 12:30:01 |
| testIsDiskImageSparsebundle | PASS | 0.000s | 2026-01-13 12:30:01 |
| testIsDiskImageSparseimage | PASS | 0.000s | 2026-01-13 12:30:01 |
| testIsNotDiskImageApp | PASS | 0.000s | 2026-01-13 12:30:01 |
| testIsNotDiskImageDmgInPath | PASS | 0.000s | 2026-01-13 12:30:01 |
| testIsNotDiskImageNoExtension | PASS | 0.000s | 2026-01-13 12:30:01 |
| testIsNotDiskImagePDF | PASS | 0.000s | 2026-01-13 12:30:01 |
| testIsNotDiskImageTxt | PASS | 0.000s | 2026-01-13 12:30:01 |
| testIsNotDiskImageZip | PASS | 0.000s | 2026-01-13 12:30:01 |

### FileOperationQueueTests
| Test | Status | Duration | Last Run |
| --- | --- | --- | --- |
| testCopyDirectory | PASS | 0.005s | 2026-01-13 12:30:31 |
| testCopyFile | PASS | 0.002s | 2026-01-13 12:30:31 |
| testCopyMultipleConflicts | PASS | 0.002s | 2026-01-13 12:30:31 |
| testCopyToSameDirectory | PASS | 0.001s | 2026-01-13 12:30:31 |
| testCreateFolder | PASS | 0.001s | 2026-01-13 12:30:31 |
| testCreateFolderNameCollision | PASS | 0.001s | 2026-01-13 12:30:31 |
| testDeleteFile | PASS | 0.014s | 2026-01-13 12:30:31 |
| testDuplicateFile | PASS | 0.001s | 2026-01-13 12:30:31 |
| testDuplicateMultiple | PASS | 0.002s | 2026-01-13 12:30:31 |
| testMoveFile | PASS | 0.002s | 2026-01-13 12:30:31 |
| testRenameFile | PASS | 0.001s | 2026-01-13 12:30:31 |
| testRenameInvalidCharacters | PASS | 0.001s | 2026-01-13 12:30:31 |
| testRenameToExistingName | PASS | 0.001s | 2026-01-13 12:30:31 |

### PaneTabTests
| Test | Status | Duration | Last Run |
| --- | --- | --- | --- |
| testCanGoBackWhenStackEmpty | PASS | 0.002s | 2026-01-13 12:32:18 |
| testCanGoBackWhenStackHasItems | PASS | 0.030s | 2026-01-13 12:32:18 |
| testGoBackMovesToForwardStack | PASS | 0.001s | 2026-01-13 12:32:18 |
| testGoForwardMovesFromForwardStack | PASS | 0.001s | 2026-01-13 12:32:18 |
| testGoUpAtRootReturnsFalse | PASS | 0.000s | 2026-01-13 12:32:18 |
| testGoUpNavigatesToParent | PASS | 0.001s | 2026-01-13 12:32:18 |
| testInitialState | PASS | 0.000s | 2026-01-13 12:32:18 |
| testNavigateAddsToBackStack | PASS | 0.001s | 2026-01-13 12:32:18 |
| testNavigateClearsForwardStack | PASS | 0.001s | 2026-01-13 12:32:18 |
| testTitleReturnsLastComponent | PASS | 0.000s | 2026-01-13 12:32:18 |

### PaneViewControllerTests
| Test | Status | Duration | Last Run |
| --- | --- | --- | --- |
| testCloseLastTabCreatesNewHome | PASS | 0.147s | 2026-01-13 12:32:42 |
| testCloseTabRemovesFromArray | PASS | 0.033s | 2026-01-13 12:32:42 |
| testCloseTabSelectsLeftWhenNoRight | PASS | 0.046s | 2026-01-13 12:32:42 |
| testCloseTabSelectsRightNeighbor | PASS | 0.045s | 2026-01-13 12:32:42 |
| testCreateTabAddsToArray | PASS | 0.030s | 2026-01-13 12:32:42 |
| testCreateTabSelectsNewTab | PASS | 0.029s | 2026-01-13 12:32:42 |
| testSelectNextTabWraps | PASS | 0.041s | 2026-01-13 12:32:42 |
| testSelectPreviousTabWraps | PASS | 0.043s | 2026-01-13 12:32:42 |

### SystemKeyHandlerTests
| Test | Status | Duration | Last Run |
| --- | --- | --- | --- |
| testGlobalKeyDownF5TriggersCopyToOtherPane | PASS | 0.164s | 2026-01-13 12:35:18 |
| testSystemDefinedDictationKeyTriggersCopyToOtherPane | PASS | 0.064s | 2026-01-13 12:35:18 |
| testSystemDefinedF5KeyTriggersCopyToOtherPane | PASS | 0.069s | 2026-01-13 12:35:18 |
| testSystemMediaKeyCodeParsingDetectsKeyDown | PASS | 0.000s | 2026-01-13 12:35:18 |

### FrecencyStoreTests
| Test | Status | Duration | Last Run |
| --- | --- | --- | --- |
| testFrecencyScoreDecaysOverTime | PASS | 0.004s | 2026-01-13 12:30:59 |
| testLoadSaveRoundTrip | PASS | 0.003s | 2026-01-13 12:30:59 |
| testNonDirectoryExcluded | PASS | 0.001s | 2026-01-13 12:30:59 |
| testRecordVisitCreatesEntry | PASS | 0.001s | 2026-01-13 12:30:59 |
| testRecordVisitIncrementsCount | PASS | 0.001s | 2026-01-13 12:30:59 |
| testRecordVisitUpdatesLastVisit | PASS | 0.107s | 2026-01-13 12:30:59 |
| testSubstringMatchCaseInsensitive | PASS | 0.001s | 2026-01-13 12:30:59 |
| testSubstringMatchPartialName | PASS | 0.001s | 2026-01-13 12:30:59 |
| testSubstringMatchRequiresContiguousCharacters | PASS | 0.001s | 2026-01-13 12:30:59 |
| testTildeExpansion | PASS | 0.001s | 2026-01-13 12:30:59 |
| testTopDirectoriesLimit | PASS | 0.006s | 2026-01-13 12:30:59 |
| testTopDirectoriesSortedByFrecency | PASS | 0.002s | 2026-01-13 12:30:59 |

### QuickNavTests
| Test | Status | Duration | Last Run |
| --- | --- | --- | --- |
| testTopDirectoriesExcludesDeletedDirectories | PASS | 0.004s | 2026-01-13 12:33:42 |
| testTopDirectoriesReturnsURLsNotStrings | PASS | 0.001s | 2026-01-13 12:33:42 |
| testTopDirectoriesWithEmptyQueryReturnsAllEntries | PASS | 0.001s | 2026-01-13 12:33:42 |
| testTopDirectoriesWithQueryFiltersResults | PASS | 0.002s | 2026-01-13 12:33:42 |
| testTopDirectoriesWithQueryMatchesPartialName | PASS | 0.001s | 2026-01-13 12:33:42 |

### SidebarTests
| Test | Status | Duration | Last Run |
| --- | --- | --- | --- |
| testSettingsFavoritesDefault | PASS | 0.001s | 2026-01-13 12:34:06 |
| testSettingsFavoritesPersistence | PASS | 0.001s | 2026-01-13 12:34:06 |
| testSettingsSidebarVisibleDefault | PASS | 0.000s | 2026-01-13 12:34:06 |
| testShortcutManagerToggleSidebarDefault | PASS | 0.001s | 2026-01-13 12:34:06 |
| testSidebarItemEquality | PASS | 0.001s | 2026-01-13 12:34:06 |
| testVolumeCapacityFormatting | PASS | 0.000s | 2026-01-13 12:34:06 |
| testVolumeInfoProperties | PASS | 0.004s | 2026-01-13 12:34:06 |
| testVolumeMonitorReturnsVolumes | PASS | 0.000s | 2026-01-13 12:34:06 |

### SplitPositionTests
| Test | Status | Duration | Last Run |
| --- | --- | --- | --- |
| testCollapsedSidebar | PASS | 0.001s | 2026-01-13 12:34:31 |
| testDividerPositionFromRatio | PASS | 0.000s | 2026-01-13 12:34:31 |
| testLargeRatio | PASS | 0.000s | 2026-01-13 12:34:31 |
| testMissingDefaults | PASS | 0.002s | 2026-01-13 12:34:31 |
| testRatioCalculation | PASS | 0.000s | 2026-01-13 12:34:31 |
| testRatioIndependentOfSidebarWidth | PASS | 0.000s | 2026-01-13 12:34:31 |
| testRatioPersistence | PASS | 0.000s | 2026-01-13 12:34:31 |
| testRoundTrip | PASS | 0.000s | 2026-01-13 12:34:31 |
| testSidebarWidthPersistence | PASS | 0.000s | 2026-01-13 12:34:31 |
| testSmallRatio | PASS | 0.000s | 2026-01-13 12:34:31 |

### SystemIntegrationTests
| Test | Status | Duration | Last Run |
| --- | --- | --- | --- |
| testContextMenuBuildsForFile | PASS | 0.149s | 2026-01-13 12:34:54 |
| testContextMenuBuildsForFolder | PASS | 0.006s | 2026-01-13 12:34:54 |
| testContextMenuBuildsForMultipleSelection | PASS | 0.006s | 2026-01-13 12:34:54 |
| testDragPasteboardContainsFileURLs | PASS | 0.005s | 2026-01-13 12:34:54 |
| testDropTargetRowTracking | PASS | 0.001s | 2026-01-13 12:34:54 |
| testOpenWithAppsForImage | PASS | 0.003s | 2026-01-13 12:34:54 |
| testOpenWithAppsForTextFile | PASS | 0.002s | 2026-01-13 12:34:54 |

### DroppablePathControlTests
| Test | Status | Duration | Last Run |
| --- | --- | --- | --- |
| testCalculateItemRectsReturnsRectForEachItem | PASS | 0.000s | 2026-01-13 12:27:58 |
| testCalculateItemRectsAreContiguous | PASS | 0.044s | 2026-01-13 12:27:58 |
| testPathItemIndexReturnsCorrectIndex | PASS | 0.000s | 2026-01-13 12:27:58 |
| testPathItemIndexReturnsNilForPointOutsideItems | PASS | 0.000s | 2026-01-13 12:27:58 |
| testPathItemIndexReturnsNilForEmptyPathItems | PASS | 0.000s | 2026-01-13 12:27:58 |

### HousekeepingTests
| Test | Status | Duration | Last Run |
| --- | --- | --- | --- |
| testAboutPanelVersion | PASS | 0.000s | 2026-01-13 12:31:53 |
| testFileMenuHasRevealInFinder | PASS | 0.000s | 2026-01-13 12:31:53 |
| testGoMenuHasKeyboardShortcuts | PASS | 0.000s | 2026-01-13 12:31:53 |
| testLoadDirectoryIncludesHiddenFilesWhenTrue | PASS | 0.011s | 2026-01-13 12:31:53 |
| testLoadDirectorySkipsHiddenFilesWhenFalse | PASS | 0.002s | 2026-01-13 12:31:53 |
| testShowHiddenFilesCanBeToggled | PASS | 0.000s | 2026-01-13 12:31:53 |
| testShowHiddenFilesDefaultsToFalse | PASS | 0.000s | 2026-01-13 12:31:53 |
| testViewMenuHasToggleHiddenFiles | PASS | 0.000s | 2026-01-13 12:31:53 |

### PreferencesTests
| Test | Status | Duration | Last Run |
| --- | --- | --- | --- |
| testCodableColorFromHex | PASS | 0.005s | 2026-01-13 12:33:07 |
| testCodableColorHexRoundtrip | PASS | 0.002s | 2026-01-13 12:33:07 |
| testDateFormatSettingsDefaults | PASS | 0.002s | 2026-01-13 12:33:07 |
| testDateFormatSettingsPersistence | PASS | 0.003s | 2026-01-13 12:33:07 |
| testFontSizeClamping | PASS | 0.002s | 2026-01-13 12:33:07 |
| testGitStatusColors | PASS | 0.005s | 2026-01-13 12:33:07 |
| testKeyComboDisplayString | PASS | 0.002s | 2026-01-13 12:33:07 |
| testKeyComboMatches | PASS | 0.002s | 2026-01-13 12:33:07 |
| testSettingsCodable | PASS | 0.001s | 2026-01-13 12:33:07 |
| testSettingsEquatable | PASS | 0.001s | 2026-01-13 12:33:07 |
| testSettingsManagerDefaults | PASS | 0.001s | 2026-01-13 12:33:07 |
| testSettingsManagerPersistence | PASS | 0.002s | 2026-01-13 12:33:07 |
| testShortcutActionDisplayNames | PASS | 0.001s | 2026-01-13 12:33:07 |
| testShortcutManagerCustomOverride | PASS | 0.002s | 2026-01-13 12:33:07 |
| testShortcutManagerDefaults | PASS | 0.002s | 2026-01-13 12:33:07 |
| testShortcutManagerKeyEquivalent | PASS | 0.002s | 2026-01-13 12:33:07 |
| testShortcutManagerRestoreDefaults | PASS | 0.002s | 2026-01-13 12:33:07 |
| testThemeChoiceDisplayNames | PASS | 0.002s | 2026-01-13 12:33:07 |
| testThemeChoiceSystemResolvesToLightOrDark | PASS | 0.002s | 2026-01-13 12:33:07 |
| testThemeFontReturnsValidFont | PASS | 0.013s | 2026-01-13 12:33:07 |
| testThemeManagerBuiltInThemes | PASS | 0.002s | 2026-01-13 12:33:07 |
| testThemeManagerCustomTheme | PASS | 0.001s | 2026-01-13 12:33:07 |

### GitStatusTests
| Test | Status | Duration | Last Run |
| --- | --- | --- | --- |
| testFileItemGitStatusProperty | PASS | 0.001s | 2026-01-13 12:31:30 |
| testFileItemURLInitHasNilGitStatus | PASS | 0.007s | 2026-01-13 12:31:30 |
| testGitStatusCaching | PASS | 0.041s | 2026-01-13 12:31:30 |
| testGitStatusInGitRepo | PASS | 0.001s | 2026-01-13 12:31:30 |
| testGitStatusInvalidateCache | PASS | 0.044s | 2026-01-13 12:31:30 |
| testGitStatusNonRepo | PASS | 0.013s | 2026-01-13 12:31:30 |

## Notes
- 2026-01-13: Full test suite run (190 tests in 19 classes). All pass. New test classes: FileOpenHelperTests (14), SidebarTests (8), SplitPositionTests (10). New tests: 2 in FileItemTests (date format settings), 2 in PreferencesTests (date format settings). Test names renamed in SystemKeyHandlerTests and FileListResponderTests.
- 2026-01-08: Added ThemeManager tests (4 tests): built-in themes, custom theme, system choice, font validation.
- 2026-01-08: Added GitStatusTests (6 tests) for Phase 6 git integration: non-repo handling, caching, FileItem property.
- 2026-01-08: Added testGitStatusColors to PreferencesTests for git status color verification.
- 2026-01-08: Fixed testTableViewNextResponderIsViewController - renamed to testTableViewIsInViewControllerHierarchy, checks view hierarchy instead of responder chain (which requires a window).
- 2026-01-08: Added ShortcutManager tests (4 tests) for Phase 5 keyboard shortcuts: defaults, custom override, restore defaults, key equivalents.
- 2026-01-07: Added PreferencesTests (11 tests) for Stage 6 settings infrastructure, SettingsManager, KeyCombo, CodableColor.
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
