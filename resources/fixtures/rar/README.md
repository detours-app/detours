# RAR extraction fixtures

`manifest.json` records each source URL, original path, byte count and SHA-256, plus the expected extracted names and reference hashes. These files are public test data. No fixture was produced by Detours or a RAR writer during this work.

## Encrypted multipart reference

Source: [SharpCompress at eab8154e3fd03fade8925e82456048ed49afd02b](https://github.com/adamhathcock/sharpcompress/tree/eab8154e3fd03fade8925e82456048ed49afd02b/tests/TestArchives). Its MIT notice is retained in `LICENSE.sharpcompress.txt`.

`sharpcompress/Rar.EncryptedParts.part01.rar` through `part06.rar` form one older-format encrypted RAR set. The public password is `test`, recorded by the upstream `Rar_Multi_Archive_Encrypted` test. The three files under `references/sharpcompress/` are byte-identical upstream originals, not decoder output. The executable reference is read as bytes only and must never be executed.

`RarFixtureTests/testPinnedInputsMatchIndependentReferences` checks every pinned hash and licence, then uses full free 7-Zip on Foundry to extract all six parts and compares every output byte against the originals. Qualification is required before this set is used as a positive Detours fixture. This set does not provide combined RAR5 encryption-and-multipart coverage.

Missing and damaged copies belong only in test-owned verification workspaces. The committed archives and references are immutable inputs.
