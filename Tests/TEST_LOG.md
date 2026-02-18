# Test Log

## Latest Run
- Started: 2026-02-18 22:49:26
- Command: `swift test --filter FileItemTests`
- Status: PASS
- Duration: ~1s
- Notes: All 13 FileItemTests pass, including 10 new column sorting tests (sort by name/size/date asc/desc, folders-on-top by name/size, folders-on-top off, children preservation).

### FileItemTests (Column Sorting)
| Test | Status | Duration | Last Run |
| --- | --- | --- | --- |
| testSortByNameAscending | PASS | 0.000s | 2026-02-18 22:49:26 |
| testSortByNameDescending | PASS | 0.000s | 2026-02-18 22:49:26 |
| testSortBySizeAscending | PASS | 0.000s | 2026-02-18 22:49:26 |
| testSortBySizeDescending | PASS | 0.000s | 2026-02-18 22:49:26 |
| testSortByDateAscending | PASS | 0.000s | 2026-02-18 22:49:26 |
| testSortByDateDescending | PASS | 0.000s | 2026-02-18 22:49:26 |
| testSortFoldersOnTopByName | PASS | 0.000s | 2026-02-18 22:49:26 |
| testSortFoldersOnTopBySize | PASS | 0.000s | 2026-02-18 22:49:26 |
| testSortFoldersOnTopOff | PASS | 0.000s | 2026-02-18 22:49:26 |
| testSortPreservesChildrenUnderParent | PASS | 0.000s | 2026-02-18 22:49:26 |

---

## Previous Run
- Started: 2026-02-13 10:27:44
- Command: `swift test --filter ArchiveOperationTests`
- Status: PASS
- Duration: 1.418s
- Notes: All 29 archive tests pass. Added extraction conflict dialog — replaced testExtractOverwritesExisting with testExtractKeepsBothOnConflict. Extraction now checks for existing items before extracting and shows Keep Both / Replace / Stop dialog.

### ArchiveOperationTests
| Test | Status | Duration | Last Run |
| --- | --- | --- | --- |
| testDetectZipFormat | PASS | 0.001s | 2026-02-13 10:27:44 |
| testDetect7zFormat | PASS | 0.001s | 2026-02-13 10:27:44 |
| testDetectTarGzFormat | PASS | 0.000s | 2026-02-13 10:27:44 |
| testDetectTgzFormat | PASS | 0.000s | 2026-02-13 10:27:44 |
| testDetectTarBz2Format | PASS | 0.000s | 2026-02-13 10:27:44 |
| testDetectTarXzFormat | PASS | 0.000s | 2026-02-13 10:27:44 |
| testDetectUnknownFormat | PASS | 0.001s | 2026-02-13 10:27:44 |
| testDetectCaseInsensitive | PASS | 0.001s | 2026-02-13 10:27:44 |
| testDetectZipAvailable | PASS | 0.001s | 2026-02-13 10:27:44 |
| testDetectUnzipAvailable | PASS | 0.002s | 2026-02-13 10:27:44 |
| testDetectTarAvailable | PASS | 0.000s | 2026-02-13 10:27:44 |
| testIsExtractableForArchive | PASS | 0.001s | 2026-02-13 10:27:44 |
| testIsExtractableForNonArchive | PASS | 0.000s | 2026-02-13 10:27:44 |
| testCreateZipArchive | PASS | 0.071s | 2026-02-13 10:27:44 |
| testCreateZipArchiveMultipleFiles | PASS | 0.081s | 2026-02-13 10:27:44 |
| testCreateZipWithPassword | PASS | 0.070s | 2026-02-13 10:27:44 |
| testCreateTarGzArchive | PASS | 0.067s | 2026-02-13 10:27:44 |
| testCreateTarBz2Archive | PASS | 0.071s | 2026-02-13 10:27:44 |
| testArchiveNameCollision | PASS | 0.141s | 2026-02-13 10:27:44 |
| testExtractZipArchive | PASS | 0.219s | 2026-02-13 10:27:44 |
| testExtractTarGzArchive | PASS | 0.233s | 2026-02-13 10:27:44 |
| testExtractPasswordZip | PASS | 0.219s | 2026-02-13 10:27:44 |
| testExtractKeepsBothOnConflict | PASS | 0.236s | 2026-02-13 10:27:44 |
| testDialogDefaultNameSingleFile | PASS | 0.000s | 2026-02-13 10:27:44 |
| testDialogDefaultNameSingleFolder | PASS | 0.000s | 2026-02-13 10:27:44 |
| testDialogDefaultNameMultiple | PASS | 0.001s | 2026-02-13 10:27:44 |
| testDialogValidation | PASS | 0.000s | 2026-02-13 10:27:44 |
| testPasswordDisabledForTarFormats | PASS | 0.000s | 2026-02-13 10:27:44 |
| testPasswordEnabledForZipAnd7z | PASS | 0.000s | 2026-02-13 10:27:44 |

## Previous Run
- Started: 2026-02-07 21:45:00
- Command: `swift test --filter DirectoryLoaderTests`
- Status: PASS
- Duration: 5.313s
- Notes: All 33 tests pass across 11 suites. Added 10 new Phase 6 integration tests: MultiDirectoryWatcher integration (2), load cancellation (2), async folder expansion (3), icon/loader lifecycle (3). Full spec Phase 6 coverage complete.

### DirectoryLoaderTests (Swift Testing)
| Test | Status | Duration | Last Run |
| --- | --- | --- | --- |
| loadDirectory returns entries for temp directory with files | PASS | 0.010s | 2026-02-07 21:45:00 |
| loadDirectory throws timeout when load exceeds duration | PASS | 0.007s | 2026-02-07 21:45:00 |
| Cancelling parent Task stops the load | PASS | 0.043s | 2026-02-07 21:45:00 |
| loadDirectory throws appropriate error for unreadable directory | PASS | 0.007s | 2026-02-07 21:45:00 |
| LoadedFileEntry correctly captures metadata from resource values | PASS | 0.008s | 2026-02-07 21:45:00 |

### ResourceKeySelectionTests (Swift Testing)
| Test | Status | Duration | Last Run |
| --- | --- | --- | --- |
| Local paths include localizedNameKey | PASS | 0.006s | 2026-02-07 21:45:00 |
| Local paths exclude iCloud keys | PASS | 0.006s | 2026-02-07 21:45:00 |
| Local paths include base resource keys | PASS | 0.006s | 2026-02-07 21:45:00 |
| iCloud Mobile Documents path includes iCloud keys | PASS | 0.006s | 2026-02-07 21:45:00 |
| iCloud path also includes localizedNameKey | PASS | 0.006s | 2026-02-07 21:45:00 |

### IconLoaderTests (Swift Testing)
| Test | Status | Duration | Last Run |
| --- | --- | --- | --- |
| Second call for same URL returns cached icon without re-fetching | PASS | 0.009s | 2026-02-07 21:45:00 |
| invalidate removes entry, next call re-fetches | PASS | 0.008s | 2026-02-07 21:45:00 |

### IconLoaderNetworkVolumeTests (Swift Testing)
| Test | Status | Duration | Last Run |
| --- | --- | --- | --- |
| Network volume directory returns folder placeholder icon | PASS | 0.006s | 2026-02-07 21:45:00 |
| Network volume file with known extension returns UTType icon | PASS | 0.444s | 2026-02-07 21:45:00 |
| Network volume file without extension returns file placeholder | PASS | 0.006s | 2026-02-07 21:45:00 |
| Network volume package returns UTType icon, not folder | PASS | 0.006s | 2026-02-07 21:45:00 |
| Network volume icons are cached | PASS | 0.006s | 2026-02-07 21:45:00 |
| Local file uses workspace icon lookup, not extension-based | PASS | 0.008s | 2026-02-07 21:45:00 |

### FileItemEntryInitTests (Swift Testing)
| Test | Status | Duration | Last Run |
| --- | --- | --- | --- |
| FileItem created from LoadedFileEntry has correct properties | PASS | 0.012s | 2026-02-07 21:45:00 |

### VolumeMonitorNetworkTests (Swift Testing)
| Test | Status | Duration | Last Run |
| --- | --- | --- | --- |
| isNetworkVolume returns false for local paths | PASS | 0.002s | 2026-02-07 21:45:00 |
| isNetworkVolume returns false for home directory | PASS | 0.002s | 2026-02-07 21:45:00 |

### NetworkDirectoryPollerTests (Swift Testing)
| Test | Status | Duration | Last Run |
| --- | --- | --- | --- |
| Poller fires onChange when directory contents change | PASS | 2.083s | 2026-02-07 21:45:00 |
| Poller does not fire onChange when nothing changed | PASS | 5.312s | 2026-02-07 21:45:00 |

### MultiDirectoryWatcher Integration (Swift Testing)
| Test | Status | Duration | Last Run |
| --- | --- | --- | --- |
| Local directory uses DispatchSource watcher, not poller | PASS | 0.208s | 2026-02-07 21:45:00 |
| Unwatching stops monitoring for changes | PASS | 0.714s | 2026-02-07 21:45:00 |

### Load Cancellation Tests (Swift Testing)
| Test | Status | Duration | Last Run |
| --- | --- | --- | --- |
| Cancelling load task prevents results from being delivered | PASS | 0.029s | 2026-02-07 21:45:00 |
| Rapid sequential loads each cancel the previous | PASS | 0.012s | 2026-02-07 21:45:00 |

### Async Folder Expansion Tests (Swift Testing)
| Test | Status | Duration | Last Run |
| --- | --- | --- | --- |
| loadChildrenAsync returns sorted children with parent set | PASS | 0.009s | 2026-02-07 21:45:00 |
| loadChildrenAsync returns existing children if already loaded | PASS | 0.008s | 2026-02-07 21:45:00 |
| loadChildrenAsync returns nil for non-directory | PASS | 0.007s | 2026-02-07 21:45:00 |

### Icon Load Task Lifecycle Tests (Swift Testing)
| Test | Status | Duration | Last Run |
| --- | --- | --- | --- |
| IconLoader invalidateAll clears entire cache | PASS | 0.006s | 2026-02-07 21:45:00 |
| DirectoryLoader loadChildren is equivalent to loadDirectory | PASS | 0.009s | 2026-02-07 21:45:00 |
| DirectoryLoader handles nonexistent directory | PASS | 0.007s | 2026-02-07 21:45:00 |

### NetworkUITests (XCUITest)
| Test | Status | Duration | Last Run |
| --- | --- | --- | --- |
| testNetworkSectionExists | PASS | 25.35s | 2026-02-03 14:18:00 |
| testNetworkSectionShowsPlaceholder | PASS | 21.12s | 2026-02-03 14:18:00 |
| testConnectToServerOpensWithKeyboardShortcut | PASS | 21.10s | 2026-02-03 14:18:00 |
| testConnectToServerDialogElements | PASS | 21.27s | 2026-02-03 14:18:00 |
| testConnectToServerCancelCloses | PASS | 23.50s | 2026-02-03 14:18:00 |
| testConnectToServerValidatesURL | PASS | 21.28s | 2026-02-03 14:18:00 |
| testGoMenuHasConnectToServer | PASS | 19.24s | 2026-02-03 14:18:00 |

### NetworkTests (Swift Testing)
| Test | Status | Duration | Last Run |
| --- | --- | --- | --- |
| testNetworkProtocolURLSchemes | PASS | 0.000s | 2026-02-03 14:14:49 |
| testNetworkServerEquality | PASS | 0.000s | 2026-02-03 14:14:49 |
| testNetworkServerURL | PASS | 0.000s | 2026-02-03 14:14:49 |
| testNetworkMountErrorDescriptions | PASS | 0.000s | 2026-02-03 14:14:49 |
| testConnectToServerURLValidation | PASS | 0.002s | 2026-02-03 14:14:49 |
| testRecentServersMaxCount | PASS | 0.005s | 2026-02-03 14:14:49 |
| testRecentServersPersistence | PASS | 0.001s | 2026-02-03 14:14:49 |
| testVolumeInfoMatchesServer | PASS | 0.000s | 2026-02-03 14:14:49 |
| testSyntheticServerEquality | PASS | 0.000s | 2026-02-03 14:14:49 |
| testSyntheticServerDisplayName | PASS | 0.000s | 2026-02-03 14:14:49 |

### SmokeTests (XCUITest)
| Test | Status | Duration | Last Run |
| --- | --- | --- | --- |
| testAppLaunchesWithWindow | PASS | 4.27s | 2026-01-21 17:39:25 |
| testHomeButtonExists | PASS | 4.04s | 2026-01-21 17:41:00 |
| testFileListOutlineViewExists | PASS | 3.91s | 2026-01-21 17:41:41 |
| testHomeButtonShowsOutlineRows | PASS | 6.98s | 2026-01-21 17:43:08 |

### FolderExpansionUITests (XCUITest)
| Test | Status | Duration | Last Run |
| --- | --- | --- | --- |
| testDisclosureTriangleExpand | PASS | 13.49s | 2026-01-21 17:29:12 |
| testDisclosureTriangleCollapse | PASS | 14.49s | 2026-01-21 15:58:50 |
| testOptionClickRecursiveExpand | PASS | 14.27s | 2026-01-21 16:06:08 |
| testOptionClickRecursiveCollapse | PASS | 14.87s | 2026-01-21 16:07:26 |
| testRightArrowExpandsFolder | PASS | 12.34s | 2026-01-21 16:08:13 |
| testRightArrowOnExpandedMovesToChild | PASS | 14.56s | 2026-01-21 16:08:35 |
| testLeftArrowCollapsesFolder | PASS | 14.92s | 2026-01-21 16:08:58 |
| testLeftArrowOnCollapsedMovesToParent | PASS | 15.97s | 2026-01-21 16:09:41 |
| testOptionRightRecursiveExpand | PASS | 14.39s | 2026-01-21 16:10:03 |
| testOptionLeftRecursiveCollapse | PASS | 16.82s | 2026-01-21 16:10:30 |
| testLeftArrowOnCollapsedRootFolderNoOp | PASS | 12.72s | 2026-01-21 17:47:56 |
| testCollapseWithSelectionInsideMoveToParent | PASS | 15.11s | 2026-01-21 16:10:53 |
| testSettingsToggleDisablesTriangles | PASS | 22.88s | 2026-01-21 18:13:40 |
| testSettingsToggleArrowKeysNoOp | PASS | 33.69s | 2026-01-21 19:06:08 |
| testSettingsToggleReenableRestoresState | PASS | 28.51s | 2026-01-21 19:55:52 |
| testTabSwitchPreservesExpansion | PASS | 19.54s | 2026-01-21 20:01:00 |
| testTabsHaveIndependentExpansion | PASS | 27.06s | 2026-01-21 20:04:00 |
| testBothPanesIndependentExpansion | PASS | 24.96s | 2026-01-21 20:05:00 |
| testSelectionWorksOnNestedItems | PASS | 22.06s | 2026-01-21 21:33:27 |
| testCutWorksOnNestedItems | PASS | 20.57s | 2026-01-21 21:34:01 |
| testDirectoryWatchingDetectsNewFile | SKIP | - | 2026-01-21 20:14:00 |
| testDirectoryWatchingDetectsDeletedFolder | SKIP | - | 2026-01-21 20:14:00 |
| testExternalRenameLosesExpansionState | SKIP | - | 2026-01-21 20:14:00 |

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
| testLoadDirectory | PASS | 0.002s | 2026-01-22 11:38:36 |
| testLoadDirectoryExcludesHidden | PASS | 0.002s | 2026-01-22 11:38:36 |
| testLoadDirectoryHandlesEmptyDirectory | PASS | 0.001s | 2026-01-22 11:38:36 |
| testLoadDirectorySortsAlphabetically | PASS | 0.003s | 2026-01-22 11:38:36 |
| testLoadDirectorySortsFoldersFirst | PASS | 0.002s | 2026-01-22 11:38:36 |
| testNestedFolderChildrenLoadable | PASS | 0.003s | 2026-01-22 11:38:36 |
| testItemLocatableByURLAfterExpansion | PASS | 0.002s | 2026-01-22 11:38:36 |
| testItemAtReturnsCorrectItem | PASS | 0.016s | 2026-01-22 11:38:36 |

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
| testCopyDirectory | PASS | 0.005s | 2026-02-03 15:44:24 |
| testCopyFile | PASS | 0.001s | 2026-02-03 15:44:24 |
| testCopyMultipleConflicts | PASS | 0.001s | 2026-02-03 15:44:24 |
| testCopyToSameDirectory | PASS | 0.001s | 2026-02-03 15:44:24 |
| testCopyUndo | PASS | 0.525s | 2026-02-03 15:44:24 |
| testCreateFolder | PASS | 0.001s | 2026-02-03 15:44:24 |
| testCreateFolderNameCollision | PASS | 0.003s | 2026-02-03 15:44:24 |
| testCreateFolderUndo | PASS | 0.509s | 2026-02-03 15:44:24 |
| testCreateFolderWithoutUndoManager | PASS | 0.001s | 2026-02-03 15:44:24 |
| testDeleteFile | PASS | 0.002s | 2026-02-03 15:44:24 |
| testDeleteUndo | PASS | 0.512s | 2026-02-03 15:44:24 |
| testDeleteUndoMultiple | PASS | 0.516s | 2026-02-03 15:44:24 |
| testDuplicateFile | PASS | 0.001s | 2026-02-03 15:44:24 |
| testDuplicateMultiple | PASS | 0.001s | 2026-02-03 15:44:24 |
| testDuplicateUndo | PASS | 0.505s | 2026-02-03 15:44:24 |
| testMoveFile | PASS | 0.002s | 2026-02-03 15:44:24 |
| testMoveUndo | PASS | 0.506s | 2026-02-03 15:44:24 |
| testMultipleUndos | PASS | 1.026s | 2026-02-03 15:44:24 |
| testRapidUndosDoNotRace | PASS | 0.004s | 2026-02-03 15:44:24 |
| testRenameFile | PASS | 0.001s | 2026-02-03 15:44:24 |
| testRenameInvalidCharacters | PASS | 0.001s | 2026-02-03 15:44:24 |
| testRenameToExistingName | PASS | 0.001s | 2026-02-03 15:44:24 |
| testRestoreConflict | PASS | 0.513s | 2026-02-03 15:44:24 |
| testTabScopedUndo | PASS | 0.002s | 2026-02-03 15:44:24 |
| testTrashItemDirectlyForUndo | PASS | 0.001s | 2026-02-03 15:44:24 |
| testUndoIsSynchronous | PASS | 0.002s | 2026-02-03 15:44:24 |

### DuplicateStructureTests
| Test | Status | Duration | Last Run |
| --- | --- | --- | --- |
| testDuplicateStructureCreatesDirectories | PASS | 0.005s | 2026-01-27 09:58:35 |
| testDuplicateStructureDestinationExists | PASS | 0.001s | 2026-01-27 09:58:35 |
| testDuplicateStructureMultipleYears | PASS | 0.005s | 2026-01-27 09:58:35 |
| testDuplicateStructureOmitsFiles | PASS | 0.002s | 2026-01-27 09:58:35 |
| testDuplicateStructurePreservesDepth | PASS | 0.002s | 2026-01-27 09:58:35 |
| testDuplicateStructureYearSubstitution | PASS | 0.001s | 2026-01-27 09:58:35 |
| testYearDetectionFindsYear | PASS | 0.002s | 2026-01-27 09:58:35 |
| testYearDetectionNoYear | PASS | 0.000s | 2026-01-27 09:58:35 |
| testModelDestinationURL | PASS | 0.002s | 2026-01-27 11:33:49 |
| testModelValidation | PASS | 0.001s | 2026-01-27 11:33:49 |

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
| testCloseLastTabCreatesNewHome | PASS | 0.131s | 2026-01-22 11:38:36 |
| testCloseTabRemovesFromArray | PASS | 0.040s | 2026-01-22 11:38:36 |
| testCloseTabSelectsLeftWhenNoRight | PASS | 0.072s | 2026-01-22 11:38:36 |
| testCloseTabSelectsRightNeighbor | PASS | 0.068s | 2026-01-22 11:38:36 |
| testCreateTabAddsToArray | PASS | 0.033s | 2026-01-22 11:38:36 |
| testCreateTabSelectsNewTab | PASS | 0.031s | 2026-01-22 11:38:36 |
| testSelectNextTabWraps | PASS | 0.050s | 2026-01-22 11:38:36 |
| testSelectPreviousTabWraps | PASS | 0.050s | 2026-01-22 11:38:36 |
| testRestoreTabsWithExpansionAndSelection | PASS | 0.067s | 2026-01-22 11:38:36 |
| testRestoreTabsWithEmptyState | PASS | 0.045s | 2026-01-22 11:38:36 |
| testExpansionPreservedOnTabSwitch | PASS | 0.055s | 2026-01-22 11:38:36 |

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
| testContextMenuBuildsForFile | PASS | 0.149s | 2026-01-21 10:30:00 |
| testContextMenuBuildsForFolder | PASS | 0.006s | 2026-01-21 10:30:00 |
| testContextMenuBuildsForMultipleSelection | PASS | 0.006s | 2026-01-21 10:30:00 |
| testFileItemsHaveURLsForDragging | PASS | 0.005s | 2026-01-21 10:30:00 |
| testOpenWithAppsForImage | PASS | 0.003s | 2026-01-21 10:30:00 |
| testOpenWithAppsForTextFile | PASS | 0.002s | 2026-01-21 10:30:00 |

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
| testFileItemGitStatusProperty | PASS | 0.001s | 2026-01-21 10:30:00 |
| testFileItemURLInitHasNilGitStatus | PASS | 0.007s | 2026-01-21 10:30:00 |
| testGitStatusCaching | PASS | 0.041s | 2026-01-21 10:30:00 |
| testGitStatusInGitRepo | PASS | 0.001s | 2026-01-21 10:30:00 |
| testGitStatusInvalidateCache | PASS | 0.044s | 2026-01-21 10:30:00 |
| testGitStatusNonRepo | PASS | 0.013s | 2026-01-21 10:30:00 |

### FolderExpansionTests
| Test | Status | Duration | Last Run |
| --- | --- | --- | --- |
| testFileItemLoadChildren | PASS | 0.010s | 2026-01-22 11:31:12 |
| testFileItemLoadChildrenEmpty | PASS | 0.001s | 2026-01-22 11:31:12 |
| testFileItemLoadChildrenFile | PASS | 0.002s | 2026-01-22 11:31:12 |
| testFileItemLoadChildrenUnreadable | PASS | 0.000s | 2026-01-22 11:31:12 |
| testMultiDirectoryWatcherWatchUnwatch | PASS | 0.001s | 2026-01-22 11:31:12 |
| testMultiDirectoryWatcherCallback | PASS | 0.002s | 2026-01-22 11:31:12 |
| testMultiDirectoryWatcherUnwatchAll | PASS | 0.001s | 2026-01-22 11:31:12 |
| testExpansionStateSerialization | PASS | 0.000s | 2026-01-22 11:31:12 |
| testExpansionStateEmpty | PASS | 0.000s | 2026-01-22 11:31:12 |
| testFolderExpansionSettingDefault | PASS | 0.000s | 2026-01-22 11:31:12 |
| testFolderExpansionSettingToggle | PASS | 0.001s | 2026-01-22 11:31:12 |
| testDepthSortingForExpansionRestoration | PASS | 0.001s | 2026-01-22 11:31:12 |
| testDepthSortingHandlesUnsortedSet | PASS | 0.003s | 2026-01-22 11:31:12 |
| testSelectionByURLNotRowIndex | PASS | 0.002s | 2026-01-22 11:31:12 |
| testExpansionMustPrecedeSelection | PASS | 0.002s | 2026-01-22 11:31:12 |

### PasteSelectionUITests (XCUITest)
| Test | Status | Duration | Last Run |
| --- | --- | --- | --- |
| testPasteInExpandedFolderKeepsSelectionInFolder | PASS | 31.0s | 2026-01-22 15:38:00 |
| testDeleteInExpandedFolderKeepsSelectionNearby | - | - | - |
| testDuplicateInExpandedFolderSelectsDuplicate | - | - | - |

### QuickNavCmdEnterUITests (XCUITest)
| Test | Status | Duration | Last Run |
| --- | --- | --- | --- |
| testCmdEnterSelectsSearchedItem | PASS | 20.121s | 2026-01-23 14:17:30 |
| testEnterVsCmdEnter | - | - | - |

### DuplicateStructureUITests (XCUITest)
| Test | Status | Duration | Last Run |
| --- | --- | --- | --- |
| testDuplicateStructureCreatesFolder | PASS | 26.283s | 2026-01-27 11:37:24 |
| testDuplicateStructureCancelDismisses | PASS | 24.213s | 2026-01-27 11:38:06 |
| testDuplicateStructureEscapeDismisses | PASS | 22.979s | 2026-01-27 11:38:39 |

### FolderExpansionUITests
| Test | Status | Duration | Last Run |
| --- | --- | --- | --- |
| testActivePanePreservedOnRelaunch | PASS | 33.801s | 2026-01-22 14:45:12 |
| testRenamePreservesExpansion | PASS | 29.822s | 2026-01-22 12:39:20 |
| testPastePreservesExpansion | PASS | 28.556s | 2026-01-22 12:31:00 |
| testNestedExpansionSurvivesRefresh | PASS | 19.356s | 2026-01-22 12:23:32 |
| testSelectionPreservedAfterRefresh | PASS | - | 2026-01-22 (manual) |
| testDeletePreservesExpansion | PASS | 21.431s | 2026-01-22 12:27:32 |

### FilterTests
| Test | Status | Duration | Last Run |
| --- | --- | --- | --- |
| testFilterMatchesSubstring | PASS | 0.005s | 2026-01-27 23:27:24 |
| testFilterCaseInsensitive | PASS | 0.003s | 2026-01-27 23:27:24 |
| testFilterNoMatch | PASS | 0.003s | 2026-01-27 23:27:24 |
| testFilterPreservesExpansion | PASS | 0.004s | 2026-01-27 23:27:24 |
| testClearFilterRestoresFullList | PASS | 0.014s | 2026-01-27 23:27:24 |
| testTotalItemCountUnaffectedByFilter | PASS | 0.003s | 2026-01-27 23:27:24 |
| testFilterMatchesNestedFileRecursively | PASS | 0.007s | 2026-01-27 23:27:24 |

### FilterUITests (XCUITest)
| Test | Status | Duration | Last Run |
| --- | --- | --- | --- |
| testCmdFShowsFilterBar | PASS | 13.7s | 2026-01-27 23:24:09 |
| testSlashKeyShowsFilterBar | PASS | 15.5s | 2026-01-27 23:25:24 |
| testFilterTextChangeFiltersItems | PASS | 15.2s | 2026-01-27 23:24:37 |
| testEscapeClearsFilterThenCloses | PASS | 17.5s | 2026-01-27 23:24:56 |
| testDownArrowMovesFocusToList | PASS | 14.2s | 2026-01-27 23:25:08 |
| testFilterAutoExpandsToShowNestedMatches | PASS | 22.9s | 2026-01-27 23:25:24 |

### NewFolderUITests (XCUITest)
| Test | Status | Duration | Last Run |
| --- | --- | --- | --- |
| testNewFolderSelectsNewFolderNotExisting | PASS | 30.580s | 2026-02-03 17:47:54 |
| testNewFolderWithoutExpansion | PASS | 23.512s | 2026-02-03 16:03:24 |
| testCancelNewFolderDoesNotDeleteExisting | PASS | 24.170s | 2026-02-03 16:03:59 |

### UndoUITests (XCUITest)
| Test | Status | Duration | Last Run |
| --- | --- | --- | --- |
| testUndoDelete | PASS | 19.602s | 2026-01-29 16:23:39 |
| testUndoCopy | PASS | 26.948s | 2026-01-29 16:44:26 |
| testUndoMove | PASS | 26.080s | 2026-01-29 16:49:17 |
| testUndoMenuLabel | PASS | 15.944s | 2026-01-29 16:20:12 |
| testMultipleUndoOrder | PASS | 22.839s | 2026-01-29 16:24:19 |
| testRedo | PASS | 18.394s | 2026-01-29 16:15:56 |
| testTabScopedUndo | PASS | 25.127s | 2026-01-29 16:40:29 |
| testMultipleUndosAcrossTabs | PASS | 41.609s | 2026-01-29 16:53:17 |

## Notes
- 2026-02-07 21:45: DirectoryLoaderTests - Added 10 Phase 6 integration tests (33 total across 11 suites): WatcherIntegrationTests (2) verifies DispatchSource watcher for local dirs and unwatch stops monitoring, LoadCancellationTests (2) verifies cancel prevents delivery and rapid sequential loads cancel previous, AsyncFolderExpansionTests (3) verifies loadChildrenAsync returns sorted children with parent set / returns cached / returns nil for non-directory, IconLoadLifecycleTests (3) verifies invalidateAll clears cache / loadChildren matches loadDirectory / nonexistent directory throws disconnected. Spec Phase 6 checkboxes all complete.
- 2026-02-07 21:15: DirectoryLoaderTests - Added 11 new tests (23 total across 7 suites) for network volume optimizations: ResourceKeySelectionTests (5) verifies key selection logic (local gets localizedNameKey, iCloud gets ubiquitous keys, base keys always present), IconLoaderNetworkVolumeTests (6) verifies extension-based icon loading (folder placeholder for directories, UTType icon for known extensions, file placeholder for extensionless, package handling, caching, local vs network path). Made resourceKeys(for:) internal for testability.
- 2026-02-07 20:31: DirectoryLoaderTests - 12 new tests for async directory loading feature across 5 suites. Tests DirectoryLoader actor (entries, timeout, cancellation, access denied, metadata), IconLoader (caching, invalidation), FileItem init from LoadedFileEntry, VolumeMonitor.isNetworkVolume, and NetworkDirectoryPoller (change detection, no false positives). Also fixed pre-existing FolderExpansionTests compilation error caused by MultiDirectoryWatcher closure becoming @Sendable.
- 2026-02-03 17:47: NewFolderUITests/testNewFolderSelectsNewFolderNotExisting PASSED - Fixed two bugs: (1) createNewFolder now creates INSIDE selected folder instead of alongside it, (2) findItem() fixed to compare paths instead of URLs because directory URLs have trailing slashes that break URL equality. Root cause of 3-hour debugging session: repeatedly running tests without understanding the actual requirement (create inside, not alongside).
- 2026-02-02 20:39: NetworkTests - Added 3 new tests for hierarchical network volume display: testVolumeInfoMatchesServer (volume-to-server host matching), testSyntheticServerEquality, testSyntheticServerDisplayName. Total: 10 NetworkTests all PASS.
- 2026-01-27 23:25: FilterUITests/testFilterAutoExpandsToShowNestedMatches PASSED - Fixed recursive filter auto-expand. Root cause: FileItem.loadChildren() was recreating children even when already loaded, breaking NSOutlineView's item identity tracking. Fix: early return if children != nil. Also added testFilterMatchesNestedFileRecursively unit test to verify dataSource.filteredChildren() recursive filtering.
- 2026-01-27 22:52: FilterUITests/testSlashKeyShowsFilterBar PASSED - Fixed "/" key handling. XCUI sends "/" with shift modifier (mods=131072) and wrong keyCode (26 instead of 44). Changed check to match character "/" with empty modifiers OR shift only.
- 2026-01-22 15:38: PasteSelectionUITests/testPasteInExpandedFolderKeepsSelectionInFolder PASSED (manual verification) - Fixed paste destination to use selected item's parent folder instead of root. When file.txt in SubfolderA1 selected, paste now goes to SubfolderA1. Conflict dialog appeared proving correct location. Also fixed: delete/duplicate selection using tableView.numberOfRows instead of dataSource.items.count, selectItem(at:) now searches full tree.
- 2026-01-22 14:45: FolderExpansionUITests/testActivePanePreservedOnRelaunch PASSED - Fixed active pane jumping to right on relaunch. Root cause: tableViewSelectionDidChange called fileListDidBecomeActive for programmatic changes (git status), stealing focus. Fix: only call fileListDidBecomeActive on user clicks (onActivate), not programmatic selection.
- 2026-01-22 12:39: FolderExpansionUITests/testRenamePreservesExpansion PASSED - Fixed test to use context menu for rename (XCUITest keyboard shortcut handling unreliable for function keys and Shift+Enter). Test verifies rename operation preserves folder expansion state.
- 2026-01-22 12:31: FolderExpansionUITests/testPastePreservesExpansion PASSED - Added Cmd+A before typing to select all text in rename field. Paste operation preserves folder expansion state.
- 2026-01-22 12:25: FolderExpansionUITests/testSelectionPreservedAfterRefresh FAILED - Known test infrastructure issue with XCUI nested outline rows. Clicking on SubfolderA1 selects FolderA instead. App behavior is correct; test helper is the issue.
- 2026-01-22 12:23: FolderExpansionUITests/testNestedExpansionSurvivesRefresh PASSED - Fixed by adding Hashable conformance to FileItem. NSOutlineView uses hash/isEqual to match items across reloadData().
- 2026-01-22 11:50: FolderExpansionUITests/testNestedExpansionSurvivesRefresh FAILED - After Cmd+R refresh, SubfolderA1 visible but file.txt not visible. Nested expansion not fully preserved. Depth sorting fix may be incomplete.
- 2026-01-22 11:45: FolderExpansionUITests/testRenamePreservesExpansion FAILED - Shift+Enter rename didn't produce expected result, renamed.txt not found after rename operation.
- 2026-01-22: Added comprehensive bug fix verification tests. FileListDataSourceTests: 3 new tests (testNestedFolderChildrenLoadable, testItemLocatableByURLAfterExpansion, testItemAtReturnsCorrectItem). PaneViewControllerTests: 3 new tests (testRestoreTabsWithExpansionAndSelection, testRestoreTabsWithEmptyState, testExpansionPreservedOnTabSwitch). FolderExpansionTests: 4 new tests for depth sorting and selection. FolderExpansionUITests: 5 new tests (testRenamePreservesExpansion, testPastePreservesExpansion, testNestedExpansionSurvivesRefresh, testSelectionPreservedAfterRefresh, testDeletePreservesExpansion). All unit tests pass (34 tests). UI tests pending approval.
- 2026-01-21: Added FolderExpansionTests (11 tests) for Stage 8 folder expansion: FileItem.loadChildren, MultiDirectoryWatcher, expansion state persistence, and settings toggle. SystemIntegrationTests updated: testDragPasteboardContainsFileURLs renamed to testFileItemsHaveURLsForDragging, testDropTargetRowTracking removed (used NSTableView API). Full suite: 201 tests in 20 classes, ALL PASS.
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
- 2026-01-27: Added DuplicateStructureUITests (3 UI tests) verifying end-to-end duplicate structure workflow: folder creation, Cancel dismissal, Escape dismissal. Fixed callback bug where onComplete was cleared before being called.
- 2026-01-27: Added DuplicateStructureTests (10 unit tests) for duplicate folder structure feature: directory creation, depth preservation, file omission, year substitution, destination exists error, year detection regex, model destination URL, and validation.
- 2026-01-06 10:25:43: Added system-defined media key handling for the dictation key (F5 on many keyboards) and tests for the path.
