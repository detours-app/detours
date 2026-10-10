# RAR extraction fixtures

`manifest.json` records each source URL, original path, byte count and SHA-256, plus the expected extracted names and reference hashes. These files are public test data. No fixture was produced by Detours or a RAR writer during this work.

## Encrypted multipart reference

Source: [SharpCompress at eab8154e3fd03fade8925e82456048ed49afd02b](https://github.com/adamhathcock/sharpcompress/tree/eab8154e3fd03fade8925e82456048ed49afd02b/tests/TestArchives). Its MIT notice is retained in `LICENSE.sharpcompress.txt`.

`sharpcompress/Rar.EncryptedParts.part01.rar` through `part06.rar` form one older-format encrypted RAR set. The public password is `test`, recorded by the upstream `Rar_Multi_Archive_Encrypted` test. The three files under `references/sharpcompress/` are byte-identical upstream originals, not decoder output. The executable reference is read as bytes only and must never be executed.

The pinned upstream `.gitattributes`, retained as `sharpcompress.gitattributes.txt`, requires `*.txt text eol=crlf`. The text reference keeps the upstream Git blob's LF bytes; its expected extracted bytes and hash apply the upstream CRLF checkout rule. The qualification test reconstructs those bytes from the original and compares them exactly, without ignoring text differences.

`RarFixtureTests/testPinnedInputsMatchIndependentReferences` checks every pinned hash and licence, then uses full free 7-Zip on Foundry to extract all six parts and compares every output byte against the originals. Qualification is required before this set is used as a positive Detours fixture. This set does not provide combined RAR5 encryption-and-multipart coverage.

Set `DETOURS_RAR_REFERENCE_7ZZ` to the official [7-Zip 26.02 macOS executable](https://github.com/ip7z/7zip/releases/download/26.02/7z2602-mac.tar.xz). Its distribution archive has SHA-256 `1cf6760579502f87e591ff5c73a005ec50b3e4d6f507e8b038382d563c3175b9`. Foundry's Homebrew 26.02 copy lists RAR formats but omits RAR decompression codecs; it cannot qualify this set.

Missing and damaged copies belong only in test-owned verification workspaces. The committed archives and references are immutable inputs.

## RAR4 and RAR5 corpus

The ISC-licensed [rarfile corpus at d2f7df6fc843dae356fd6b0a85971dc36fd6e757](https://github.com/markokr/rarfile/tree/d2f7df6fc843dae356fd6b0a85971dc36fd6e757/test/files) supplies ordinary, solid, empty, Unicode, content-encrypted, header-encrypted, old/new multipart, CRC, BLAKE, link and traversal cases. `LICENSE.rarfile.txt` retains its notice. Encrypted inputs use the upstream public password `password`.

Each committed `.exp` is upstream expectation text. The manifest transcribes its names, byte counts, checksums, timestamps and link targets. The `stest` byte sequence comes from the retained upstream `test_seek.py`: 512 four-byte lines, `000\n` through `511\n`. Its SHA-256 is derived from that independent recipe. Other entries retain upstream CRC expectations where original bytes are unavailable. Encrypted RAR5 checksums may be keyed; their plaintext is compared with the independent seek sequence instead. RAR4 timestamps have local-time semantics; RAR5 timestamps retain their upstream UTC offsets.

`rar5-dups.rar` contains duplicate-content references with distinct names, not duplicate filenames. Filename-collision tests must create deterministic damaged copies within the test-owned verification workspace. The symlink fixtures include escaping links and are refusal cases for complete extraction. No fixture expectation is generated from Detours decoder output.
