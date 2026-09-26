import Foundation

extension WindowsOperationScripts {
    // Native rename contract: learn.microsoft.com/windows-hardware/drivers/ddi/ntifs/ns-ntifs-_file_rename_information
    static let filesystemHelpers = #"""
    if (-not ('DetoursOperationFiles' -as [type])) {
    Add-Type -TypeDefinition @'
    using System;
    using System.IO;
    using System.Text;
    using System.ComponentModel;
    using System.Runtime.InteropServices;
    using System.Security.AccessControl;
    using System.Security.Principal;
    using System.Security.Cryptography;
    using Microsoft.Win32.SafeHandles;

    public static class DetoursOperationFiles {
        public sealed class Identity { public string volume; public string @object; }
        public sealed class Observation {
            public Identity identity; public string kind; public string version;
            public ulong byteCount; public string sha256; public string linkTarget; public string contentVersion;
        }
        public sealed class TreeEntry { public string relativePath; public Observation observation; }
        public sealed class ContentProof { public ulong byteCount; public string sha256; }
        public sealed class TreeManifest { public TreeEntry[] entries; public ContentProof proof; }
        [StructLayout(LayoutKind.Sequential)]
        public struct RenameInfo { public uint flags; public IntPtr root; public uint length; public ushort name; }
        [StructLayout(LayoutKind.Sequential)]
        private struct IoStatus { public IntPtr status; public UIntPtr information; }
        [StructLayout(LayoutKind.Sequential)]
        private struct SecurityAttributes { public int length; public IntPtr descriptor; public int inherit; }
        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern SafeFileHandle CreateFileW(string path, uint access, uint share, IntPtr security,
            uint disposition, uint flags, IntPtr template);
        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool GetFileInformationByHandleEx(SafeFileHandle file, int kind, [Out] byte[] data, uint size);
        [DllImport("ntdll.dll")]
        private static extern int NtSetInformationFile(SafeFileHandle file, out IoStatus result, IntPtr data, uint size, int kind);
        [DllImport("ntdll.dll")]
        private static extern uint RtlNtStatusToDosError(int status);
        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool DeviceIoControl(SafeFileHandle file, uint code, IntPtr input, uint inputSize,
            [Out] byte[] output, uint outputSize, out uint returned, IntPtr overlapped);
        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern bool CreateDirectoryW(string path, ref SecurityAttributes security);

        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        [return: MarshalAs(UnmanagedType.U1)]
        private static extern bool CreateSymbolicLinkW(string path, string target, uint flags);
        public static Observation CreateArchiveSymbolicLink(string path, string target, bool directory) {
            using (SafeFileHandle parent = Open(Path.GetDirectoryName(path), 0x80, 3)) {
                if (Observe(parent).kind != "directory") throw new IOException("Archive link parent is not a directory.");
                if (!CreateSymbolicLinkW(path, target, directory ? 3u : 2u)) throw new Win32Exception(Marshal.GetLastWin32Error());
                return Observe(path);
            }
        }
        public static Observation SetArchiveJunction(string path, string volume, string id, string target) {
            string full = Path.GetFullPath(target);
            if (full.StartsWith("\\", StringComparison.Ordinal)) throw new IOException("Archive junction requires a local target.");
            byte[] substitute = Encoding.Unicode.GetBytes(@"\??\" + full);
            byte[] display = Encoding.Unicode.GetBytes(full);
            int length = checked(20 + substitute.Length + display.Length);
            if (length > 16384) throw new IOException("Archive junction target is too long.");
            byte[] bytes = new byte[length];
            Buffer.BlockCopy(BitConverter.GetBytes(0xA0000003u), 0, bytes, 0, 4);
            Buffer.BlockCopy(BitConverter.GetBytes((ushort)(length - 8)), 0, bytes, 4, 2);
            Buffer.BlockCopy(BitConverter.GetBytes((ushort)substitute.Length), 0, bytes, 10, 2);
            Buffer.BlockCopy(BitConverter.GetBytes((ushort)(substitute.Length + 2)), 0, bytes, 12, 2);
            Buffer.BlockCopy(BitConverter.GetBytes((ushort)display.Length), 0, bytes, 14, 2);
            Buffer.BlockCopy(substitute, 0, bytes, 16, substitute.Length);
            Buffer.BlockCopy(display, 0, bytes, 18 + substitute.Length, display.Length);
            using (SafeFileHandle handle = Open(path, 0x40000080, 3)) {
                Observation observed = Observe(handle);
                if (observed.identity.volume != volume || observed.identity.@object != id || observed.kind != "directory")
                    throw new IOException("Archive junction placeholder changed.");
                IntPtr data = Marshal.AllocHGlobal(length);
                try {
                    Marshal.Copy(bytes, 0, data, length); uint returned;
                    if (!DeviceIoControl(handle, 0x000900A4, data, (uint)length, null, 0, out returned, IntPtr.Zero))
                        throw new Win32Exception(Marshal.GetLastWin32Error());
                    return Observe(handle);
                } finally { Marshal.FreeHGlobal(data); }
            }
        }
        private static SafeFileHandle Open(string path, uint access, uint share) {
            SafeFileHandle handle = CreateFileW(path, access, share, IntPtr.Zero, 3, 0x02200000, IntPtr.Zero);
            if (handle.IsInvalid) {
                int error = Marshal.GetLastWin32Error(); handle.Dispose(); throw new Win32Exception(error);
            }
            return handle;
        }
        private static byte[] Info(SafeFileHandle handle, int kind, int size) {
            byte[] data = new byte[size];
            if (!GetFileInformationByHandleEx(handle, kind, data, (uint)size)) throw new Win32Exception(Marshal.GetLastWin32Error());
            return data;
        }
        private static byte[] Slice(byte[] bytes, int offset, int count) {
            byte[] value = new byte[count]; Buffer.BlockCopy(bytes, offset, value, 0, count); return value;
        }
        private static string Version(byte[] basic, byte[] standard, bool changed) {
            using (MemoryStream bytes = new MemoryStream()) {
                // NTFS can tunnel a displaced name's creation time onto the incoming file.
                // CreationTime: https://learn.microsoft.com/dotnet/api/system.io.filesysteminfo.creationtime
                if (changed) bytes.Write(basic, 0, 8);
                bytes.Write(basic, 16, changed ? 16 : 8);
                bytes.Write(basic, 32, 4);
                bytes.Write(standard, 8, 8);
                return Convert.ToBase64String(bytes.ToArray());
            }
        }
        private static string LinkTarget(SafeFileHandle handle) {
            byte[] data = new byte[16384]; uint count;
            if (!DeviceIoControl(handle, 0x000900A8, IntPtr.Zero, 0, data, (uint)data.Length, out count, IntPtr.Zero))
                throw new Win32Exception(Marshal.GetLastWin32Error());
            if (count < 16) throw new IOException("Incomplete reparse data.");
            uint tag = BitConverter.ToUInt32(data, 0);
            int start = tag == 0xA000000C ? 20 : tag == 0xA0000003 ? 16 : 0;
            if (start == 0) throw new NotSupportedException("Unsupported reparse point.");
            int offset = BitConverter.ToUInt16(data, 12), length = BitConverter.ToUInt16(data, 14);
            if (length == 0) { offset = BitConverter.ToUInt16(data, 8); length = BitConverter.ToUInt16(data, 10); }
            if ((length & 1) != 0 || (offset & 1) != 0 || start + offset + length > count)
                throw new IOException("Invalid reparse target.");
            string target = Encoding.Unicode.GetString(data, start + offset, length);
            return Convert.ToBase64String(Encoding.UTF8.GetBytes(target));
        }
        private static Observation Observe(SafeFileHandle handle) {
            byte[] id = Info(handle, 18, 24), basic = Info(handle, 0, 40), standard = Info(handle, 1, 24);
            uint attributes = BitConverter.ToUInt32(basic, 32);
            bool link = (attributes & 0x400) != 0;
            return new Observation {
                identity = new Identity { volume = Convert.ToBase64String(Slice(id, 0, 8)),
                    @object = Convert.ToBase64String(Slice(id, 8, 16)) },
                kind = link ? "symbolicLink" : (attributes & 0x10) != 0 ? "directory" : "file",
                byteCount = (ulong)Math.Max(0, BitConverter.ToInt64(standard, 8)),
                version = Version(basic, standard, true), contentVersion = Version(basic, standard, false),
                linkTarget = link ? LinkTarget(handle) : null
            };
        }
        public static Observation Observe(string path) {
            using (SafeFileHandle handle = Open(path, 0x80, 7)) { return Observe(handle); }
        }
        public static Observation ObserveStream(FileStream stream) { return Observe(stream.SafeFileHandle); }
        public static SafeFileHandle PinDirectory(string path, string volume, string id) {
            SafeFileHandle handle = Open(path, 0x81, 3);
            try {
                Observation current = Observe(handle);
                if (current.kind != "directory" || current.identity.volume != volume || current.identity.@object != id)
                    throw new IOException("Operation directory changed.");
                return handle;
            } catch { handle.Dispose(); throw; }
        }
        public static void CopyDirectoryMetadata(string source, string target, string volume, string id) {
            using (SafeFileHandle origin = Open(source, 0x80, 7))
            using (SafeFileHandle destination = Open(target, 0x180, 3)) {
                Observation current = Observe(destination);
                if (current.kind != "directory" || current.identity.volume != volume || current.identity.@object != id)
                    throw new IOException("Operation metadata destination changed.");
                byte[] original = Info(origin, 0, 40), desired = new byte[40];
                Buffer.BlockCopy(original, 16, desired, 16, 8);
                Buffer.BlockCopy(original, 32, desired, 32, 4);
                IntPtr buffer = Marshal.AllocHGlobal(40);
                try {
                    Marshal.Copy(desired, 0, buffer, 40);
                    IoStatus result;
                    int status = NtSetInformationFile(destination, out result, buffer, 40, 4);
                    if (status != 0) throw new Win32Exception((int)RtlNtStatusToDosError(status));
                } finally { Marshal.FreeHGlobal(buffer); }
            }
        }
        public static void SetDirectoryTime(string path, string volume, string id, long timestamp) {
            SetArchiveTime(path, volume, id, "directory", timestamp);
        }
        public static void SetArchiveTime(string path, string volume, string id, string kind, long timestamp) {
            using (SafeFileHandle handle = Open(path, 0x180, 3)) {
                Observation observed = Observe(handle);
                if (observed.kind != kind || observed.identity.volume != volume || observed.identity.@object != id)
                    throw new IOException("Archive metadata identity changed.");
                byte[] desired = new byte[40]; Buffer.BlockCopy(BitConverter.GetBytes(timestamp), 0, desired, 16, 8);
                IntPtr buffer = Marshal.AllocHGlobal(40);
                try {
                    Marshal.Copy(desired, 0, buffer, 40); IoStatus result;
                    int status = NtSetInformationFile(handle, out result, buffer, 40, 4);
                    if (status != 0) throw new Win32Exception((int)RtlNtStatusToDosError(status));
                } finally { Marshal.FreeHGlobal(buffer); }
            }
        }
        public static FileStream OpenObservedFile(string path, string volume, string id, string version) {
            SafeFileHandle handle = Open(path, 0x80000000, 1);
            try {
                Observation current = Observe(handle);
                Require(current, volume, id, version);
                if (current.kind != "file") throw new IOException("Operation source is not a regular file.");
                return new FileStream(handle, FileAccess.Read, 65536, false);
            } catch { handle.Dispose(); throw; }
        }
        public static FileStream CreateNewFile(string path) {
            SafeFileHandle handle = CreateFileW(path, 0xC0000000, 7, IntPtr.Zero, 1, 0x00200000, IntPtr.Zero);
            if (handle.IsInvalid) {
                int error = Marshal.GetLastWin32Error(); handle.Dispose(); throw new Win32Exception(error);
            }
            try { return new FileStream(handle, FileAccess.ReadWrite, 65536, false); }
            catch { handle.Dispose(); throw; }
        }
        public static void RemoveOwned(string path, string volume, string id) {
            using (SafeFileHandle handle = Open(path, 0x10180, 0)) {
                Observation observed = Observe(handle);
                if (observed.identity.volume != volume || observed.identity.@object != id)
                    throw new IOException("Operation cleanup object changed.");
                DeleteHandle(handle);
            }
        }
        public static void DeleteConfirmed(string path, string volume, string id, string kind, string version) {
            using (SafeFileHandle handle = Open(path, 0x10180, 0)) {
                Observation observed = Observe(handle);
                if (observed.identity.volume != volume || observed.identity.@object != id || observed.kind != kind ||
                    (kind != "directory" && observed.version != version)) throw new IOException("Confirmed deletion object changed.");
                DeleteHandle(handle);
            }
        }
        private static void DeleteHandle(SafeFileHandle handle) {
            byte[] basic = Info(handle, 0, 40);
            uint attributes = BitConverter.ToUInt32(basic, 32);
            IntPtr buffer = Marshal.AllocHGlobal(40);
            try {
                IoStatus result;
                if ((attributes & 1) != 0) {
                    Marshal.Copy(new byte[40], 0, buffer, 40);
                    attributes &= ~1u;
                    Marshal.WriteInt32(buffer, 32, (int)(attributes == 0 ? 0x80 : attributes));
                    int update = NtSetInformationFile(handle, out result, buffer, 40, 4);
                    if (update != 0) throw new Win32Exception((int)RtlNtStatusToDosError(update));
                }
                Marshal.WriteByte(buffer, 1);
                int status = NtSetInformationFile(handle, out result, buffer, 1, 13);
                if (status != 0) throw new Win32Exception((int)RtlNtStatusToDosError(status));
            } finally { Marshal.FreeHGlobal(buffer); }
        }
        public static Observation CreateDirectoryExclusive(string path) {
            SecurityAttributes attributes = new SecurityAttributes {
                length = Marshal.SizeOf(typeof(SecurityAttributes)), descriptor = IntPtr.Zero, inherit = 0 };
            if (!CreateDirectoryW(path, ref attributes)) throw new Win32Exception(Marshal.GetLastWin32Error());
            return Observe(path);
        }
        public static Observation Prove(string path) {
            using (SafeFileHandle handle = Open(path, 0x80000000, 7)) {
                Observation before = Observe(handle);
                if (before.kind != "file") throw new NotSupportedException("Content proof requires a regular file.");
                using (FileStream stream = new FileStream(handle, FileAccess.Read))
                using (SHA256 hash = SHA256.Create()) {
                    string digest = BitConverter.ToString(hash.ComputeHash(stream)).Replace("-", "").ToLowerInvariant();
                    Observation after = Observe(handle);
                    Require(after, before.identity.volume, before.identity.@object, before.version);
                    after.sha256 = digest;
                    return after;
                }
            }
        }
        public static TreeManifest Manifest(string path) {
            var entries = new System.Collections.Generic.List<TreeEntry>();
            CollectTree(path, "", entries);
            return MakeManifest(entries);
        }
        private static TreeManifest MakeManifest(System.Collections.Generic.List<TreeEntry> entries) {
            entries.Sort(delegate(TreeEntry left, TreeEntry right) {
                byte[] a = Convert.FromBase64String(left.relativePath), b = Convert.FromBase64String(right.relativePath);
                for (int index = 0; index < Math.Min(a.Length, b.Length); index++) {
                    int order = a[index].CompareTo(b[index]); if (order != 0) return order;
                }
                return a.Length.CompareTo(b.Length);
            });
            StringBuilder json = new StringBuilder("[");
            ulong total = 0;
            foreach (TreeEntry entry in entries) {
                Observation observed = entry.observation;
                ulong size = observed.kind == "file" ? observed.byteCount : 0;
                total = checked(total + size);
                if (json.Length > 1) json.Append(',');
                json.Append("{\"byteCount\":").Append(size.ToString(System.Globalization.CultureInfo.InvariantCulture));
                json.Append(",\"kind\":\"").Append(observed.kind).Append('"');
                if (observed.linkTarget != null) json.Append(",\"linkTarget\":\"").Append(observed.linkTarget).Append('"');
                json.Append(",\"relativePath\":\"").Append(entry.relativePath).Append('"');
                if (observed.sha256 != null) json.Append(",\"sha256\":\"").Append(observed.sha256).Append('"');
                json.Append('}');
            }
            json.Append(']');
            using (SHA256 hash = SHA256.Create()) {
                string digest = BitConverter.ToString(hash.ComputeHash(Encoding.UTF8.GetBytes(json.ToString()))).Replace("-", "").ToLowerInvariant();
                return new TreeManifest { entries = entries.ToArray(), proof = new ContentProof { byteCount = total, sha256 = digest } };
            }
        }
        public sealed class CopyInput { public string relativePath; public string sourcePath; public Observation observation; }
        public sealed class CopyPlan { public TreeManifest manifest; public CopyInput[] inputs; public CopyInput[] links; }
        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern uint GetFinalPathNameByHandleW(SafeFileHandle file, StringBuilder path, uint count, uint flags);
        private static string FollowedPath(string path) {
            using (SafeFileHandle handle = CreateFileW(path, 0x80, 7, IntPtr.Zero, 3, 0x02000000, IntPtr.Zero)) {
                if (handle.IsInvalid) throw new Win32Exception(Marshal.GetLastWin32Error());
                StringBuilder result = new StringBuilder(32768);
                uint count = GetFinalPathNameByHandleW(handle, result, (uint)result.Capacity, 0);
                if (count == 0) throw new Win32Exception(Marshal.GetLastWin32Error());
                if (count >= result.Capacity) throw new IOException("Resolved operation path is too long.");
                string resolved = result.ToString();
                if (resolved.StartsWith(@"\\?\UNC\", StringComparison.OrdinalIgnoreCase)) return @"\\" + resolved.Substring(8);
                return resolved.StartsWith(@"\\?\", StringComparison.Ordinal) ? resolved.Substring(4) : resolved;
            }
        }
        public static CopyPlan PlanCopy(string path) {
            var inputs = new System.Collections.Generic.List<CopyInput>();
            var links = new System.Collections.Generic.List<CopyInput>();
            ExpandCopy(path, "", new System.Collections.Generic.HashSet<string>(StringComparer.Ordinal), 0, inputs, links);
            var entries = new System.Collections.Generic.List<TreeEntry>();
            var byName = new System.Collections.Generic.Dictionary<string, CopyInput>(StringComparer.Ordinal);
            foreach (CopyInput input in inputs) {
                entries.Add(new TreeEntry { relativePath = input.relativePath, observation = input.observation });
                byName.Add(input.relativePath, input);
            }
            TreeManifest manifest = MakeManifest(entries);
            CopyInput[] ordered = new CopyInput[manifest.entries.Length];
            for (int index = 0; index < ordered.Length; index++) ordered[index] = byName[manifest.entries[index].relativePath];
            return new CopyPlan { manifest = manifest, inputs = ordered, links = links.ToArray() };
        }
        private static string ObjectKey(Observation observation) { return observation.identity.volume + ":" + observation.identity.@object; }
        private static void ExpandCopy(string path, string prefix, System.Collections.Generic.HashSet<string> ancestors,
            int depth, System.Collections.Generic.List<CopyInput> inputs, System.Collections.Generic.List<CopyInput> links) {
            if (depth > 40) throw new IOException("Copy link traversal exceeded its limit.");
            TreeManifest manifest = Manifest(path);
            if (manifest.entries[0].observation.kind == "directory" && ancestors.Contains(ObjectKey(manifest.entries[0].observation)))
                throw new IOException("Copy source contains a directory link cycle.");
            foreach (TreeEntry entry in manifest.entries) {
                string relative = Encoding.UTF8.GetString(Convert.FromBase64String(entry.relativePath));
                string output = prefix.Length == 0 ? relative : relative.Length == 0 ? prefix : prefix + "/" + relative;
                string origin = relative.Length == 0 ? path : Path.Combine(path, relative.Replace('/', Path.DirectorySeparatorChar));
                string encoded = Convert.ToBase64String(Encoding.UTF8.GetBytes(output));
                if (entry.observation.kind != "symbolicLink") {
                    inputs.Add(new CopyInput { relativePath = encoded, sourcePath = origin, observation = entry.observation });
                    continue;
                }
                links.Add(new CopyInput { relativePath = encoded, sourcePath = origin, observation = entry.observation });
                string target = FollowedPath(origin);
                Require(Observe(origin), entry.observation.identity.volume, entry.observation.identity.@object, entry.observation.version);
                var parents = new System.Collections.Generic.HashSet<string>(ancestors, StringComparer.Ordinal);
                foreach (TreeEntry directory in manifest.entries) {
                    if (directory.observation.kind != "directory") continue;
                    string name = Encoding.UTF8.GetString(Convert.FromBase64String(directory.relativePath));
                    if (name.Length == 0 || relative.StartsWith(name + "/", StringComparison.Ordinal)) parents.Add(ObjectKey(directory.observation));
                }
                ExpandCopy(target, output, parents, depth + 1, inputs, links);
            }
        }
        private static void CollectTree(string path, string relative, System.Collections.Generic.List<TreeEntry> entries) {
            Observation before = Observe(path);
            string encoded = Convert.ToBase64String(Encoding.UTF8.GetBytes(relative));
            if (before.kind == "file") {
                Observation proved = Prove(path);
                Require(proved, before.identity.volume, before.identity.@object, before.version);
                entries.Add(new TreeEntry { relativePath = encoded, observation = proved });
            } else if (before.kind == "symbolicLink") {
                entries.Add(new TreeEntry { relativePath = encoded, observation = before });
            } else {
                using (SafeFileHandle directory = Open(path, 0x81, 3)) {
                    Require(Observe(directory), before.identity.volume, before.identity.@object, before.version);
                    string[] names = Directory.GetFileSystemEntries(path);
                    Array.Sort(names, StringComparer.Ordinal);
                    entries.Add(new TreeEntry { relativePath = encoded, observation = before });
                    foreach (string child in names) {
                        string name = Path.GetFileName(child);
                        CollectTree(child, relative.Length == 0 ? name : relative + "/" + name, entries);
                    }
                    string[] after = Directory.GetFileSystemEntries(path);
                    Array.Sort(after, StringComparer.Ordinal);
                    if (after.Length != names.Length) throw new IOException("Operation directory changed.");
                    for (int index = 0; index < names.Length; index++) {
                        if (names[index] != after[index]) throw new IOException("Operation directory changed.");
                    }
                    Require(Observe(directory), before.identity.volume, before.identity.@object, before.version);
                }
            }
            Require(Observe(path), before.identity.volume, before.identity.@object, before.version);
        }
        private static void Require(Observation actual, string volume, string id, string version) {
            if (actual.identity.volume != volume || actual.identity.@object != id || actual.version != version)
                throw new IOException("Operation object changed.");
        }
        public static Observation MoveExclusive(string source, string target, string volume, string id, string version) {
            return LinkOrMove(source, target, volume, id, version, 10);
        }
        public static Observation CreateArchiveHardLink(string source, string target, string volume, string id, string version) {
            return LinkOrMove(source, target, volume, id, version, 11);
        }
        private static Observation LinkOrMove(string source, string target, string volume, string id, string version, int information) {
            string parentPath = Path.GetDirectoryName(target), name = Path.GetFileName(target);
            if (String.IsNullOrEmpty(parentPath) || String.IsNullOrEmpty(name) || name == "." || name == "..")
                throw new IOException("Invalid operation destination.");
            using (SafeFileHandle parent = Open(parentPath, 0x80, 3))
            using (SafeFileHandle handle = Open(source, 0x10080, 7)) {
                Observation directory = Observe(parent), before = Observe(handle);
                if (directory.kind != "directory") throw new IOException("Operation destination parent is not a directory.");
                Require(before, volume, id, version);
                if (directory.identity.volume != volume) throw new IOException("Operation move requires the same volume.");
                byte[] text = Encoding.Unicode.GetBytes(name);
                int offset = Marshal.OffsetOf(typeof(RenameInfo), "name").ToInt32();
                int size = offset + text.Length + 2;
                IntPtr buffer = Marshal.AllocHGlobal(size);
                bool retained = false;
                try {
                    Marshal.Copy(new byte[size], 0, buffer, size);
                    parent.DangerousAddRef(ref retained);
                    Marshal.WriteIntPtr(buffer, Marshal.OffsetOf(typeof(RenameInfo), "root").ToInt32(), parent.DangerousGetHandle());
                    Marshal.WriteInt32(buffer, Marshal.OffsetOf(typeof(RenameInfo), "length").ToInt32(), text.Length);
                    Marshal.Copy(text, 0, IntPtr.Add(buffer, offset), text.Length);
                    // The NT entry point supports a pinned RootDirectory; the Win32 wrapper rejects it.
                    IoStatus result;
                    int status = NtSetInformationFile(handle, out result, buffer, (uint)size, information);
                    if (status != 0) throw new Win32Exception((int)RtlNtStatusToDosError(status));
                } finally {
                    if (retained) parent.DangerousRelease();
                    Marshal.FreeHGlobal(buffer);
                }
                Observation after = Observe(handle);
                if (after.identity.volume != before.identity.volume || after.identity.@object != before.identity.@object ||
                    after.kind != before.kind || after.contentVersion != before.contentVersion || after.linkTarget != before.linkTarget)
                    throw new IOException("Operation object changed during move.");
                return after;
            }
        }
        public static Observation CreatePrivateDirectory(string path) {
            SecurityIdentifier sid = WindowsIdentity.GetCurrent().User;
            DirectorySecurity security = new DirectorySecurity();
            security.SetOwner(sid); security.SetAccessRuleProtection(true, false);
            security.AddAccessRule(new FileSystemAccessRule(sid, FileSystemRights.FullControl,
                InheritanceFlags.ContainerInherit | InheritanceFlags.ObjectInherit, PropagationFlags.None, AccessControlType.Allow));
            byte[] descriptor = security.GetSecurityDescriptorBinaryForm();
            IntPtr buffer = Marshal.AllocHGlobal(descriptor.Length);
            try {
                Marshal.Copy(descriptor, 0, buffer, descriptor.Length);
                SecurityAttributes attributes = new SecurityAttributes { length = Marshal.SizeOf(typeof(SecurityAttributes)), descriptor = buffer, inherit = 0 };
                if (!CreateDirectoryW(path, ref attributes)) throw new Win32Exception(Marshal.GetLastWin32Error());
                return Observe(path);
            } finally { Marshal.FreeHGlobal(buffer); }
        }
    }
    '@
    }
    """#
}
