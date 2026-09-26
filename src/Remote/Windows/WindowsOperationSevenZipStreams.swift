import Foundation

extension WindowsOperationScripts {
    static let sevenZipStreams = #"""
    [ComVisible(true), ClassInterface(ClassInterfaceType.None)]
    public sealed class DetoursSevenZipSourceStream : IDetoursSevenZipInput, IDisposable {
        private FileStream stream;
        private readonly SHA256 hash = SHA256.Create();
        private readonly DetoursSevenZipSource source;
        private readonly DetoursSevenZipCancellation cancellation;
        private long received;
        public bool verified;
        public DetoursSevenZipSourceStream(DetoursSevenZipSource item, DetoursSevenZipCancellation token) {
            source = item; cancellation = token;
            stream = new FileStream(item.path, FileMode.Open, FileAccess.Read, FileShare.Read);
            if (stream.Length != item.length) { stream.Dispose(); throw new IOException("Archive source size changed."); }
            if (item.length == 0) Verify();
        }
        private void Verify() {
            hash.TransformFinalBlock(new byte[0], 0, 0);
            string actual = BitConverter.ToString(hash.Hash).Replace("-", "").ToLowerInvariant();
            stream.Dispose();
            if (received != source.length || actual != source.sha256) throw new IOException("Archive source content changed.");
            verified = true;
        }
        public int Read(IntPtr data, uint size, IntPtr processed) {
            if (processed != IntPtr.Zero) Marshal.WriteInt32(processed, 0);
            try {
                cancellation.Check();
                if (verified || size == 0) return 0;
                byte[] bytes = new byte[(int)Math.Min(65536, Math.Min((long)size, source.length - received))];
                int count = stream.Read(bytes, 0, bytes.Length);
                if (count == 0) throw new EndOfStreamException("Archive source ended before its accepted length.");
                hash.TransformBlock(bytes, 0, count, bytes, 0); received += count;
                Marshal.Copy(bytes, 0, data, count);
                if (received == source.length) Verify();
                if (processed != IntPtr.Zero) Marshal.WriteInt32(processed, count);
                return 0;
            } catch (Exception error) { return cancellation.Fail(error); }
        }
        public void Dispose() { stream.Dispose(); hash.Dispose(); }
    }
    [ComVisible(true), ClassInterface(ClassInterfaceType.None)]
    public sealed class DetoursSevenZipOutputStream : IDetoursSevenZipOutput, IDetoursSevenZipSeekOutput {
        private readonly Stream stream;
        private readonly DetoursSevenZipCancellation cancellation;
        public DetoursSevenZipOutputStream(Stream destination, DetoursSevenZipCancellation token) { stream = destination; cancellation = token; }
        public int Write(IntPtr data, uint size, IntPtr processed) {
            if (processed != IntPtr.Zero) Marshal.WriteInt32(processed, 0);
            try {
                cancellation.Check();
                byte[] bytes = new byte[(int)Math.Min(65536, size)];
                Marshal.Copy(data, bytes, 0, bytes.Length); stream.Write(bytes, 0, bytes.Length);
                if (processed != IntPtr.Zero) Marshal.WriteInt32(processed, bytes.Length);
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
        public int SetSize(ulong size) {
            try { cancellation.Check(); stream.SetLength(checked((long)size)); return 0; }
            catch (Exception error) { return cancellation.Fail(error); }
        }
    }
    [ComVisible(true), ClassInterface(ClassInterfaceType.None)]
    public sealed class DetoursSevenZipUpdate : IDetoursSevenZipUpdate, IDisposable {
        private readonly DetoursSevenZipSource[] sources;
        private readonly DetoursSevenZipCancellation cancellation;
        private readonly Dictionary<uint, DetoursSevenZipSourceStream> streams = new Dictionary<uint, DetoursSevenZipSourceStream>();
        public DetoursSevenZipUpdate(DetoursSevenZipSource[] items, DetoursSevenZipCancellation token) { sources = items; cancellation = token; }
        public int SetTotal(ulong total) { return SetCompleted(IntPtr.Zero); }
        public int SetCompleted(IntPtr completed) {
            try { cancellation.Check(); return 0; } catch (Exception error) { return cancellation.Fail(error); }
        }
        public int GetUpdateItemInfo(uint index, out int data, out int properties, out uint archiveIndex) {
            data = 1; properties = 1; archiveIndex = UInt32.MaxValue; return SetCompleted(IntPtr.Zero);
        }
        public int GetProperty(uint index, uint property, out DetoursSevenZipVariant value) {
            value = new DetoursSevenZipVariant();
            try {
                cancellation.Check(); DetoursSevenZipSource source = sources[index];
                switch (property) {
                    case 3: value.type = 8; value.pointer = Marshal.StringToBSTR(source.name); break;
                    case 6: value.type = 11; value.number = source.directory ? -1 : 0; break;
                    case 7: value.type = 21; value.number = source.directory ? 0 : source.length; break;
                    case 9: value.type = 19; value.number = source.attributes; break;
                    case 12: value.type = 64; value.number = source.timestamp; break;
                }
                return 0;
            } catch (Exception error) { return cancellation.Fail(error); }
        }
        public int GetStream(uint index, out IDetoursSevenZipInput stream) {
            stream = null;
            try {
                cancellation.Check();
                if (!sources[index].directory) {
                    DetoursSevenZipSourceStream input = new DetoursSevenZipSourceStream(sources[index], cancellation);
                    streams.Add(index, input); stream = input;
                }
                return 0;
            } catch (Exception error) { return cancellation.Fail(error); }
        }
        public int SetOperationResult(int result) {
            if (result != 0) return cancellation.Fail(new IOException("7z source operation failed: " + result));
            return SetCompleted(IntPtr.Zero);
        }
        public void Verify() {
            for (uint index = 0; index < sources.Length; index++) {
                cancellation.Check();
                if (sources[index].directory) continue;
                DetoursSevenZipSourceStream stream;
                if (!streams.TryGetValue(index, out stream)) {
                    if (sources[index].length != 0) throw new IOException("7z did not consume a selected file.");
                    stream = new DetoursSevenZipSourceStream(sources[index], cancellation);
                    streams.Add(index, stream);
                }
                if (!stream.verified) throw new IOException("7z input was not fully verified.");
            }
        }
        public void Dispose() { foreach (DetoursSevenZipSourceStream stream in streams.Values) stream.Dispose(); }
    }
    """#
}
