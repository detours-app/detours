import Foundation

extension WindowsOperationScripts {
    static let sevenZipReader = #"""
    [ComImport, Guid("23170F69-40C1-278A-0000-000600600000"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    public interface IDetoursSevenZipReader {
        [PreserveSig] int Open([MarshalAs(UnmanagedType.Interface)] IDetoursSevenZipSeekInput stream, IntPtr limit,
            [MarshalAs(UnmanagedType.Interface)] IDetoursRarOpen callback);
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
    public sealed class DetoursSevenZipExtract : IDetoursSevenZipExtract, IDetoursSevenZipOutput, IDetoursRarPassword, IDisposable {
        private readonly uint index;
        private readonly Stream output;
        private readonly DetoursSevenZipCancellation cancellation;
        private readonly SHA256 hash = SHA256.Create();
        private long received;
        private bool supplied;
        private bool completed;
        private readonly DetoursRarOpen rar;
        private readonly long limit;
        public DetoursSevenZipExtract(uint selected, Stream target, DetoursSevenZipCancellation token, DetoursRarOpen password, long length) {
            index = selected; output = target; cancellation = token; rar = password; limit = length;
        }
        public int CryptoGetTextPassword(out string password) {
            password = null;
            return rar == null ? cancellation.Fail(new IOException("Encrypted 7z archives are unsupported.")) : rar.CryptoGetTextPassword(out password);
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
            if (result != 0) {
                string message = "7z extraction failed integrity verification: " + result;
                if (rar != null) message = result == 9 ? "RAR_PASSWORD_INCORRECT" : result == 1 ? "Unsupported RAR compression method." :
                    rar.PasswordRequested ? "RAR_PASSWORD_OR_DAMAGE" : "Damaged RAR archive.";
                return cancellation.Fail(new IOException(message));
            }
            if (supplied) completed = true;
            return SetCompleted(IntPtr.Zero);
        }
        public int Write(IntPtr data, uint size, IntPtr processed) {
            if (processed != IntPtr.Zero) Marshal.WriteInt32(processed, 0);
            try {
                cancellation.Check(); byte[] bytes = new byte[(int)Math.Min(65536, size)];
                if (rar != null && (received > limit || bytes.Length > limit - received)) throw new IOException("RAR member exceeds its declared size.");
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
            public bool Encrypted, SplitBefore, SplitAfter;
            internal uint Attributes;
            public DateTimeOffset LastWriteTime;
        }
        private readonly IDetoursSevenZipReader archive;
        private readonly DetoursSevenZipCancellation cancellation;
        private readonly IDetoursSevenZipSeekInput input;
        private readonly DetoursRarOpen rar;
        public bool IsVolume;
        public long VolumeIndex = -1;
        public Entry[] Entries;
        public DetoursSevenZipArchive(object instance, Stream stream, string cancelPath)
            : this(instance, stream, new DetoursSevenZipCancellation(cancelPath)) { }
        private DetoursSevenZipArchive(object instance, Stream stream, DetoursSevenZipCancellation token)
            : this(instance, new DetoursSevenZipArchiveStream(stream, token), token, null, 7, false) { }
        public DetoursSevenZipArchive(object instance, IDetoursSevenZipSeekInput stream, DetoursSevenZipCancellation token,
            DetoursRarOpen callback, int format, bool inspection) {
            archive = (IDetoursSevenZipReader)instance;
            cancellation = token; input = stream; rar = callback;
            try {
                Check(archive.Open(input, IntPtr.Zero, rar));
                if (rar != null) { IsVolume = ArchiveNumber(35, 0) != 0; VolumeIndex = ArchiveNumber(80, -1); }
                uint count; Check(archive.GetNumberOfItems(out count));
                List<Entry> entries = new List<Entry>();
                for (uint index = 0; index < count; index++) {
                    cancellation.Check();
                    if ((rar == null && Flag(index, 15)) || Flag(index, 21) || Flag(index, 63) || Flag(index, 65))
                        throw new IOException("Encrypted, deleted, anti-item and alternate-stream archive members are unsupported.");

                    string name = Text(index, 3);
                    if (String.IsNullOrEmpty(name)) throw new IOException("7z member has no path.");
                    uint attributes = checked((uint)Number(index, 9));
                    bool posixLink = (attributes & 0x8000) != 0 && ((attributes >> 16) & 0xF000) == 0xA000;
                    bool windowsLink = (attributes & 0x400) != 0;
                    bool directory = Flag(index, 6) && !posixLink && !windowsLink;
                    string symbolic = rar == null ? null : Text(index, 54);
                    string hard = rar == null ? null : Text(index, 90);
                    uint mode = rar == null ? 0 : checked((uint)Number(index, 53)) & 0xF000;
                    if (rar != null && mode == 0 && (attributes & 0x8000) != 0) mode = (attributes >> 16) & 0xF000;
                    if (rar != null && (windowsLink || mode != 0 && mode != 0x8000 && mode != 0x4000 && mode != 0xA000 ||
                        symbolic != null && hard != null)) throw new IOException("Unsupported RAR link or special file.");
                    if (symbolic != null || hard != null) directory = false;
                    if (directory) name = name.TrimEnd('/') + "/";
                    entries.Add(new Entry { Index = index, FullName = name, Length = Number(index, 7, rar != null && !directory), Attributes = attributes,
                        Kind = hard != null ? "hardLink" : symbolic != null || posixLink || windowsLink ? "symbolicLink" : directory ? "directory" : "file",
                        LinkTarget = symbolic ?? hard, Encrypted = Flag(index, 15), SplitBefore = Flag(index, 16), SplitAfter = Flag(index, 17),
                        LastWriteTime = new DateTimeOffset(DateTime.FromFileTimeUtc(Number(index, 12))) });
                }
                Entries = entries.ToArray();
                if (rar != null) {
                    long flags = ArchiveNumber(71, 0);
                    if ((flags & (128L | 256L)) != 0) throw new IOException("Unsupported RAR compression method or feature.");
                    bool continuation = inspection && format == 0xCC && VolumeIndex > 0 && Entries.Length > 0 && Entries[0].SplitBefore;
                    if ((flags & ~(continuation ? 2L : 0L)) != 0 || !inspection && ArchiveText(55) != null)
                        throw new IOException(rar.PasswordRequested ? "RAR_PASSWORD_OR_DAMAGE" : "Damaged or incomplete RAR archive.");
                    if (inspection) return;
                    foreach (Entry entry in Entries) if (entry.Encrypted) { string secret; Check(rar.CryptoGetTextPassword(out secret)); }
                }
                foreach (Entry entry in Entries) {
                    if (entry.Kind != "symbolicLink" || entry.LinkTarget != null) continue;
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
            if (result != 0) {
                if (rar != null) throw new IOException(rar.PasswordRequested ? "RAR_PASSWORD_OR_DAMAGE" : "Damaged or unsupported RAR archive.");
                Marshal.ThrowExceptionForHR(result); throw new IOException("7z archive operation returned " + result);
            }
        }
        private long ArchiveNumber(uint property, long absent) {
            DetoursSevenZipVariant value; Check(archive.GetArchiveProperty(property, out value));
            try {
                if (value.type == 0) return absent;
                if (value.type == 11) return (short)value.number == 0 ? 0 : 1;
                if (value.type != 19 && value.type != 21 || value.number < 0) throw new IOException("Invalid RAR archive property.");
                return value.number;
            } finally { Marshal.ThrowExceptionForHR(PropVariantClear(ref value)); }
        }
        private string ArchiveText(uint property) {
            DetoursSevenZipVariant value; Check(archive.GetArchiveProperty(property, out value));
            try {
                if (value.type == 0) return null;
                if (value.type != 8) throw new IOException("Invalid RAR archive property.");
                string result = Marshal.PtrToStringBSTR(value.pointer);
                return String.IsNullOrEmpty(result) ? null : result;
            } finally { Marshal.ThrowExceptionForHR(PropVariantClear(ref value)); }
        }
        private string Text(uint index, uint property) {
            DetoursSevenZipVariant value; Check(archive.GetProperty(index, property, out value));
            try {
                if (value.type == 0) return null;
                if (value.type != 8) throw new IOException("Unexpected 7z text property.");
                return Marshal.PtrToStringBSTR(value.pointer);
            } finally { Marshal.ThrowExceptionForHR(PropVariantClear(ref value)); }
        }
        private long Number(uint index, uint property, bool required = false) {
            DetoursSevenZipVariant value; Check(archive.GetProperty(index, property, out value));
            try {
                if (value.type == 0 && !required) return 0;
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
            using (DetoursSevenZipExtract callback = new DetoursSevenZipExtract(entry.Index, output, cancellation, rar, entry.Length)) {
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
