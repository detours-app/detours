# 7-Zip 26.02

Source: [7-Zip 26.02](https://github.com/ip7z/7zip/tree/26.02).

The files here implement the upstream Format7z bundle and ZIP, TAR, gzip, bzip2, xz, RAR and RAR5 handlers, with their required codecs, portable C implementations of optimized routines and Unix platform support. Detours uses their stream interfaces so the operation helper creates and owns archive output handles. RAR handlers are extraction-only. Their unRAR licence permits no-cost extraction but prohibits using this code to develop a RAR (WinRAR) compatible archiver or recreate RAR compression; retain unRarLicense.txt when distributing these sources.

Local changes: AesOpt.c explicitly includes emmintrin.h for the SSE types it uses. Apple's explicit Clang modules do not expose these declarations through wmmintrin.h alone. See [Clang module visibility](https://clang.llvm.org/docs/Modules.html). DllExports2.cpp retains UTF-8 decoding at initialization because Detours passes UTF-8 names independently of the embedding process locale; locale-selected decoding corrupts unflagged Unix ZIP names.

Source archive SHA-256: `7e5600ad0b21918bc41803bd84d0c2967e097fb7fbaa2e7aeb90beeb1121e54b`. Licensing is retained in License.txt and copying.txt; the upstream unRarLicense.txt is retained with the license package.
