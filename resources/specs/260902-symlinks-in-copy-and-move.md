# Symbolic Links in Copy and Move

## Meta

- Status: Draft
- Branch: feature/symlinks-in-copy-and-move

---

## Business

### Goal

Copying or moving a symbolic link does the sensible thing without asking: within one machine the link stays a link, across machines the file it points at travels instead, and a move never touches the file a link points at.

### Proposal

Detours treats a link as a link within one host and as the file it points at when the copy crosses hosts, follows the same rule for links inside copied folders, and on a move only ever removes the link itself.

### Behaviors

- Copying a selected link within one host, Mac to Mac or the same remote host to itself, creates a link with the same target text at the destination. This matches Finder, `cp` and rsync.
- Moving a selected link within one host renames the link. The file or folder it points at does not move.
- Copying a selected link to a different host, Mac to remote, remote to Mac, or remote to remote, copies the file it points at under the link's name. A link to a folder copies that folder's contents under the link's name.
- Moving a selected link to a different host copies what the link points at, then moves the link itself to the source host's trash. The file or folder it pointed at stays where it was.
- Inside a folder copied to a different host, a link that points to something within that same folder arrives as a link again, adjusted so it still points at the copied counterpart. A link that points outside the copied folder arrives as a copy of what it points at. This is rsync's `--copy-unsafe-links` rule.
- A link whose target no longer exists fails that one item with the message that it points to a file that does not exist, naming the link. Other items in the same copy continue.
- A link that leads back into a folder already being copied, directly or through further links, fails that one item with a message naming the link, so a copy can never run without end.
- Deleting or trashing a link, with F8 or Cmd-Backspace, on a remote host removes the link and leaves what it pointed at untouched, as it already does on the Mac.
- No dialog is shown for any of this. The rule is fixed and described in the user guide.
- Pressing Space on a link keeps its current behaviour: the file it points at is previewed.

### Acceptance Criteria

- [ ] **A1** Copying a link from one local folder to another local folder gives a link at the destination, and the original file is unchanged.
- [ ] **A2** Copying a link within a remote host gives a link at the destination on that host.
- [ ] **A3** Moving a link within a remote host renames the link, and the file it pointed at is still in place.
- [ ] **A4** Copying a link to a file from the Mac to a remote host lands a regular file with the link's name and the target's contents on the host.
- [ ] **A5** Copying a link to a folder from a remote host to the Mac lands a real folder with the link's name containing the target folder's files.
- [ ] **A6** Copying a folder from the Mac to a remote host recreates a link that pointed inside that folder as a working link on the host, and turns a link that pointed outside it into a copy of the file it pointed at.
- [ ] **A7** Moving a link to a file from the Mac to a remote host lands the file on the host, moves the link to the Mac's Trash, and leaves the original file on the Mac untouched.
- [ ] **A8** Copying a link whose target is missing fails that item with a message naming the link, and the other selected items still copy.
- [ ] **A9** Copying a folder containing a link back to itself to a remote host fails that link with a message naming it and completes the rest of the folder.
- [ ] **A10** Trashing a link on a remote host removes the link, and the file it pointed at is still in place.
- [ ] **A11** The user guide describes the rule for links in copy and move.

### Out of scope

- Windows hosts. Their links and junctions keep today's behaviour.
- Finder aliases, which are files, not links, and keep today's behaviour.
- Links inside archives being created or extracted.
- Preserving a link's ownership or permissions.
- A setting or a modifier key to choose the other behaviour.

---

## Technical

### Approach

Two capabilities are missing and everything else composes from them: reading where a link points (already available through `readSymlink` on every provider) and creating a link at a destination. `FileProvider` in `src/Services/FileProvider/FileProvider.swift` gains `createSymbolicLink(at:pointingTo:)`. `LocalFileProvider` implements it with `FileManager.createSymbolicLink`; `RemoteFileProvider` sends a new `symlink` message (the next free message number in `src/Remote/Protocol/Messages.swift`, mirrored in `Server/ServerRPCProtocol.swift`), which `Server/RPCHandler.swift` lists as state-changing and `Server/FileOperations.swift` serves with `FileManager.createSymbolicLink`; `WindowsRemoteProvider` throws the existing unsupported-operation error. Whether a link points inside the copied tree is decided from the resolved absolute path `readSymlink` already returns, compared against the copied root's resolved path, and a recreated link is written with a relative target computed from those two paths, so the copy is correct whatever the original link text was.

Same-host copies today go through `copyfile(3)` in `src/Operations/CopyfileHelper.swift` on the Mac and `FileManager.copyItem` in the helper's `copy` in `Server/FileOperations.swift`. `copyfile` follows a top-level link unless `COPYFILE_NOFOLLOW_SRC` is set, so the helper sets that flag; the Linux helper recreates a link source with `createSymbolicLink` rather than relying on Foundation's copy. Moves within one host are already renames and need no change beyond tests. The helper's trash in `Server/TrashOperations.swift` resolves links on the item path before moving it, which moves the target instead of the link; it changes to resolve only the parent directory and keep the final component as it is, and the same correction applies to its restore and rollback paths so a trashed link restores as a link.

Cross-host copies run through `performProviderTransfer` in `src/Operations/FileOperationQueue+Operations.swift`, which downloads each item into a temporary local folder and uploads it from there. The link rule lives in that download step and its upload counterpart. A selected link is resolved once at the top: missing target fails the item with a new `FileOperationError.linkTargetMissing(name)`, a folder target is walked under the link's name, a file target is downloaded under the link's name. While walking a folder, each nested link is resolved: inside the root it is recorded as a relative link to recreate, outside it is followed like a selected link. Loop protection keeps the set of resolved directory paths currently open on the walk and every resolved directory already walked; entering one again fails that item with `FileOperationError.linkLoops(name)`. Recorded links are written into the temporary folder as real local links, which the upload step already lists with the symbolic-link key; it recreates them through the provider after the surrounding folder has been uploaded, so a link never points at something not yet there. The source trash on a cross-host move already targets the link's own path; with the helper trash fixed it removes the link only.

Quick Look is untouched: it already previews the file a remote link points at. The user guide and the remote browsing guide describe the rule. The rebuilt Linux helper reaches each host through the existing hash comparison on the next connection.

### Approach Validation

Same-host behaviour follows the tools users already know: `cp -R`, rsync in archive mode and Finder all copy a link as a link, and rsync documents `-l` as the preserving default with `-L` as the explicit opt-in to follow ([Baeldung, copying symbolic links with rsync](https://www.baeldung.com/linux/rsync-copy-symlinks)). Following everything is scp's behaviour and is the documented complaint: recursive scp copies the contents behind every link with no way to turn it off, and the request to add one has been open for years ([recursive scp and symlinks](https://smaftoul.wordpress.com/2008/08/13/recursive-scp-and-symlinks/), [OpenSSH bug 485](https://bugzilla.mindrot.org/show_bug.cgi?id=485)). That is why nested links are not followed wholesale.

For links inside a copied tree crossing hosts, rsync's `--copy-unsafe-links` is the established middle ground: links pointing within the copied tree stay links, links pointing outside are replaced by what they point at, so nothing dangles and the tree keeps its shape. A Linux kernel test-suite change records the trade-off from experience: switching to follow-everything fixed dangling links but broke tests that depended on a link being a link, and `--copy-unsafe-links` was the fix that did right by both ([selftests: keep symlinks when possible](https://lkml.iu.edu/hypermail/linux/kernel/2308.2/06948.html)). Detours adopts the same rule, deciding inside-or-outside from resolved paths rather than from the link text, which also handles absolute links that happen to point inside the tree.

Two failure modes shape the design. Links that loop, such as a folder containing a link to its own parent, turn a naive walk into an endless copy, so the walk keeps resolved paths and refuses to re-enter one. And the helper's own trash was found, while writing this spec, to resolve a link before moving it, which would have moved the target on every cross-host move of a link; fixing that is part of the change and covered by a live test.

### Risks

| Risk | Mitigation |
| ---- | ---------- |
| A cross-host move of a link removes the target instead of the link on a Linux host. | Fix the helper's trash to resolve only the parent path, and cover it with a live test that trashes a link and asserts the target is still there. |
| A folder containing a link back into itself copies without end. | Track resolved directory paths on the walk and already walked; fail the offending link with a named message and continue with the rest. |
| A link recreated on the other host points at nothing because its text was absolute or relative to somewhere else. | Recreate links from resolved paths as relative targets within the copied tree; links pointing outside are never recreated, they are copied as content. |
| A same-host copy on the Mac silently follows the link because `copyfile` follows a top-level link by default. | Set `COPYFILE_NOFOLLOW_SRC` and assert with a test that the copy is a link. |
| Foundation's copy on the Linux helper follows or mangles a link source. | The helper recreates link sources explicitly instead of copying them; a live test on devtest asserts the result is a link with the same target text. |
| An older helper on a host does not know the new link command. | The app already compares helper hashes on connect and installs the bundled helper when they differ, so the command is present before any copy runs. |
| The rule surprises a user who expected the other behaviour. | The user guide states the rule in one paragraph, and every failure names the link and the reason. |
| Windows hosts break on the new provider call. | The Windows provider throws the existing unsupported-operation error, and Windows links are out of scope. |

### Implementation Plan

**Phase 1: Link creation on every provider**

- [ ] **C1** Add `createSymbolicLink(at:pointingTo:)` to `FileProvider` in `src/Services/FileProvider/FileProvider.swift`, with a default that throws `FileProviderError.unsupportedOperation`.
- [ ] **C2** Implement it in `src/Services/FileProvider/LocalFileProvider.swift` with `FileManager.createSymbolicLink(at:withDestinationURL:)`, refusing to overwrite an existing item.
- [ ] **C3** Add a `symlink(path:target:)` message with the next free number in `src/Remote/Protocol/Messages.swift` and `Server/ServerRPCProtocol.swift`, name it in the message-name table in `src/Services/FileProvider/RemoteFileProvider.swift`, list it as state-changing in `Server/RPCHandler.swift`, and serve it in `Server/FileOperations.swift` with `FileManager.createSymbolicLink`, refusing an existing item.
- [ ] **C4** Implement the provider call in `src/Services/FileProvider/RemoteFileProvider.swift` over that message, and in `src/Remote/UITestRemoteProvider.swift` with a confined local link.
- [ ] **C5** Add `linkTargetMissing(name:)` and `linkLoops(name:)` to `src/Operations/FileOperationError.swift` with plain messages naming the link.

**Phase 2: Same host**

- [ ] **C6** Set `COPYFILE_NOFOLLOW_SRC` in `src/Operations/CopyfileHelper.swift` so a selected link copies as a link on the Mac.
- [ ] **C7** In `Server/FileOperations.swift` `copy`, recreate a source that is a link with `createSymbolicLink` and its original target text instead of `copyItem`.
- [ ] **C8** In `Server/TrashOperations.swift`, resolve links only in the parent directory of a trashed, restored or rolled-back path and keep the final component as given, so a link is trashed and restored as a link.

**Phase 3: Across hosts**

- [ ] **C9** In `performProviderTransfer` in `src/Operations/FileOperationQueue+Operations.swift`, resolve a selected link through `readSymlink` and `stat` before the download step: a missing target fails the item with `linkTargetMissing`, a folder target is walked under the link's name, a file target is downloaded under the link's name.
- [ ] **C10** In the download step of the same file, add a walk context carrying the copied root's resolved path, the resolved directory paths currently open, and every resolved directory already walked; a nested link resolving inside the root is recorded for recreation with a relative target, one resolving outside is followed like a selected link, a re-entered directory fails the item with `linkLoops`, and a missing target fails it with `linkTargetMissing`.
- [ ] **C11** Write each recorded link into the temporary local folder as a real link with `FileManager.createSymbolicLink`, and in the upload step of the same file recreate links through `createSymbolicLink` on the destination provider after the folder that contains them has been uploaded.
- [ ] **C12** Make the per-item failures from C9 and C10 join the operation's existing partial-failure reporting so the remaining items complete.
- [ ] **C13** Confirm `trashSourceAfterProviderMove` in the same file passes the link's own path for both local and remote sources, adjusting `displaceLocalItem` in `src/Operations/FileOperationQueue+Replacement.swift` if `trashItem` follows the link.

**Phase 4: Documentation**

- [ ] **C14** Describe the rule in `resources/docs/USER_GUIDE.md` under file operations and in `resources/docs/remote-vm-browsing.md` under transfers, and add the changelog entries.

---

## Testing

### Unit Tests (`Tests/SymlinkTransferPlanTests.swift`)

- [ ] **T1** `testLinkInsideRootIsRecordedAsRelativeLink` - A nested link resolving inside the root yields a relative target from the link's folder to the copied counterpart.
- [ ] **T2** `testLinkOutsideRootIsFollowed` - A nested link resolving outside the root is walked as content.
- [ ] **T3** `testAbsoluteLinkInsideRootIsStillInside` - An absolute link that resolves inside the root counts as inside.
- [ ] **T4** `testReenteredDirectoryFailsWithLinkLoops` - Entering a resolved directory already open or already walked fails with `linkLoops` naming the link.
- [ ] **T5** `testMissingTargetFailsWithLinkTargetMissing` - A link whose target cannot be read fails with `linkTargetMissing` naming the link.

### Unit Tests (`Tests/CrossProviderTransferTests.swift`)

- [ ] **T6** `testSelectedFileLinkCopiesTargetUnderLinkName` - With the fake providers, a selected link to a file uploads the target's bytes under the link's name.
- [ ] **T7** `testSelectedFolderLinkCopiesFolderUnderLinkName` - A selected link to a folder uploads that folder's children under the link's name.
- [ ] **T8** `testNestedInsideLinkIsRecreatedAfterItsFolder` - A folder with an internal link uploads the folder first and then calls `createSymbolicLink` with a relative target.
- [ ] **T9** `testDanglingLinkFailsOnlyThatItem` - A dangling link fails with `linkTargetMissing`, and a second selected item still uploads.
- [ ] **T10** `testMoveOfLinkTrashesTheLinkPathOnly` - A cross-provider move trashes the link's own location and never the target's.

### Unit Tests (`Tests/TrashOperationsTests.swift`)

- [ ] **T11** `testTrashingLinkMovesLinkNotTarget` - Trashing a link in a temporary home moves the link into the trash and leaves the target file in place.
- [ ] **T12** `testRestoringTrashedLinkRestoresLink` - Restoring that entry puts a link back at the original path.

### Unit Tests (`Tests/FileOperationQueueTests.swift`)

- [ ] **T13** `testLocalCopyOfLinkKeepsLink` - Copying a link between temporary folders yields a link with the same target text and leaves the target unchanged.
- [ ] **T14** `testLocalMoveOfLinkRenamesLink` - Moving a link between temporary folders yields a link at the destination and leaves the target unchanged.
- [ ] **T15** `testLocalTrashOfLinkKeepsTarget` - Trashing a link through the queue leaves the target file in place.

### Integration Tests (`Tests/RemoteIntegrationTests.swift`, live against devtest from Foundry)

- [ ] **T16** `testSameHostCopyOfLinkKeepsLink` - Copying a link within devtest yields a link with the same target text.
- [ ] **T17** `testSameHostMoveOfLinkRenamesLink` - Moving a link within devtest renames it and leaves the target in place.
- [ ] **T18** `testTrashingRemoteLinkLeavesTarget` - Trashing a link on devtest removes the link and leaves the target in place; restoring brings the link back.
- [ ] **T19** `testFileLinkUploadsTargetUnderLinkName` - Copying a local link to a file to devtest lands a regular file with the link's name and the target's bytes.
- [ ] **T20** `testFolderLinkDownloadsFolderUnderLinkName` - Copying a devtest link to a folder to the Mac lands a real folder with the link's name and the target's files.
- [ ] **T21** `testFolderWithInsideAndOutsideLinksUploadsPerRule` - Copying a local folder holding one link inside it and one outside it to devtest recreates the first as a working relative link and the second as a regular file.
- [ ] **T22** `testLoopingLinkFailsItemAndCompletesFolder` - A folder holding a link to itself copies its other files to devtest and fails the link with `linkLoops`.
- [ ] **T23** `testDanglingLinkFailsItemOnly` - A dangling link and a plain file selected together copy the file and fail the link with `linkTargetMissing`.
- [ ] **T24** `testCrossHostMoveOfLinkTrashesLinkOnly` - Moving a local link to devtest lands the file on the host, puts the link in the Mac's Trash, and leaves the local target in place.
- [ ] **T25** `testSymlinkMessageRoundTripsThroughRealHelper` - The new message creates a link on devtest and refuses an existing item.

### E2E Tests (`Tests/UITests/DetoursUITests/DetoursUITests/RemoteSymlinkCopyUITests.swift`, guarded installed-smoke on Foundry against devtest)

- [ ] **T26** `testF5OnLocalLinkLandsTargetOnRemoteHost` - With the live remote pane on the right and a local link to a Markdown file selected on the left, F5 lands a regular file with the link's name on the host, and the remote listing shows it as a file, not a link.

---

## Build Log

Populated at implement time.
