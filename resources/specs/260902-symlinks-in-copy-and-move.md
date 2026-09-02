# Symbolic Links in Copy and Move

## Meta

- Status: Reviewed
- Branch: feature/symlinks-in-copy-and-move

---

## Business

### Goal

Copying or moving a symbolic link does the sensible thing without asking: within one machine the link stays a link, across machines the file it points at travels instead, and a move never touches the file a link points at.

### Proposal

Detours preserves links copied within one host. Across hosts it copies a selected link's final referent; inside a copied folder it preserves links to copied counterparts and follows links to outside items. Moving a link removes only the link itself.

### Behaviors

- Copying a selected link between local folders on the Mac or between folders on the same remote host creates a link with the same target text at the destination.
- Moving a selected link within one host renames the link. The file or folder it points at does not move.
- Copying a selected link to a different host, Mac to remote, remote to Mac, or remote to remote, copies the file it points at under the link's name. A link to a folder copies that folder's contents under the link's name.
- When a copy crosses hosts, a chain of links is followed to its final file or folder. A chain that loops fails with a message naming the link being copied.
- Moving a selected link to a different host copies what the link points at, then moves the link itself to the source host's trash. The file or folder it pointed at stays where it was.
- Inside a folder copied to a different host, a link that points to something within that same folder arrives as a link again, adjusted so it still points at the copied counterpart. A link that points outside the copied folder arrives as a copy of what it points at.
- When a copy crosses hosts, a link whose target no longer exists fails that one item with the message that it points to an item that does not exist, naming the link. Other items in the same copy continue. Within one host the dangling link copies as a link.
- When a copy crosses hosts, a link that leads back into a folder already being copied, directly or through further links, fails that one item with a message naming the link, so a copy can never run without end. Within one host the looping link copies as a link.
- If a folder move across hosts has a failed nested link, the remaining content still arrives but the whole source folder stays in place.
- Deleting or trashing a link, with F8 or Cmd-Backspace, on a remote host removes the link and leaves what it pointed at untouched, as it already does on the Mac.
- No preference or choice dialog is shown. A failed link still produces the operation's error dialog.
- Pressing Space on a link keeps its current behaviour: the file it points at is previewed.

### Acceptance Criteria

- [ ] **A1** Copying a link from one local folder to another local folder gives a link at the destination, and the original file is unchanged.
- [ ] **A2** Copying a link within a remote host gives a link at the destination on that host.
- [ ] **A3** Moving a link within a remote host renames the link, and the file it pointed at is still in place.
- [ ] **A4** Copying a link to a file from the Mac to a remote host lands a regular file with the link's name and the target's contents on the host.
- [ ] **A5** Copying a link to a folder from a remote host to the Mac lands a real folder with the link's name containing the target folder's files.
- [ ] **A6** Copying a folder from the Mac to a remote host recreates a link that pointed inside that folder as a working link on the host, and turns a link that pointed outside it into a copy of the file it pointed at.
- [ ] **A7** Moving a link to a file from the Mac to a remote host lands the file on the host, moves the link to the Mac's Trash, and leaves the original file on the Mac untouched.
- [ ] **A8** Copying a link whose target is missing across hosts fails that item with a message naming the link, and the other selected items still copy; copying it within one host preserves the dangling link.
- [ ] **A9** Copying a folder containing a link back to itself to a remote host fails that link with a message naming it and completes the rest of the folder.
- [ ] **A10** Trashing a link on a remote host removes the link, and the file it pointed at is still in place.
- [ ] **A11** The user guide describes the rule for links in copy and move.
- [ ] **A12** A folder moved across hosts with a failed nested link leaves the whole source folder in place and reports the partial destination copy.

### Out of scope

- Windows hosts. Their links and junctions keep today's behaviour.
- Finder aliases, which are files, not links, and keep today's behaviour.
- Links inside archives being created or extracted.
- Preserving a link's ownership or permissions.
- A setting or a modifier key to choose the other behaviour.

---

## Technical

### Approach

Two capabilities are missing and everything else composes from them: reading each hop of a link target, already available through `readSymlink` on every provider, and creating a link at a destination from raw target text. `FileProvider` in `src/Services/FileProvider/FileProvider.swift` gains `createSymbolicLink(at:targetPath:)`. `LocalFileProvider` implements it with `FileManager.createSymbolicLink(atPath:withDestinationPath:)`; `RemoteFileProvider` sends a new `symlink(path:targetPath:)` message with tag 23 in `src/Remote/Protocol/Messages.swift`, mirrored in `Server/ServerRPCProtocol.swift`, which `Server/RPCHandler.swift` lists as state-changing and `Server/FileOperations.swift` serves with the same path-based API. Transfers with a Windows source or destination remain on their current transfer paths and never call the new method. The Unix transfer resolver repeatedly calls `readSymlink` and `stat` until it reaches a non-link, while a per-chain visited set detects cyclic link chains. Whether the final referent is inside the copied tree is decided by comparing its canonical absolute path with the copied root's canonical path. A recreated link is written with a relative target from the copied link's parent to the copied referent, so the copy is correct whatever the original link text was.

Same-host copies today go through `copyfile(3)` in `src/Operations/CopyfileHelper.swift` on the Mac and `FileManager.copyItem` in the helper's `copy` in `Server/FileOperations.swift`. `copyfile` follows a top-level link unless `COPYFILE_NOFOLLOW_SRC` is set, so the helper sets that flag; the Linux helper recreates a link source with `createSymbolicLink` rather than relying on Foundation's copy. Moves within one host are already renames and need no change beyond tests. The helper's trash in `Server/TrashOperations.swift` resolves links on the item path before moving it, which moves the target instead of the link; it changes to resolve only the parent directory and keep the final component as it is, and the same correction applies to its restore and rollback paths so a trashed link restores as a link.

Cross-host transfers enter through `performProviderTransfer` in `src/Operations/FileOperationQueue+Operations.swift`, which delegates link-aware work to `src/Operations/FileOperationQueue+SymlinkTransfer.swift` instead of adding more code to the existing oversized operations file. A selected link is resolved to its final referent at the top: a missing target fails the item with a new `FileOperationError.linkTargetMissing(name)`, a folder target is walked under the link's name, and a file target is downloaded under the link's name. While walking a folder, each nested link is resolved to its final referent: one inside the root is recorded as a relative link to recreate, while one outside is followed like a selected link. Loop protection keeps only the resolved directory paths currently active on the walk, so genuine recursion fails with `FileOperationError.linkLoops(name)` while separate links to the same directory each copy it. Nested link failures accumulate beside the temporary content; the remaining tree uploads, the destination is recorded as a success rather than entering rollback, and the failed link paths join the operation's partial-failure result. A move trashes its source only when that selected item has no nested failure, so a partial folder remains whole at the source. Recorded links are written into the temporary folder as real local links; the upload step recreates them through the provider after the containing folder exists. The source trash on a successful cross-host move targets the link's own path; with the helper trash fixed it removes the link only.

Quick Look is untouched: it already previews the file a remote link points at. The user guide and the remote browsing guide describe the rule. Each bundled helper update reaches its host through the existing hash comparison on the next connection.

### Approach Validation

Same-host behaviour follows the tools users already know: `cp -R`, rsync in archive mode and Finder all copy a link as a link, and rsync documents `-l` as the preserving default with `-L` as the explicit opt-in to follow ([Baeldung, copying symbolic links with rsync](https://www.baeldung.com/linux/rsync-copy-symlinks)). Following everything is scp's behaviour and is the documented complaint: recursive scp copies the contents behind every link with no way to turn it off, and the request to add one has been open for years ([recursive scp and symlinks](https://smaftoul.wordpress.com/2008/08/13/recursive-scp-and-symlinks/), [OpenSSH bug 485](https://bugzilla.mindrot.org/show_bug.cgi?id=485)). That is why nested links are not followed wholesale.

For links inside a copied tree crossing hosts, Detours adapts rsync's `--copy-unsafe-links` middle ground: links pointing within the copied tree stay links, while links pointing outside are replaced by what they point at. Rsync classifies safety from link text and therefore treats every absolute link as unsafe; Detours instead classifies the resolved destination, preserving an absolute link when it lands inside the copied tree ([official rsync symbolic-link rules](https://github.com/RsyncProject/rsync/blob/master/rsync.1.md#symbolic-links)). A Linux kernel test-suite change records the trade-off from experience: switching to follow-everything fixed dangling links but broke tests that depended on a link being a link, and `--copy-unsafe-links` restored both outcomes ([selftests: keep symlinks when possible](https://lkml.iu.edu/hypermail/linux/kernel/2308.2/06948.html)).

Two failure modes shape the design. Links that loop, such as a folder containing a link to its own parent, turn a naive walk into an endless copy, so the walk keeps resolved paths and refuses to re-enter one. And the helper's own trash was found, while writing this spec, to resolve a link before moving it, which would have moved the target on every cross-host move of a link; fixing that is part of the change and covered by a live test.

### Risks

| Risk | Mitigation |
| ---- | ---------- |
| A cross-host move of a link removes the target instead of the link on a Linux host. | Fix the helper's trash to resolve only the parent path, and cover it with a live test that trashes a link and asserts the target is still there. |
| A folder move with a failed nested link removes source content that never reached the destination. | Leave the selected source folder untouched whenever its walk records a nested failure. |
| A folder containing a link back into itself copies without end. | Track the resolved directory paths active on the walk; fail the offending link with a named message and continue with the rest. |
| A chain of links loops before reaching a file or folder. | Track the locations visited while resolving each chain and fail it with `linkLoops` when a location repeats. |
| A link recreated on the other host points at nothing because its text was absolute or relative to somewhere else. | Recreate links from resolved paths as relative targets within the copied tree; links pointing outside are never recreated, they are copied as content. |
| A same-host copy on the Mac silently follows the link because `copyfile` follows a top-level link by default. | Set `COPYFILE_NOFOLLOW_SRC` and assert with a test that the copy is a link. |
| Foundation's copy on the Linux helper follows or mangles a link source. | The helper recreates link sources explicitly instead of copying them; a live test on devtest asserts the result is a link with the same target text. |
| An older helper on a host does not know the new link command. | The app already compares helper hashes on connect and installs the bundled helper when they differ, so the command is present before any copy runs. |
| The rule surprises a user who expected the other behaviour. | The user guide states the rule in one paragraph, and every failure names the link and the reason. |
| A transfer involving Windows changes its existing link or junction behavior. | Detect a Windows source or destination before the Unix link walk and retain the existing Windows transfer path. |

### Implementation Plan

**Phase 1: Link creation on every provider**

- [x] **C1** Add `createSymbolicLink(at:targetPath:)` to `FileProvider` in `src/Services/FileProvider/FileProvider.swift`, with a default that throws `FileProviderError.unsupportedOperation`.
- [x] **C2** Implement it in `src/Services/FileProvider/LocalFileProvider.swift` with `FileManager.createSymbolicLink(atPath:withDestinationPath:)` and a non-following existence check that refuses regular, linked and dangling-link destinations.
- [x] **C3** Add a `symlink(path:targetPath:)` message with tag 23 in `src/Remote/Protocol/Messages.swift` and `Server/ServerRPCProtocol.swift`, name it in the message-name table in `src/Services/FileProvider/RemoteFileProvider.swift`, list it as state-changing in `Server/RPCHandler.swift`, and serve it in `Server/FileOperations.swift` with the same path-based API and non-following destination check.
- [x] **C4** Implement the raw-target provider call in `src/Services/FileProvider/RemoteFileProvider.swift`, and implement it in `src/Remote/UITestRemoteProvider.swift` with a confined link path.
- [x] **C5** Add `linkTargetMissing(name:)` with “The link {name} points to an item that does not exist.” and `linkLoops(name:)` with “The link {name} leads in a loop.” to `src/Operations/FileOperationError.swift`, including the two cases in `LocalizedError` and `FileOperationQueue.errorPresentation`.

**Phase 2: Same host**

- [x] **C6** In `src/Operations/CopyfileHelper.swift`, detect a source link without following it, set `COPYFILE_NOFOLLOW_SRC`, and add `COPYFILE_RECURSIVE` only for a non-link directory.
- [x] **C7** In `Server/FileOperations.swift` `copy`, test for a source link before directory handling and recreate it with its original target text, including when that target is missing, instead of calling `copyItem`.
- [x] **C8** In `Server/TrashOperations.swift`, resolve only the parent of every trashed, restored or rolled-back path, retain its final component, and use non-following existence checks for source, trash and restore destinations so valid and dangling links move as links.

**Phase 3: Across hosts**

- [ ] **C9** Add the link resolver and transfer plan to `src/Operations/FileOperationQueue+SymlinkTransfer.swift`; retain the existing `stageLocation` and `uploadStagedItem` path for any Windows endpoint, otherwise test for a link before directory handling and resolve every hop through `readSymlink` and `stat`, failing a repeated location with `linkLoops` or a missing target with `linkTargetMissing`, walking a folder referent under the link's name, and downloading a file referent under that name.
- [ ] **C10** In the same new file, add a walk context carrying the copied root's canonical path and the resolved directory paths currently active; compare path components to classify descendants, resolve every nested link hop, record a link ending inside the root with a relative target, follow one ending outside like a selected link, fail an active directory or repeated link location with `linkLoops`, and fail a missing target with `linkTargetMissing`.
- [ ] **C11** Write each recorded link into the temporary local folder with `FileManager.createSymbolicLink(atPath:withDestinationPath:)`; during upload, handle a link before checking whether its referent is a directory and recreate it through `createSymbolicLink(at:targetPath:)` after the containing folder exists.
- [ ] **C12** Accumulate nested failures in the new file while building the remaining temporary content, upload that content, record its destination as a success without rollback, add each failed link path to the operation's existing partial-failure result, and suppress source trash for a moved folder with any nested failure.

**Phase 4: Documentation**

- [ ] **C13** Describe the rule in `resources/docs/USER_GUIDE.md` under file operations and in `resources/docs/remote-vm-browsing.md` under transfers, and add one feature entry to `resources/docs/CHANGELOG.md`.

---

## Testing

All tests run on Foundry. Unit and integration tests run over SSH; the single installed-app test runs through the guarded qualification runner.

### Unit Tests (`Tests/SymlinkTransferPlanTests.swift`)

- [ ] **T1** `testLinkInsideRootIsRecordedAsRelativeLink` - A two-hop nested link ending inside the root yields a relative target from the link's folder to the copied counterpart.
- [ ] **T2** `testLinkOutsideRootIsFollowed` - Two nested links resolving to the same outside folder are each walked as content.
- [ ] **T3** `testAbsoluteLinkInsideRootIsStillInside` - An absolute link that resolves inside the root counts as inside.
- [ ] **T4** `testReenteredDirectoryFailsWithLinkLoops` - Re-entering an active directory or repeating a location within one link chain fails with `linkLoops` and “The link {name} leads in a loop.”
- [ ] **T5** `testMissingTargetFailsWithLinkTargetMissing` - A link chain whose final target cannot be read fails with `linkTargetMissing` and “The link {name} points to an item that does not exist.”

### Unit Tests (`Tests/CrossProviderTransferTests.swift`)

- [ ] **T6** `testSelectedFileLinkCopiesTargetUnderLinkName` - With the fake providers, a selected two-hop link to a file uploads the final target's bytes under the selected link's name.
- [ ] **T7** `testSelectedFolderLinkCopiesFolderUnderLinkName` - A selected link to a folder uploads that folder's children under the link's name.
- [ ] **T8** `testNestedInsideLinkIsRecreatedAfterItsFolder` - A folder with an internal link uploads the folder first and then calls `createSymbolicLink` with a relative target.
- [ ] **T9** `testDanglingLinkFailsOnlyThatItem` - A dangling nested link is reported by path while the rest of its selected folder and a second selected item upload; the result records the folder destination as successful and leaves it in place.
- [ ] **T10** `testProviderMovesTrashOnlyCompleteSources` - A successful cross-provider link move trashes only the link, while a folder move with a failed nested link keeps the partial destination and leaves its whole source folder in place.

### Unit Tests (`Tests/TrashOperationsTests.swift`)

- [ ] **T11** `testTrashingLinkMovesLinkNotTarget` - Trashing valid and dangling links in a temporary home moves each link into the trash and leaves the valid link's referent in place.
- [ ] **T12** `testRestorePathsPreserveLink` - Direct restore and batch rollback each put a link back at the original path.

### Unit Tests (`Tests/FileOperationQueueTests.swift`)

- [ ] **T13** `testLocalCopyOfLinksKeepsLinks` - Copying selected valid, dangling and looping links, plus a folder containing them, between temporary folders preserves each target text and leaves each existing referent unchanged.
- [ ] **T14** `testLocalMoveOfLinkRenamesLink` - Moving a link between temporary folders yields a link at the destination and leaves the target unchanged.
- [ ] **T15** `testLocalTrashOfLinkKeepsTarget` - Trashing a link through the queue leaves the target file in place.

### Integration Tests (`Tests/RemoteIntegrationTests+Symlinks.swift`, live against devtest from Foundry)

Add the tests as an extension of `RemoteIntegrationTests`, exposing only the existing fixture, SSH quoting and path-check helpers that the new file reuses.

- [ ] **T16** `testSameHostCopyOfLinksKeepsLinks` - Copying selected valid, dangling and looping links, plus a folder containing them, within devtest preserves each target text.
- [ ] **T17** `testSameHostMoveOfLinkRenamesLink` - Moving a link within devtest renames it and leaves the target in place.
- [ ] **T18** `testTrashingRemoteLinkLeavesTarget` - Trashing valid and dangling links on devtest removes both links and leaves the valid link's target in place; restoring brings both links back.
- [ ] **T19** `testFileLinkUploadsTargetUnderLinkName` - Copying a local link to a file to devtest lands a regular file with the link's name and the target's bytes.
- [ ] **T20** `testFolderLinkDownloadsFolderUnderLinkName` - Copying a devtest link to a folder containing an internal link lands a real folder with the selected link's name and recreates the internal link on the Mac.
- [ ] **T21** `testFolderWithInsideAndOutsideLinksUploadsPerRule` - Copying a local folder holding one link inside it and one outside it to devtest recreates the first as a working relative link and the second as a regular file.
- [ ] **T22** `testLoopingLinkFailsItemAndCompletesFolder` - A folder holding a link to itself copies its other files to devtest and fails the link with `linkLoops`.
- [ ] **T23** `testDanglingLinkFailsItemOnly` - A dangling link and a plain file selected together across hosts copy the file and fail the link with the named `linkTargetMissing` message.
- [ ] **T24** `testCrossHostMoveOfLinkTrashesLinkOnly` - Moving a local link to devtest lands the file on the host, puts the link in the Mac's Trash, and leaves the local target in place.
- [ ] **T25** Add the tag-23 binary round-trip to `Tests/MessagesTests.swift`; `testSymlinkMessageRoundTripsThroughRealHelper` creates a link on devtest and refuses both regular and dangling-link destinations.

### E2E Tests (`Tests/UITests/DetoursUITests/DetoursUITests/RemoteSymlinkCopyUITests.swift`, guarded installed-smoke on Foundry against devtest)

- [ ] **T26** `testF5OnLocalLinkLandsTargetOnRemoteHost` - Run as the `transfer` installed smoke on `LINUX_TARGET`; the app control seam creates the local link and remote destination, F5 copies it, and the remote listing shows a regular file with the link's name.

---

## Build Log

- **C1** `createSymbolicLink(at:targetPath:)` added to `FileProvider` with a default that throws `FileProviderError.unsupportedOperation("createSymbolicLink")`, so the Windows provider and every test fake keep compiling and refuse the call.
- **C2** `LocalFileProvider.createSymbolicLink` refuses any destination that `lstat` can see (regular file, link, dangling link) with `destinationExists`, then calls `FileManager.createSymbolicLink(atPath:withDestinationPath:)` with the raw target text.
- **C3** Tag 18 was already `watchEvent` on the client side, so the spec's tag collided with a live message; the new `symlink` message uses tag 23, the next free tag, in `RPCMessage` and `ServerRPCMessage`. Named `Symlink` in the message-type table, listed as state-changing in `RPCHandler`, served by `FileOperations.symlink(path:targetPath:)` with an `lstat` destination check. `MessagesTests` round-trips it.
- **C4** `RemoteFileProvider.createSymbolicLink` sends the raw target bytes as a `RemotePath`; `UITestRemoteProvider` confines the link path to its root, refuses an existing destination without following it, and records the call in the provider history like `createDirectory`.
- **C6** `CopyfileHelper` sets `COPYFILE_NOFOLLOW_SRC` on every copy and adds `COPYFILE_RECURSIVE` only when `lstat` reports a real directory, so a selected link copies as a link on the Mac.
- **C7** The helper's `copy` recreates a link source with its original target text through `createSymbolicLink`, dangling or not, and names it like a file when picking a " copy" suffix, since a dangling link has no resource values to read.
- **C8** `TrashOperations` addresses trash, restore and rollback paths through `resolvingParent(of:)`, which resolves every component but the last, and checks source, trash and restore destinations with `lstat` through the new `Server/PathProbe.swift`, so a valid or dangling link moves as a link and restores as a link.
- **C5** `FileOperationError.linkTargetMissing(name:)` and `linkLoops(name:)` added with the spec's messages in `LocalizedError` and a title/body pair in `FileOperationQueue.errorPresentation`.
