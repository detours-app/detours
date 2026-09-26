import Foundation

extension WindowsOperationScripts {
    static let tarReaderHelpers = #"""
    if (-not ('DetoursTarArchive' -as [type])) {
    Add-Type -TypeDefinition @'
    using System;
    using System.IO;
    using System.Text;
    using System.Globalization;
    using System.Collections.Generic;
    public sealed class DetoursTarArchive {
        public sealed class Entry {
            public string FullName;
            public string Kind;
            public string LinkTarget;
            public long Length;
            public DateTimeOffset LastWriteTime;
            internal long Offset;
            internal Stream Archive;
            public Stream Open() { Archive.Position = Offset; return new EntryStream(Archive, Length); }
        }
        private sealed class EntryStream : Stream {
            private Stream source;
            private long remaining;
            public EntryStream(Stream input, long length) { source = input; remaining = length; }
            public override int Read(byte[] buffer, int offset, int count) {
                int result = source.Read(buffer, offset, (int)Math.Min(count, remaining));
                if (result == 0 && remaining != 0) throw new EndOfStreamException("Incomplete TAR member.");
                remaining -= result; return result;
            }
            public override bool CanRead { get { return true; } }
            public override bool CanSeek { get { return false; } }
            public override bool CanWrite { get { return false; } }
            public override long Length { get { throw new NotSupportedException(); } }
            public override long Position { get { throw new NotSupportedException(); } set { throw new NotSupportedException(); } }
            public override void Flush() { }
            public override long Seek(long offset, SeekOrigin origin) { throw new NotSupportedException(); }
            public override void SetLength(long value) { throw new NotSupportedException(); }
            public override void Write(byte[] buffer, int offset, int count) { throw new NotSupportedException(); }
        }
        public Entry[] Entries;
        private static readonly Encoding Utf8 = new UTF8Encoding(false, true);
        private static string Text(byte[] data, int offset, int length) {
            int end = offset;
            while (end < offset + length && data[end] != 0) end++;
            return Utf8.GetString(data, offset, end - offset);
        }
        private static long Number(byte[] data, int offset, int length) {
            long result = 0;
            if ((data[offset] & 128) != 0) {
                if ((data[offset] & 64) != 0) throw new IOException("Negative TAR size.");
                result = data[offset] & 127;
                for (int index = 1; index < length; index++) result = checked(result * 256 + data[offset + index]);
                return result;
            }
            string value = Encoding.ASCII.GetString(data, offset, length).Trim('\0', ' ');
            foreach (char digit in value) {
                if (digit < '0' || digit > '7') throw new IOException("Invalid TAR number.");
                result = checked(result * 8 + digit - '0');
            }
            return result;
        }
        private static byte[] Read(Stream source, int count) {
            byte[] result = new byte[count]; int offset = 0;
            while (offset < count) {
                int received = source.Read(result, offset, count - offset);
                if (received == 0) throw new EndOfStreamException("Incomplete TAR archive.");
                offset += received;
            }
            return result;
        }
        private static Dictionary<string, string> Pax(byte[] data) {
            Dictionary<string, string> result = new Dictionary<string, string>(StringComparer.Ordinal);
            int offset = 0;
            while (offset < data.Length) {
                int space = Array.IndexOf(data, (byte)' ', offset);
                if (space < 0) throw new IOException("Invalid PAX length.");
                int length = int.Parse(Encoding.ASCII.GetString(data, offset, space - offset), CultureInfo.InvariantCulture);
                if (length <= space - offset + 2 || length > data.Length - offset || data[offset + length - 1] != 10)
                    throw new IOException("Invalid PAX record.");
                string record = Utf8.GetString(data, space + 1, offset + length - space - 2);
                int separator = record.IndexOf('=');
                if (separator < 1) throw new IOException("Invalid PAX key.");
                result[record.Substring(0, separator)] = record.Substring(separator + 1);
                offset += length;
            }
            return result;
        }
        public DetoursTarArchive(Stream source) {
            List<Entry> entries = new List<Entry>();
            Dictionary<string, string> global = new Dictionary<string, string>(StringComparer.Ordinal);
            Dictionary<string, string> next = new Dictionary<string, string>(StringComparer.Ordinal);
            source.Position = 0;
            while (source.Position < source.Length) {
                byte[] header = Read(source, 512); bool empty = true; long sum = 0;
                for (int index = 0; index < header.Length; index++) {
                    if (header[index] != 0) empty = false;
                    sum += index >= 148 && index < 156 ? 32 : header[index];
                }
                if (empty) break;
                if (sum != Number(header, 148, 8)) throw new IOException("Invalid TAR header checksum.");
                long length = Number(header, 124, 12); char kind = (char)header[156];
                if (kind == 'x' || kind == 'g') {
                    if (length > 16777216) throw new IOException("TAR metadata exceeds the supported size.");
                    Dictionary<string, string> values = Pax(Read(source, (int)length));
                    foreach (KeyValuePair<string, string> pair in values) (kind == 'g' ? global : next)[pair.Key] = pair.Value;
                    source.Position = checked(source.Position + (512 - length % 512) % 512);
                    continue;
                }
                Dictionary<string, string> attributes = new Dictionary<string, string>(global);
                foreach (KeyValuePair<string, string> pair in next) attributes[pair.Key] = pair.Value;
                next.Clear();
                string name = Text(header, 0, 100); string prefix = Text(header, 345, 155);
                if (prefix.Length > 0) name = prefix + "/" + name;
                if (attributes.ContainsKey("path")) name = attributes["path"];
                bool rootEntry = name == "." || name == "./";
                while (name.StartsWith("./", StringComparison.Ordinal)) name = name.Substring(2);
                if (attributes.ContainsKey("size")) length = long.Parse(attributes["size"], CultureInfo.InvariantCulture);
                string target = attributes.ContainsKey("linkpath") ? attributes["linkpath"] : Text(header, 157, 100);
                decimal time = attributes.ContainsKey("mtime") ? decimal.Parse(attributes["mtime"], CultureInfo.InvariantCulture) : Number(header, 136, 12);
                string type;
                switch (kind) {
                    case '\0': case '0': type = "file"; break;
                    case '5': type = "directory"; if (!name.EndsWith("/", StringComparison.Ordinal)) name += "/"; break;
                    case '1': type = "hardLink"; break;
                    case '2': type = "symbolicLink"; break;
                    default: throw new IOException("Unsupported Windows TAR entry type: " + kind);
                }
                if (length < 0 || length > source.Length - source.Position) throw new IOException("Invalid TAR member size.");
                if (type == "directory" && rootEntry) { source.Position += length + (512 - length % 512) % 512; continue; }
                entries.Add(new Entry { FullName = name, Kind = type, LinkTarget = target, Length = length,
                    LastWriteTime = new DateTimeOffset(1970, 1, 1, 0, 0, 0, TimeSpan.Zero).AddTicks(checked((long)(time * 10000000))),
                    Offset = source.Position, Archive = source });
                source.Position = checked(source.Position + length + (512 - length % 512) % 512);
            }
            Entries = entries.ToArray();
        }
    }
    '@
    }
    """#
}
