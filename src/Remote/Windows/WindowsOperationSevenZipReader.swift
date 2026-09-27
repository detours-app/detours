import Foundation

extension WindowsOperationScripts {
    static let sevenZipReader = #"""
    [ComImport, Guid("23170F69-40C1-278A-0000-000600600000"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    public interface IDetoursSevenZipReader {
        [PreserveSig] int Open([MarshalAs(UnmanagedType.Interface)] IDetoursSevenZipSeekInput stream, IntPtr limit, IntPtr callback);
        [PreserveSig] int Close();
        [PreserveSig] int GetNumberOfItems(out uint count);
        [PreserveSig] int GetProperty(uint index, uint property, out DetoursSevenZipVariant value);
        [PreserveSig] int Extract([MarshalAs(UnmanagedType.LPArray, SizeParamIndex = 1)] uint[] indices, uint count, int test,
            [MarshalAs(UnmanagedType.Interface)] IDetoursSevenZipExtract callback);
        [PreserveSig] int GetArchiveProperty(uint property, out DetoursSevenZipVariant value);
        [PreserveSig] int GetNumberOfProperties(out uint count);
        [PreserveSig] int GetPropertyInfo(uint index, out IntPtr name, out uint property, out ushort type);
        [PreserveSig] int GetNumberOfArchiveProperties(out uint count);
        [PreserveSig] int GetArchivePropertyInfo(uint index, out IntPtr name, out uint property, out ushort type);
    }
    [ComVisible(true), Guid("23170F69-40C1-278A-0000-000600200000"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    public interface IDetoursSevenZipExtract {
        [PreserveSig] int SetTotal(ulong total);
        [PreserveSig] int SetCompleted(IntPtr completed);
        [PreserveSig] int GetStream(uint index, [MarshalAs(UnmanagedType.Interface)] out IDetoursSevenZipOutput stream, int mode);
        [PreserveSig] int PrepareOperation(int mode);
        [PreserveSig] int SetOperationResult(int result);
    }
    [ComVisible(true), ClassInterface(ClassInterfaceType.None)]
    public sealed class DetoursSevenZipArchiveStream : IDetoursSevenZipInput, IDetoursSevenZipSeekInput {
        private readonly Stream stream;
        private readonly DetoursSevenZipCancellation cancellation;
        public DetoursSevenZipArchiveStream(Stream input, DetoursSevenZipCancellation token) { stream = input; cancellation = token; }
        public int Read(IntPtr data, uint size, IntPtr processed) {
            if (processed != IntPtr.Zero) Marshal.WriteInt32(processed, 0);
            try {
                cancellation.Check(); byte[] bytes = new byte[(int)Math.Min(65536, size)];
                int count = stream.Read(bytes, 0, bytes.Length); Marshal.Copy(bytes, 0, data, count);
                if (processed != IntPtr.Zero) Marshal.WriteInt32(processed, count);
                return 0;
            } catch (Exception error) { return cancellation.Fail(error); }
        }
        public int Seek(long offset, uint origin, IntPtr position) {
            try {
                cancellation.Check(); long result = stream.Seek(offset, (SeekOrigin)origin);
                if (position != IntPtr.Zero) Marshal.WriteInt64(position, result);
                return 0;
            } catch (Exception error) { return cancellation.Fail(error); }
        }
    }
    [ComVisible(true), ClassInterface(ClassInterfaceType.None)]
    public sealed class DetoursSevenZipExtract : IDetoursSevenZipExtract, IDetoursSevenZipOutput, IDisposable {
        private readonly uint index;
        private readonly Stream output;
        private readonly DetoursSevenZipCancellation cancellation;
        private readonly SHA256 hash = SHA256.Create();
        private long received;
        private bool supplied;
        private bool completed;
        public DetoursSevenZipExtract(uint selected, Stream target, DetoursSevenZipCancellation token) {
            index = selected; output = target; cancellation = token;
        }
        public int SetTotal(ulong total) { return SetCompleted(IntPtr.Zero); }
        public int SetCompleted(IntPtr amount) {
            try { cancellation.Check(); return 0; } catch (Exception error) { return cancellation.Fail(error); }
        }
        public int GetStream(uint selected, out IDetoursSevenZipOutput stream, int mode) {
            stream = null;
            if (selected != index || mode != 0) return SetCompleted(IntPtr.Zero);
            if (supplied) return cancellation.Fail(new IOException("7z requested the output twice."));
            supplied = true; stream = this; return SetCompleted(IntPtr.Zero);
        }
        public int PrepareOperation(int mode) { return SetCompleted(IntPtr.Zero); }
        public int SetOperationResult(int result) {
            if (result != 0) return cancellation.Fail(new IOException("7z extraction failed integrity verification: " + result));
            if (supplied) completed = true;
            return SetCompleted(IntPtr.Zero);
        }
        public int Write(IntPtr data, uint size, IntPtr processed) {
            if (processed != IntPtr.Zero) Marshal.WriteInt32(processed, 0);
            try {
                cancellation.Check(); byte[] bytes = new byte[(int)Math.Min(65536, size)];
                Marshal.Copy(data, bytes, 0, bytes.Length); output.Write(bytes, 0, bytes.Length);
                hash.TransformBlock(bytes, 0, bytes.Length, bytes, 0); received = checked(received + bytes.Length);
                if (processed != IntPtr.Zero) Marshal.WriteInt32(processed, bytes.Length);
                return 0;
            } catch (Exception error) { return cancellation.Fail(error); }
        }
        public string Verify(long length) {
            if (!supplied || !completed || received != length) throw new IOException("7z did not verify the complete member.");
            hash.TransformFinalBlock(new byte[0], 0, 0);
            return BitConverter.ToString(hash.Hash).Replace("-", "").ToLowerInvariant();
        }
        public void Dispose() { hash.Dispose(); }
    }
    public sealed class DetoursSevenZipArchive : IDisposable {
        [DllImport("ole32.dll")] private static extern int PropVariantClear(ref DetoursSevenZipVariant value);
        public sealed class Entry {
            public uint Index;
            public string FullName;
            public long Length;
            public string Kind;
            public string LinkTarget;
            internal uint Attributes;
            public DateTimeOffset LastWriteTime;
        }
        private readonly IDetoursSevenZipReader archive;
        private readonly DetoursSevenZipCancellation cancellation;
        private readonly DetoursSevenZipArchiveStream input;
        public Entry[] Entries;
        public DetoursSevenZipArchive(object instance, Stream stream, string cancelPath) {
            archive = (IDetoursSevenZipReader)instance;
            cancellation = new DetoursSevenZipCancellation(cancelPath);
            input = new DetoursSevenZipArchiveStream(stream, cancellation);
            try {
                Check(archive.Open(input, IntPtr.Zero, IntPtr.Zero));
                uint count; Check(archive.GetNumberOfItems(out count));
                List<Entry> entries = new List<Entry>();
                for (uint index = 0; index < count; index++) {
                    cancellation.Check();
                    if (Flag(index, 15) || Flag(index, 21) || Flag(index, 63) || Flag(index, 65))
                        throw new IOException("Encrypted, deleted, anti-item and alternate-stream archive members are unsupported.");

                    string name = Text(index, 3);
                    if (String.IsNullOrEmpty(name)) throw new IOException("7z member has no path.");
                    uint attributes = checked((uint)Number(index, 9));
                    bool posixLink = (attributes & 0x8000) != 0 && ((attributes >> 16) & 0xF000) == 0xA000;
                    bool windowsLink = (attributes & 0x400) != 0;
                    bool directory = Flag(index, 6) && !posixLink && !windowsLink;
                    if (directory) name = name.TrimEnd('/') + "/";
                    entries.Add(new Entry { Index = index, FullName = name, Length = Number(index, 7), Attributes = attributes,
                        Kind = posixLink || windowsLink ? "symbolicLink" : directory ? "directory" : "file",
                        LastWriteTime = new DateTimeOffset(DateTime.FromFileTimeUtc(Number(index, 12))) });
                }
                Entries = entries.ToArray();
                foreach (Entry entry in Entries) {
                    if (entry.Kind != "symbolicLink") continue;
                    if (entry.Length < 1 || entry.Length >= 4096) throw new IOException("Invalid 7z link data length.");
                    using (MemoryStream target = new MemoryStream()) {
                        Extract(entry, target);
                        if ((entry.Attributes & 0x400) != 0) throw new IOException("Windows reparse archive members require native link restoration.");
                        entry.LinkTarget = new UTF8Encoding(false, true).GetString(target.ToArray());
                        if (entry.LinkTarget.IndexOf('\0') >= 0 || entry.LinkTarget.Length == 0)
                            throw new IOException("Invalid 7z symbolic link target.");
                    }
                }
            } catch { archive.Close(); Marshal.FinalReleaseComObject(archive); throw; }
        }
        private void Check(int result) {
            if (cancellation.failure != null) throw new IOException(cancellation.failure);
            if (result != 0) { Marshal.ThrowExceptionForHR(result); throw new IOException("7z archive operation returned " + result); }
        }
        private string Text(uint index, uint property) {
            DetoursSevenZipVariant value; Check(archive.GetProperty(index, property, out value));
            try {
                if (value.type == 0) return null;
                if (value.type != 8) throw new IOException("Unexpected 7z text property.");
                return Marshal.PtrToStringBSTR(value.pointer);
            } finally { Marshal.ThrowExceptionForHR(PropVariantClear(ref value)); }
        }
        private long Number(uint index, uint property) {
            DetoursSevenZipVariant value; Check(archive.GetProperty(index, property, out value));
            try {
                if (value.type == 0) return 0;
                if (value.type != 19 && value.type != 21 && value.type != 64) throw new IOException("Unexpected 7z numeric property.");
                if (value.number < 0) throw new IOException("Invalid 7z numeric property.");
                return value.number;
            } finally { Marshal.ThrowExceptionForHR(PropVariantClear(ref value)); }
        }
        private bool Flag(uint index, uint property) {
            DetoursSevenZipVariant value; Check(archive.GetProperty(index, property, out value));
            try {
                if (value.type == 0) return false;
                if (value.type != 11) throw new IOException("Unexpected 7z flag property.");
                return (short)value.number != 0;
            } finally { Marshal.ThrowExceptionForHR(PropVariantClear(ref value)); }
        }
        public string Extract(Entry entry, Stream output) {
            using (DetoursSevenZipExtract callback = new DetoursSevenZipExtract(entry.Index, output, cancellation)) {
                Check(archive.Extract(new uint[] { entry.Index }, 1, 0, callback));
                return callback.Verify(entry.Length);
            }
        }
        public void Dispose() {
            try { Check(archive.Close()); } finally { Marshal.FinalReleaseComObject(archive); GC.KeepAlive(input); }
        }
    }
    """#
}
