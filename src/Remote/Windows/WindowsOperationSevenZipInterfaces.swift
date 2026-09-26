import Foundation

extension WindowsOperationScripts {
    static let sevenZipInterfaces = #"""
    using System;
    using System.IO;
    using System.Text;
    using System.Collections.Generic;
    using System.ComponentModel;
    using System.Runtime.InteropServices;
    using System.Security.Cryptography;

    [StructLayout(LayoutKind.Explicit, Size = 24)]
    public struct DetoursSevenZipVariant {
        [FieldOffset(0)] public ushort type;
        [FieldOffset(8)] public long number;
        [FieldOffset(8)] public IntPtr pointer;
    }
    [ComVisible(true), Guid("23170F69-40C1-278A-0000-000300010000"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    public interface IDetoursSevenZipInput {
        [PreserveSig] int Read(IntPtr data, uint size, IntPtr processed);
    }
    [ComVisible(true), Guid("23170F69-40C1-278A-0000-000300030000"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    public interface IDetoursSevenZipSeekInput {
        [PreserveSig] int Read(IntPtr data, uint size, IntPtr processed);
        [PreserveSig] int Seek(long offset, uint origin, IntPtr position);
    }
    [ComVisible(true), Guid("23170F69-40C1-278A-0000-000300020000"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    public interface IDetoursSevenZipOutput {
        [PreserveSig] int Write(IntPtr data, uint size, IntPtr processed);
    }
    [ComVisible(true), Guid("23170F69-40C1-278A-0000-000300040000"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    public interface IDetoursSevenZipSeekOutput {
        [PreserveSig] int Write(IntPtr data, uint size, IntPtr processed);
        [PreserveSig] int Seek(long offset, uint origin, IntPtr position);
        [PreserveSig] int SetSize(ulong size);
    }
    [ComVisible(true), Guid("23170F69-40C1-278A-0000-000600800000"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    public interface IDetoursSevenZipUpdate {
        [PreserveSig] int SetTotal(ulong total);
        [PreserveSig] int SetCompleted(IntPtr completed);
        [PreserveSig] int GetUpdateItemInfo(uint index, out int data, out int properties, out uint archiveIndex);
        [PreserveSig] int GetProperty(uint index, uint property, out DetoursSevenZipVariant value);
        [PreserveSig] int GetStream(uint index, [MarshalAs(UnmanagedType.Interface)] out IDetoursSevenZipInput stream);
        [PreserveSig] int SetOperationResult(int result);
    }
    [ComImport, Guid("23170F69-40C1-278A-0000-000600A00000"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    public interface IDetoursSevenZipWriter {
        [PreserveSig] int UpdateItems([MarshalAs(UnmanagedType.Interface)] IDetoursSevenZipOutput output, uint count,
            [MarshalAs(UnmanagedType.Interface)] IDetoursSevenZipUpdate callback);
        [PreserveSig] int GetFileTimeType(out uint type);
    }
    public sealed class DetoursSevenZipSource {
        public string name;
        public string path;
        public bool directory;
        public long length;
        public string sha256;
        public long timestamp;
        public uint attributes;
    }
    public sealed class DetoursSevenZipCancellation {
        private readonly string path;
        public string failure;
        public DetoursSevenZipCancellation(string cancellationPath) { path = cancellationPath; }
        public void Check() {
            try { File.GetAttributes(path); }
            catch (FileNotFoundException) { return; }
            throw new OperationCanceledException("Archive operation cancelled.");
        }
        public int Fail(Exception error) { failure = error.Message; return Marshal.GetHRForException(error); }
    }
    """#
}
