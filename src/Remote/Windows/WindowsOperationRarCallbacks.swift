import Foundation

extension WindowsOperationScripts {
    static let rarCallbacks = #"""
    [ComVisible(true), Guid("23170F69-40C1-278A-0000-000600100000"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    public interface IDetoursRarOpen {
        [PreserveSig] int SetTotal(IntPtr files, IntPtr bytes);
        [PreserveSig] int SetCompleted(IntPtr files, IntPtr bytes);
    }
    [ComVisible(true), Guid("23170F69-40C1-278A-0000-000600300000"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    public interface IDetoursRarVolumes {
        [PreserveSig] int GetProperty(uint property, out DetoursSevenZipVariant value);
        [PreserveSig] int GetStream([MarshalAs(UnmanagedType.LPWStr)] string name,
            [MarshalAs(UnmanagedType.Interface)] out IDetoursSevenZipSeekInput stream);
    }
    [ComVisible(true), Guid("23170F69-40C1-278A-0000-000500100000"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    public interface IDetoursRarPassword {
        [PreserveSig] int CryptoGetTextPassword([MarshalAs(UnmanagedType.BStr)] out string password);
    }
    [ComVisible(true), ClassInterface(ClassInterfaceType.None)]
    public sealed class DetoursRarOpen : IDetoursRarOpen, IDetoursRarVolumes, IDetoursRarPassword {
        private readonly DetoursRarVolumeSet volumes;
        private readonly string name;
        private readonly string password;
        private readonly DetoursSevenZipCancellation cancellation;
        public bool PasswordRequested;
        public DetoursRarOpen(DetoursRarVolumeSet set, string inputName, string secret, DetoursSevenZipCancellation token) {
            volumes = set; name = inputName; password = secret; cancellation = token;
        }
        public int SetTotal(IntPtr files, IntPtr bytes) { return SetCompleted(files, bytes); }
        public int SetCompleted(IntPtr files, IntPtr bytes) {
            try { cancellation.Check(); return 0; } catch (Exception error) { return cancellation.Fail(error); }
        }
        public int CryptoGetTextPassword(out string value) {
            value = null; PasswordRequested = true;
            try {
                cancellation.Check();
                if (String.IsNullOrEmpty(password)) throw new IOException("RAR_PASSWORD_REQUIRED");
                value = password; return 0;
            } catch (Exception error) { return cancellation.Fail(error); }
        }
        public int GetProperty(uint property, out DetoursSevenZipVariant value) {
            value = new DetoursSevenZipVariant();
            try {
                cancellation.Check();
                if (property == 4) { value.type = 8; value.pointer = Marshal.StringToBSTR(name); }
                return 0;
            } catch (Exception error) { return cancellation.Fail(error); }
        }
        public int GetStream(string requested, out IDetoursSevenZipSeekInput stream) {
            stream = null;
            try {
                cancellation.Check();
                if (volumes == null) return 1;
                stream = volumes.Open(requested); return 0;
            } catch (Exception error) { return cancellation.Fail(error); }
        }
    }
    [ComVisible(true), ClassInterface(ClassInterfaceType.None)]
    public sealed class DetoursRarInput : IDetoursSevenZipSeekInput {
        private readonly DetoursRarVolumeSet owner;
        private readonly DetoursRarVolumeSet.Part part;
        private long position;
        public DetoursRarInput(DetoursRarVolumeSet set, DetoursRarVolumeSet.Part source) { owner = set; part = source; }
        public int Read(IntPtr data, uint size, IntPtr processed) {
            if (processed != IntPtr.Zero) Marshal.WriteInt32(processed, 0);
            try {
                owner.Cancellation.Check();
                byte[] bytes = new byte[(int)Math.Min(65536, size)];
                using (Stream input = owner.OpenFile(part)) {
                    input.Position = position;
                    int count = input.Read(bytes, 0, bytes.Length); Marshal.Copy(bytes, 0, data, count);
                    position = checked(position + count);
                    if (processed != IntPtr.Zero) Marshal.WriteInt32(processed, count);
                }
                return 0;
            } catch (Exception error) { return owner.Cancellation.Fail(error); }
        }
        public int Seek(long offset, uint origin, IntPtr result) {
            try {
                owner.Cancellation.Check();
                if (origin > 2) throw new IOException("Invalid RAR input seek.");
                long next = checked((origin == 0 ? 0 : origin == 1 ? position : part.Length) + offset);
                if (next < 0) throw new IOException("Invalid RAR input seek.");
                position = next;
                if (result != IntPtr.Zero) Marshal.WriteInt64(result, position);
                return 0;
            } catch (Exception error) { return owner.Cancellation.Fail(error); }
        }
    }
    """#
}
