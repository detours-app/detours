# RAR Extraction

## Meta

- Status: Reviewed
- Branch: feature/rar-extraction

---

## Business

### Goal

Open received RAR archives inside Detours without buying or opening a separate archive app.

### Proposal

Add RAR extraction alongside the existing archive formats, including password-protected archives and archives split across several files. Support files on the Mac and on the supported remote hosts; keep archive creation unchanged.

### Behaviors

- RAR extraction uses the existing Extract Here command, keyboard shortcut and file-opening behavior. The user can select a single RAR file or any recognized part of a multipart RAR archive. Detours finds the first part in the same folder and extracts the set once. It does not ask the user to select every part.
- Encrypted archives use the existing password sheet. The password remains concealed, an empty submission asks for a password, and a confirmed incorrect password allows another attempt. Cancel closes the sheet without extracting anything. A damaged archive or missing part must not be reported as an incorrect password.
- When a part is missing, the error names the missing file when known and explains that all parts must be together in the same folder before extraction is retried. Detours does not search other folders, download parts or open a file picker. Ambiguous multipart sets fail with an explanation rather than choosing one.
- Selecting several parts of one archive starts one extraction. When extraction needs a containing folder, its name omits the archive's part number; existing single-file and single-folder naming rules remain unchanged. Successful extraction selects the result in the current pane.
- Existing progress, cancellation and undo controls apply. Local destination conflicts retain Keep Both, Replace and Stop; remote extraction retains its existing choice of a new, unused destination name.
- Cancelling before the result is placed in its destination leaves existing files unchanged. A completed extraction can be undone without deleting the archive or losing files displaced through Replace.
- The Mac and macOS/Linux remote hosts need no additional archive app. Windows remote hosts use the existing free 7-Zip installation requirement; missing or incompatible installations receive a specific explanation.
- RAR never appears in the archive-creation format picker. No purchase, paid software or RAR creation is required. Documentation describes RAR as extraction-only.

### Acceptance Criteria

- [ ] **A1** Ordinary and solid RAR4 and RAR5 archives extract correctly on the Mac and supported macOS, Linux and Windows remote hosts.
- [ ] **A2** Password-protected contents and concealed filenames open with the correct password, and a confirmed wrong password can be corrected without partial results.
- [ ] **A3** Split archives, including password-protected split archives, extract once when any recognized part is selected and all required parts are together.
- [ ] **A4** Missing, damaged, changed or unsafe archive contents leave original archives and existing destination files intact and explain why extraction stopped.
- [ ] **A5** Progress, cancellation, destination naming, conflict handling, selection and undo follow the existing archive workflow.
- [ ] **A6** No RAR creation option or paid dependency is introduced, and existing ZIP, 7Z and TAR features continue to work.
- [ ] **A7** Passwords are absent from saved operation records and diagnostic output.
- [ ] **A8** The GitHub page and formatted HTML user guide accurately describe RAR extraction, passwords, split archives and the Windows requirement.

### Out of scope

- Creating or modifying RAR archives.
- Repairing damaged archives, using recovery files or executing self-extracting programs.
- Browsing archive contents as folders.
- Finding missing parts outside the selected folder.
- Changing password support for other archive formats on Windows.
- Publishing the GitHub page or making a public release.

---

## Technical

### Approach

Extend the already bundled 7-Zip 26.02 decoder with RAR/RAR5 handlers and their required codecs. Use that reader locally and in the existing macOS/Linux helper. Extend the Windows remote integration with the existing free installed 7z.dll, adding the corresponding readers, password callbacks and controlled volume callbacks. Do not introduce a subprocess-based RAR extractor, a paid executable or another Windows helper.

Separate extraction formats from creation choices before adding RAR. Discover the complete multipart source set before accepting extraction, bind every part to the existing observed-source contract, and stream decoded bytes only into operation-owned output handles. Preserve the existing publication, conflict and undo mechanisms. This is an extension of familiar controls, so no UI prototype is needed.

#### Format and volume contract

The existing shared reader takes SevenZipArchiveWriter.Format, and ArchiveDialog enumerates ArchiveFormat.allCases. Introduce a reader-specific format type with RAR and RAR5 handlers; preserve existing serialized creation values and explicitly enumerate writable formats. Reject RAR creation at app, helper and Windows request boundaries before allocating output.

Recognize single .rar files, modern .partN.rar sets including zero-padded numbers, and legacy .rar/.r00/.r01 sequences. Extension matching is case-insensitive, but source lookup follows the actual filesystem and refuses ambiguous matches. A numbered suffix alone is not proof of a RAR archive: validate the RAR signature and volume headers. Resolve a selected continuation to its canonical first part in the same provider and directory. Deduplicate selections by that first part's observed identity.

Discovery uses the decoder's requested next volume and validated headers, not every file sharing a prefix. Reject mixed sets, missing first/intermediate/final parts and inconsistent numbering. Limit one set to 1,024 parts, with a specific limit error before output allocation. Do not hold one descriptor open per part: open observed handles on demand and close owned handles on every exit.

Add IArchiveOpenVolumeCallback to the native bridge and the Windows bridge. Discovery may inspect only regular sibling files through the pinned parent-directory boundary; extraction may reopen only the accepted volume list. Reject absolute paths, separators, parent traversal, NULs, symlinks and Windows reparse-point source files. Do not follow paths or URLs supplied by archive metadata.

Carry canonical first part, ordered part locations and corresponding observations through archive layout inspection, accepted intent and preparation. Record identity, version, byte count and content proof for every part, with passwords excluded. Revalidate all parts before preparation completes and through the existing commit source checks. Replacing or changing any part invalidates the operation. Single-file archive behavior remains compatible. An older helper or Windows script that lacks the RAR contract returns an explicit unsupported-capability error; it must not fall back to an unverified extraction path.

A successful reader Open call is insufficient proof of completeness. Check archive error properties, including kpidErrorFlags/kpidError, after volume discovery and before allocating member output. Repeat integrity checks during decoding; a missing final part or checksum failure must never yield a successful partial archive.

#### Safe output and passwords

Reuse the current extraction planning rules for names, links and owned output. Add a RAR-specific local adapter rather than moving unrelated ZIP/TAR implementations. Validate the entire member list before writing: reject absolute and parent-relative paths, duplicate or filesystem-equivalent names, file/directory conflicts, unsupported special files and link escapes. Windows also rejects drive-relative, UNC and alternate-data-stream paths. Safe links follow existing platform policies; unsupported link forms fail explicitly.

Decode into exclusive, empty handles under an operation-owned private working folder. Enforce each declared file length, use checked arithmetic for total lengths and reject unrepresentable lengths. Check known required space against available destination space; a later disk-full failure still rolls back owned output. Confirm checksum success and final source proofs before placing results in the destination.

Local RAR publication uses the existing extraction rollback ledger, Keep Both/Replace/Stop and undo registration. Remote RAR uses accepted preparation, one unused destination and idempotent commit. Cancellation before publication removes only operation-owned temporary data. A cancellation racing a completed commit reports the committed result and keeps its undo; it must not claim that nothing happened. Archive parts are never removed.

Pass passwords only through in-memory reader callbacks and transient existing request fields. Keep them out of command arguments, environment variables, accepted intents, persisted journals, receipts and logs. Do not apply the local ZIP password byte limit to RAR. Clear owned mutable password buffers where the current callback boundary permits it.

Separate password-required, definite wrong-password, missing-volume, changed-source, unsupported-method, corruption and cancellation outcomes. Older encrypted data can make corruption indistinguishable from a wrong password: report that ambiguity without automatically looping through an incorrect-password prompt. Header-encrypted archives can request a password during layout discovery, before an operation is accepted.

Windows layout inspection currently rejects passwords, and its native 7-Zip reader opens only 7Z. Extend only the RAR branch with opening/extraction password callbacks and volume callbacks. Resolve 7z.dll beside the existing trusted 7z.exe selection, never from the archive folder. Detect absent or incompatible RAR handlers and direct the user to the official free 7-Zip Windows download; no silent fallback.

#### Fixture contract

Use committed, independently sourced fixtures in resources/fixtures/rar/. Record pinned upstream URL, original filename, archive SHA-256, licence and expected extracted names, bytes, hashes and supported timestamps in README.md and manifest.json. Expectations come from upstream reference files or tests, not from the decoder under test. Public fixture passwords are test data, not live credentials.

Use the ISC-licensed rarfile corpus at commit d2f7df6fc843dae356fd6b0a85971dc36fd6e757 for RAR4/RAR5 ordinary, solid, Unicode, encrypted contents, encrypted headers, old/new multipart names, links, duplicate names and hostile link traversal. Include both CRC and BLAKE integrity cases. For encrypted multipart coverage, use SharpCompress commit eab8154e3fd03fade8925e82456048ed49afd02b: tests/TestArchives/Archives/Rar.EncryptedParts.part01.rar through part06.rar, with expected bytes from tests/TestArchives/Original and the MIT notice. Read the archived executable fixture as bytes only; never execute it.

Qualify that six-part set on Foundry with full free 7-Zip and compare its output to the upstream original files before using it as a positive fixture. SharpCompress's own reader cannot decode this combination; that limitation is not proof of fixture corruption or proof that Detours can read it. Qualification failure blocks the combined test, without substituting separate encryption and multipart checks. The combined fixture covers the older RAR format; RAR5 encryption and multipart have separate fixtures, which must not be reported as combined RAR5 coverage.

Create missing-part and deterministic damaged copies only within test-owned Foundry or Foundry-orchestrated helper workspaces. Never invoke RAR or WinRAR to generate fixtures. Fixture absence is a failure, not a reason to skip required coverage.

### Approach Validation

- The existing vendored README explicitly excludes RAR; recognizing a filename alone cannot add extraction. [7-Zip](https://www.7-zip.org/) lists RAR as unpacking-only, which fits the agreed scope.
- [7-Zip's licence](https://www.7-zip.org/license.txt) permits no-cost use but includes the unRAR restriction against recreating RAR compression. Keep all applicable notices; do not describe that restriction as an unrestricted licence.
- Upstream [RAR5 handling](https://github.com/ip7z/7zip/blob/26.02/CPP/7zip/Archive/Rar/Rar5Handler.cpp) exposes missing-volume and header errors independently of a successful open. The plan therefore requires complete-set preflight and final integrity checks.
- A [7-Zip support discussion](https://sourceforge.net/p/sevenzip/discussion/45797/thread/68a716b035/) illustrates ambiguous password/data errors. It motivates explicit ambiguity handling, not an assertion about a current decoder defect.
- The [SharpCompress encrypted multipart fixture](https://github.com/adamhathcock/sharpcompress/blob/eab8154e3fd03fade8925e82456048ed49afd02b/tests/TestArchives/Archives/Rar.EncryptedParts.part01.rar) is MIT-licensed; its [reader limitation](https://github.com/adamhathcock/sharpcompress/commit/7989ab2e281cc760c712e5b4ce26f748583b1fcd) requires an explicit fixture qualification check against upstream originals.
- The pinned [rarfile test corpus](https://github.com/markokr/rarfile/tree/d2f7df6fc843dae356fd6b0a85971dc36fd6e757/test/files) supplies independently authored inputs and expected behavior without requiring a RAR writer.
- UI, security and test specialists inspected the current extraction paths. Their findings added full-volume source proofs, partial-open error checks and actual Windows password support to this design.

### Risks

| Risk | Mitigation |
| --- | --- |
| A partial multipart archive opens successfully | Inspect decoder error properties and require complete decoding before publication. |
| A source part changes between inspection and commit | Bind and revalidate every observed part, not only the first file. |
| Archive names or links escape the destination | Validate all members, pin directory boundaries and expose only owned output handles. |
| Corruption is mistaken for a wrong password | Preserve distinct errors and report genuinely ambiguous encrypted-data failures. |
| RAR support accidentally becomes a creation option | Separate readable/writable formats and reject creation at every request boundary. |
| Windows coverage passes without exercising its reader | Require real Windows RAR, encrypted and multipart fixtures through 7z.dll. |
| A decoder or fixture notice is omitted | Retain pinned provenance and applicable licence files with the added sources. |

### Implementation Plan

- [x] **C1** Separate extraction and creation capabilities in src/Utilities/CompressionTools.swift, Shared/SevenZipArchiveReader.swift and ArchiveDialog; add RAR recognition and explicit app/helper/Windows creation rejection.
- [x] **C2** Extend SevenZip/ and ArchiveStreamBridge/ with pinned RAR/RAR5 handlers, codecs, complete-open error inspection, password/volume callbacks and retained licence notices.
- [x] **C3** Add the fixture corpus and manifest under resources/fixtures/rar/ with independent expected contents, pinned provenance, public fixture-password metadata and qualification of the encrypted multipart reference set. Copy these fixtures to devtest and include them in the helper cache hash so paired reader tests run during the required Linux build.
- [x] **C4** Add shared RAR volume discovery and extend archive inspection, accepted source observations and commit validation to bind the complete ordered volume set.
- [ ] **C5** Add local RAR extraction through the shared reader in src/Operations/, preserving owned-output validation, existing conflict publication, cancellation and undo.
- [ ] **C6** Extend Server/ServerArchiveExtractionReader.swift, ServerArchiveExtractionPlan and ServerOperationService extraction handling for encrypted multipart RAR and all-volume source proofs.
- [ ] **C7** Extend src/Remote/Windows/WindowsOperationArchiveLayout.swift and WindowsOperationSevenZipInterfaces/Reader/Runtime/Extraction.swift for RAR/RAR5, password and volume callback interfaces, controlled volumes and safe link properties.
- [ ] **C8** Update file opening, Extract Here availability, multi-selection deduplication and FileOperationQueue error mapping; reuse the existing password sheet and add precise volume/tool/integrity messages.
- [ ] **C9** In resources/scripts/build-server-linux.sh, copy Tests/ServerRarExtractionTests.swift to devtest and add the test file to the ServerArchiveOperationsTests sources, as ServerArchiveStreamTests is today; add it to resources/scripts/server-cache-hash.sh. Fixture copying and cache tracking are prerequisites completed under C3. RarExtractionUITests run through the guarded installed-smoke runner's --test-filter without joining a default workflow group.
- [ ] **C10** Update README.md and resources/docs/USER_GUIDE.md, regenerate resources/docs/USER_GUIDE.html with resources/scripts/render-user-guide.mjs, and document RAR extraction-only support, passwords, multipart limits and Windows prerequisites.

---

## Testing

Follow the repository machine boundary: edit and commit on Spectre, synchronize Foundry to the same clean commit, build using resources/scripts/build.sh, and run tests on Foundry. Linux helper checks use the existing Foundry-controlled devtest path; Windows checks use the existing detours-windows fixture host. No fixture setup, runtime probes or tests run on Spectre. The final normal Spectre build/install follows successful Foundry verification and the required relaunch notice.

Each named case below is a focused filter, not authorization for a broad campaign. Update Tests/TEST_LOG.md after every run. Run the existing regressions in T18–T22 individually. A full suite requires Marco's separate approval after every targeted test is green. Missing required tools, fixtures or hosts block qualification rather than silently skipping it.

Shared reader tests live in Tests/DetoursProcessTests/RarArchiveStreamTests.swift; local tests in Tests/RarArchiveOperationTests.swift; helper tests in Tests/ServerRarExtractionTests.swift; Windows cases extend WindowsAcceptedOperationLiveTests in Tests/WindowsAcceptedOperationLiveTests+RarExtraction.swift. Installed-app tests use RarExtractionUITests beside ArchivePasswordUITests.

### Reader and local tests

- [x] **T1** (C3) RarFixtureTests/testPinnedInputsMatchIndependentReferences checks fixture hashes and licences, decodes the six-part encrypted reference with full free 7-Zip on Foundry and compares every output byte to upstream originals.
- [x] **T2** (C1, C4) RarArchiveOperationTests/testRecognizesRarSetsWithoutOfferingRarCreation covers case variants, later-part entry, false numbered-file matches, unchanged creation choices and direct RAR-creation rejection.
- [ ] **T3** (C2, C3, C9) RarArchiveStreamTests/testReadsAllRarFixtureFamilies compares ordinary, solid, Unicode, empty, encrypted-content and encrypted-header RAR4/RAR5 output against the independent manifest on macOS and Linux.
- [x] **T4** (C2, C3, C4) RarArchiveStreamTests/testVolumeCallbacksRefuseUnacceptedPaths covers missing first/middle/final parts, mixed sets, the 1,024-part limit, ambiguous names, source-link substitutions, forbidden path requests and descriptor cleanup.
- [x] **T5** (C2, C3) RarArchiveStreamTests/testSeparatesPasswordIntegrityAndCancellation covers absent/wrong/correct passwords, ambiguous encrypted corruption, checksum failure, declared-size mismatch, cancellation and closed owned handles.
- [ ] **T6** (C3, C4, C5) RarArchiveOperationTests/testMultipartExtractionUsesEveryObservedPart covers both naming schemes, encrypted multipart input, selected continuation, changed parts, final source-proof rejection and absence of the password from operation records and diagnostics.
- [x] **T7** (C3, C5) RarArchiveOperationTests/testUnsafeOrDamagedRarCannotPublish covers traversal, duplicate normalized names, link escapes, truncation, disk-full failure and no changes to existing occupants.
- [ ] **T8** (C3, C5) RarArchiveOperationTests/testRarConflictCancellationAndUndoPreserveFiles covers Keep Both, Replace, Stop, destination races, pre-publication cancellation, commit-race reporting and restoration of displaced files.

### Helper and Windows tests

- [ ] **T9** (C3, C4, C6, C9) ServerRarExtractionTests/testAcceptedRarVerifiesAllPartsAndCommitsOnce runs on macOS and Linux, checking every fixture family, unpublished preparation, changed volumes, source proofs and idempotent commit.
- [ ] **T10** (C3, C4, C6, C9) ServerRarExtractionTests/testRarFailurePreservesFilesAndPasswordPrivacy covers missing parts, wrong passwords, corruption, unsafe links, cancellation and absence of passwords from records and diagnostics.
- [ ] **T11** (C3, C4, C7, C9) WindowsAcceptedOperationLiveTests/testAcceptedRarMatchesFixtureManifest exercises real RAR4/RAR5 ordinary, solid, both encryption modes and encrypted multipart extraction through the installed free DLL.
- [ ] **T12** (C3, C4, C7, C9) WindowsAcceptedOperationLiveTests/testRarVolumesAndFailuresCannotEscape covers continuation selection, replaced/missing parts, idempotent commit, drive/UNC/ADS paths, unsafe links/reparse points, cancellation and password privacy.
- [ ] **T13** (C7) WindowsArchiveScriptTests/testRarCapabilitiesDoNotChangeOtherFormats covers missing/incompatible DLL errors, no archive-folder DLL lookup and unchanged Windows ZIP/7Z password restrictions.

### Installed-app and documentation tests

- [ ] **T14** (C3, C5, C8, C9) RarExtractionUITests/testEncryptedMultipartRarRetriesAndUndoes uses the guarded installed-smoke runner to open a later part, reject a password, extract with the correct one, select the result and undo.
- [ ] **T15** (C3, C5, C8, C9) RarExtractionUITests/testMissingVolumeExplainsFailure uses the guarded runner to confirm actionable missing-part text, no partial result and no incorrect-password prompt.
- [ ] **T16** (C3, C5, C8, C9) RarExtractionUITests/testSelectingSeveralPartsExtractsOnce confirms one operation/result for a multi-selected set and inspects the actual progress and result UI.
- [ ] **T17** (C10) Regenerate USER_GUIDE.html, render README.md to a scratch HTML file with the bundled markdown-it, open both with /agent-browser, confirm every link resolves and compare the archive descriptions with the platforms T3, T9 and T11 proved.

### Focused regressions

Run each filter separately, after its related RAR checks pass. Required Windows tests use the existing DETOURS_7ZIP_FIXTURE prerequisite containing official free Windows 7z.exe and 7z.dll. Fixture setup and installed-app checks follow resources/docs/testing-runbook.md, including the independent consent-prompt sentry.

- [ ] **T18** (C1, C2, C5) Pass ArchiveOperationTests/testCreateAndExtractEncryptedZipRoundTrips, testEncryptedZipWrongPasswordRetriesWithoutPartialOutput, testCreateListAndExtractEncrypted7zRoundTrips, testEncrypted7zWrongPasswordDiffersFromCorruption and testEncryptedAESZipPromptsAndRoundTripsThroughSevenZip individually.
- [ ] **T19** (C4, C5, C6) Pass AcceptedExtractionCallerTests/testSingleItemNamesAndWrappersMatchAllExistingFormats, testEncryptedExtractionRequestsPasswordAndRetainsRetry and testChangedArchiveAfterInspectionCannotBeExtracted individually.
- [ ] **T20** (C2, C6) Pass ServerArchiveStreamTests/testNativeReaderListsAndExtractsOwnedStreamsAcrossFormats, testNativeReaderRefusesNonemptyOutputAndPropagatesCancellation and testExternalLinkArchiveRetainsExistingExtractionRefusal individually.
- [ ] **T21** (C7) Pass WindowsAcceptedOperationLiveTests/testAcceptedSevenZipCreationAndExtractionMatchExistingLayout and WindowsArchiveScriptTests/testArchiveExtractRejectsEscapingEntries individually.
- [ ] **T22** (C1, C8, C9) Pass ArchivePasswordUITests/testCreationControlsFollowSelectedFormat and testWrongPasswordShowsRetrySheet individually through the guarded installed-smoke runner.

---

## Build Log

- **T7** Foundry at `0210b48e` passed the unsafe/damaged local RAR check with traversal, duplicate and equivalent names, escaping links, truncation, space shortage and injected output-boundary disk-full errors. Existing occupants and archive inputs remain intact; private staging is removed. Both helpers and the signed app built successfully.

- **C4, T2, T4** Bound discovery and accepted requests to ordered, observed sibling volumes with all-part commit proofs and an explicit helper capability. Continuations are inspected without joining siblings, then the complete set receives strict integrity checks. Foundry at `d834b705` passed T2 and T4; Linux passed T4 among 20 process checks plus 125 helper checks. Both helpers and the signed app built successfully. Tests cover encrypted modern and legacy sets, missing/mixed/ambiguous parts, substituted links, forbidden paths, the 1,024-part limit and closed handles.

- **C3 ordering** Marco approved moving fixture copying and cache tracking from C9 into C3 because C3's paired shared-reader test is automatically included in the required Linux helper build. The remaining C9 work stays in sequence.

- **C1** Added reader-specific formats and an explicit writable-format list, retained serialized creation values, recognized `.rar` case-insensitively, and rejected RAR creation before output allocation in app/helper/Windows paths. Creation-based round trips enumerate writable formats. SwiftLint passed. Foundry `resources/scripts/build.sh --no-install` at `bedd0349` built both helpers and the signed app; embedded Linux checks passed 18 process and 125 helper tests. Continuation/signature recognition and its paired T2 remain with C4; RAR decoding remains unavailable until C2/C5.
- **C2** Imported the RAR/RAR5 handlers and dependencies from the same verified 26.02 source archive, retaining licence notices. The bridge exposes controlled sibling-volume callbacks, limits distinct parts to 1,024, opens additional part handles only while reading, checks archive error properties before member output, enforces declared lengths and separates password/integrity/volume outcomes. An unnecessary disk-image implementation caused an initial Linux link failure and was removed. Foundry build at `afe6a720` passed for both helpers and the signed app; embedded Linux checks passed 18 process and 125 helper tests. RAR fixture qualification follows in C3 and its paired tests.

- **C3** Added pinned SharpCompress and ISC rarfile corpora, independent expectations and licences. Full official 7-Zip qualified the six-part encrypted reference against upstream originals, including the upstream text checkout convention. Foundry at `02e63cb5` passed T1 and T5; Linux passed T5 among 19 process checks and 125 helper checks. Both helpers and the signed app built successfully.
