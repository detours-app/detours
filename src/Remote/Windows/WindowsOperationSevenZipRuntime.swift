import Foundation

extension WindowsOperationScripts {
    static let sevenZipRuntimeHelpers = #"""
    if (-not ('DetoursSevenZipLibrary' -as [type])) {
    Add-Type -TypeDefinition @'
    \#(sevenZipInterfaces)
    \#(sevenZipStreams)
    \#(sevenZipReader)
    public sealed class DetoursSevenZipLibrary : IDisposable {
        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern IntPtr LoadLibraryExW(string path, IntPtr file, uint flags);
        [DllImport("kernel32.dll", CharSet = CharSet.Ansi, SetLastError = true)]
        private static extern IntPtr GetProcAddress(IntPtr module, string name);
        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool FreeLibrary(IntPtr module);
        [UnmanagedFunctionPointer(CallingConvention.StdCall)]
        private delegate int CreateObject(ref Guid format, ref Guid contract, out IntPtr instance);
        private IntPtr library;
        private readonly CreateObject create;
        public DetoursSevenZipLibrary(string path) {
            if (IntPtr.Size != 8) throw new IOException("Accepted 7z operations require 64-bit Windows PowerShell.");
            library = LoadLibraryExW(Path.GetFullPath(path), IntPtr.Zero, 0x1100);
            if (library == IntPtr.Zero) throw new Win32Exception(Marshal.GetLastWin32Error());
            try {
                IntPtr address = GetProcAddress(library, "CreateObject");
                if (address == IntPtr.Zero) throw new IOException("The installed 7z library has no archive interface.");
                create = (CreateObject)Marshal.GetDelegateForFunctionPointer(address, typeof(CreateObject));
            } catch { FreeLibrary(library); library = IntPtr.Zero; throw; }
        }
        public void CreateArchive(Stream output, DetoursSevenZipSource[] sources, string cancellationPath) {
            Guid format = new Guid("23170F69-40C1-278A-1000-000110070000");
            Guid contract = typeof(IDetoursSevenZipWriter).GUID;
            IntPtr pointer;
            Marshal.ThrowExceptionForHR(create(ref format, ref contract, out pointer));
            if (pointer == IntPtr.Zero) throw new IOException("The installed 7z library cannot create this archive format.");
            object archive;
            try { archive = Marshal.GetObjectForIUnknown(pointer); } finally { Marshal.Release(pointer); }
            try {
                DetoursSevenZipCancellation cancellation = new DetoursSevenZipCancellation(cancellationPath);
                using (DetoursSevenZipUpdate callback = new DetoursSevenZipUpdate(sources, cancellation)) {
                    int result = ((IDetoursSevenZipWriter)archive).UpdateItems(new DetoursSevenZipOutputStream(output, cancellation), (uint)sources.Length, callback);
                    if (cancellation.failure != null) throw new IOException(cancellation.failure);
                    Marshal.ThrowExceptionForHR(result);
                    callback.Verify();
                    cancellation.Check();
                }
            } finally { Marshal.FinalReleaseComObject(archive); }
        }
        public DetoursSevenZipArchive OpenArchive(Stream input, string cancellationPath) {
            Guid format = new Guid("23170F69-40C1-278A-1000-000110070000");
            Guid contract = typeof(IDetoursSevenZipReader).GUID;
            IntPtr pointer;
            Marshal.ThrowExceptionForHR(create(ref format, ref contract, out pointer));
            if (pointer == IntPtr.Zero) throw new IOException("The installed 7z library cannot read this archive format.");
            object archive;
            try { archive = Marshal.GetObjectForIUnknown(pointer); } finally { Marshal.Release(pointer); }
            return new DetoursSevenZipArchive(archive, input, cancellationPath);
        }
        public void Dispose() {
            if (library != IntPtr.Zero) {
                if (!FreeLibrary(library)) throw new Win32Exception(Marshal.GetLastWin32Error());
                library = IntPtr.Zero;
            }
        }
    }
    '@
    }
    function Write-WindowsSevenZipArchive($Context, $Sources, $Output) {
        $tool = Resolve-ArchiveTool @('7z.exe', '7z')
        $libraryPath = Join-Path ([System.IO.Path]::GetDirectoryName($tool)) '7z.dll'
        $library = [DetoursSevenZipLibrary]::new($libraryPath)
        try {
            $items = [System.Collections.Generic.List[DetoursSevenZipSource]]::new()
            foreach ($source in $Sources) {
                foreach ($member in $source.plan.inputs) {
                    Assert-WindowsOperationActive $Context
                    $relative = [System.Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($member.relativePath))
                    $item = [DetoursSevenZipSource]::new()
                    $item.name = if ($relative.Length -eq 0) { $source.name } else { $source.name + '/' + $relative }
                    $item.path = $member.sourcePath; $item.directory = $member.observation.kind -eq 'directory'
                    $item.length = $member.observation.byteCount; $item.sha256 = $member.observation.sha256
                    $item.timestamp = [System.IO.File]::GetLastWriteTimeUtc($item.path).ToFileTimeUtc()
                    $item.attributes = [uint32][System.IO.File]::GetAttributes($item.path)
                    $items.Add($item)
                }
            }
            $cancel = Join-Path $Context.root ((Get-OperationKey $Context.identity.id) + '.cancel')
            $library.CreateArchive($Output, $items.ToArray(), $cancel)
        } finally { $library.Dispose() }
    }
    """#
}
