import Foundation

extension WindowsOperationScripts {
    static let rarVolumes = #"""
    public sealed class DetoursRarVolumeSet : IDisposable {
        public sealed class Part {
            public string Name;
            public object Observation;
            public long Length;
            internal string Volume, Identity, Version, Hash;
            internal int Format;
        }
        private readonly Type files;
        private readonly DetoursSevenZipLibrary library;
        private readonly string directory;
        private readonly string password;
        private readonly string[] names;
        private readonly string[] accepted;
        private readonly object parent;
        private readonly IDisposable pin;
        private readonly List<Part> parts = new List<Part>();
        private readonly Part selectedPart;
        private DetoursSevenZipArchive.Entry previous;
        private bool previousVolume;
        public readonly DetoursSevenZipCancellation Cancellation;
        public readonly string FirstName;
        public readonly string BaseName;
        public readonly int Format;
        public Part[] Parts { get { return parts.ToArray(); } }
        private static object Field(object value, string name) { return value.GetType().GetField(name).GetValue(value); }
        private static string Text(object value, string name) { return (string)Field(value, name); }
        private object Call(string method, params object[] args) {
            try { return files.GetMethod(method).Invoke(null, args); }
            catch (System.Reflection.TargetInvocationException error) { throw error.InnerException; }
        }
        private static string Identity(object observation, string name) { return Text(Field(observation, "identity"), name); }
        public DetoursRarVolumeSet(Type nativeFiles, DetoursSevenZipLibrary decoder, string selected, string secret,
            string cancelPath, string[] acceptedNames) {
            files = nativeFiles; library = decoder; password = secret; accepted = acceptedNames;
            Cancellation = new DetoursSevenZipCancellation(cancelPath);
            directory = Path.GetDirectoryName(selected);
            parent = Call("Observe", directory);
            pin = (IDisposable)Call("PinDirectory", directory, Identity(parent, "volume"), Identity(parent, "object"));
            try {
                if (accepted != null && (accepted.Length == 0 || accepted.Length > 1024)) throw new IOException("RAR accepts at most 1,024 parts.");
                names = accepted == null ? Array.ConvertAll(Directory.GetFileSystemEntries(directory), Path.GetFileName) : accepted;
                string name = Resolve(Path.GetFileName(selected));
                selectedPart = Prove(name);
                Format = selectedPart.Format;
                using (DetoursSevenZipArchive header = Inspect(selectedPart)) {
                    string first, basis; int index; Naming(name, out first, out basis, out index);
                    FirstName = Resolve(header.IsVolume ? first : name);
                    BaseName = header.IsVolume ? basis : Path.GetFileNameWithoutExtension(name);
                }
            } catch { pin.Dispose(); throw; }
        }
        public static void Naming(string name, out string first, out string basis, out int index) {
            if (String.IsNullOrEmpty(name) || name.IndexOfAny(new char[] { '/', '\\', ':', '\0' }) >= 0)
                throw new IOException("Invalid RAR volume name.");
            System.Text.RegularExpressions.Match modern = System.Text.RegularExpressions.Regex.Match(name, @"^(.*)\.part([0-9]+)\.rar$",
                System.Text.RegularExpressions.RegexOptions.IgnoreCase);
            if (modern.Success) {
                int number;
                if (!Int32.TryParse(modern.Groups[2].Value, out number) || number < 1 || number > 1024)
                    throw new IOException("RAR accepts at most 1,024 parts.");
                basis = modern.Groups[1].Value; index = number - 1;
                first = name.Substring(0, modern.Groups[2].Index) + "1".PadLeft(modern.Groups[2].Length, '0') + name.Substring(name.Length - 4);
            } else if (name.EndsWith(".rar", StringComparison.OrdinalIgnoreCase)) {
                first = name; basis = name.Substring(0, name.Length - 4); index = 0;
            } else {
                System.Text.RegularExpressions.Match legacy = System.Text.RegularExpressions.Regex.Match(name, @"^(.*)\.([r-z])([0-9]{2})$",
                    System.Text.RegularExpressions.RegexOptions.IgnoreCase);
                if (!legacy.Success) throw new IOException("Invalid RAR volume name.");
                basis = legacy.Groups[1].Value; first = basis + ".rar";
                index = 1 + (Char.ToLowerInvariant(legacy.Groups[2].Value[0]) - 'r') * 100 + Int32.Parse(legacy.Groups[3].Value);
            }
        }
        private string Resolve(string requested) {
            string first, basis; int index; Naming(requested, out first, out basis, out index);
            string found = null;
            foreach (string name in names) {
                if (!String.Equals(name, requested, StringComparison.OrdinalIgnoreCase)) continue;
                if (found != null) throw new IOException("Ambiguous RAR parts: " + requested);
                found = name;
            }
            if (found == null) throw new IOException("Missing RAR part: " + requested);
            return found;
        }
        private void ValidateParent() {
            Cancellation.Check(); object current = Call("Observe", directory);
            if (Text(current, "kind") != "directory" || Identity(current, "volume") != Identity(parent, "volume") ||
                Identity(current, "object") != Identity(parent, "object")) throw new IOException("RAR source directory changed.");
        }
        public Stream OpenFile(Part part) {
            ValidateParent();
            return (Stream)Call("OpenObservedFile", Path.Combine(directory, part.Name), part.Volume, part.Identity, part.Version);
        }
        private Part Prove(string name) {
            ValidateParent(); object observed = Call("Observe", Path.Combine(directory, name));
            if (Text(observed, "kind") != "file") throw new IOException("RAR parts must be regular files, without reparse points.");
            Part part = new Part { Name = name, Observation = observed, Volume = Identity(observed, "volume"),
                Identity = Identity(observed, "object"), Version = Text(observed, "version"), Length = checked((long)(ulong)Field(observed, "byteCount")) };
            using (Stream input = OpenFile(part)) {
                byte[] signature = new byte[8]; int offset = 0;
                while (offset < 8) { int count = input.Read(signature, offset, 8 - offset); if (count == 0) throw new IOException("Damaged RAR archive."); offset += count; }
                byte[] prefix = { 0x52, 0x61, 0x72, 0x21, 0x1a, 0x07 };
                for (int i = 0; i < prefix.Length; i++) if (signature[i] != prefix[i]) throw new IOException("Damaged RAR archive.");
                part.Format = signature[6] == 0 ? 3 : signature[6] == 1 && signature[7] == 0 ? 0xCC : 0;
                if (part.Format == 0) throw new IOException("Unsupported RAR archive signature.");
                input.Position = 0;
                using (SHA256 hash = SHA256.Create()) {
                    byte[] buffer = new byte[65536]; int count;
                    while ((count = input.Read(buffer, 0, buffer.Length)) > 0) { Cancellation.Check(); hash.TransformBlock(buffer, 0, count, buffer, 0); }
                    hash.TransformFinalBlock(new byte[0], 0, 0);
                    part.Hash = BitConverter.ToString(hash.Hash).Replace("-", "").ToLowerInvariant();
                    observed.GetType().GetField("sha256").SetValue(observed, part.Hash);
                }
                object after = Call("ObserveStream", input);
                if (Text(after, "version") != part.Version || Identity(after, "object") != part.Identity ||
                    Identity(after, "volume") != part.Volume) throw new IOException("RAR part changed.");
            }
            return part;
        }
        private DetoursSevenZipArchive Inspect(Part part) {
            using (Stream input = OpenFile(part)) {
                DetoursRarOpen callback = new DetoursRarOpen(null, part.Name, password, Cancellation);
                return library.ReadRar(new DetoursSevenZipArchiveStream(input, Cancellation), part.Format, callback, Cancellation, true);
            }
        }
        public IDetoursSevenZipSeekInput Open(string requested) {
            string name = Resolve(requested);
            foreach (Part known in parts) if (known.Name == name) return new DetoursRarInput(this, known);
            if (parts.Count >= 1024) throw new IOException("RAR accepts at most 1,024 parts.");
            if (accepted != null && (parts.Count >= accepted.Length || name != accepted[parts.Count]))
                throw new IOException("RAR part order differs from the accepted set.");
            Part part = Prove(name);
            if (part.Format != Format) throw new IOException("Inconsistent RAR parts.");
            foreach (Part known in parts) if (known.Identity == part.Identity && known.Volume == part.Volume)
                throw new IOException("Repeated RAR part identity.");
            using (DetoursSevenZipArchive header = Inspect(part)) {
                string first, basis; int index; Naming(name, out first, out basis, out index);
                if (header.IsVolume && (index != parts.Count || header.VolumeIndex >= 0 && header.VolumeIndex != parts.Count))
                    throw new IOException("Inconsistent RAR volume sequence.");
                DetoursSevenZipArchive.Entry start = header.Entries.Length == 0 ? null : header.Entries[0];
                if (parts.Count == 0) {
                    if (start != null && start.SplitBefore) throw new IOException("Missing first RAR part.");
                } else {
                    if (!previousVolume || !header.IsVolume || (previous != null && previous.SplitAfter) != (start != null && start.SplitBefore))
                        throw new IOException("Inconsistent RAR split boundaries.");
                    if (previous != null && previous.SplitAfter && (previous.FullName != start.FullName || previous.Length != start.Length ||
                        previous.Encrypted != start.Encrypted || previous.Kind != start.Kind)) throw new IOException("Inconsistent RAR split member.");
                }
                previousVolume = header.IsVolume; previous = header.Entries.Length == 0 ? null : header.Entries[header.Entries.Length - 1];
            }
            parts.Add(part); return new DetoursRarInput(this, part);
        }
        public DetoursSevenZipArchive OpenArchive() {
            IDetoursSevenZipSeekInput first = Open(FirstName);
            DetoursRarOpen callback = new DetoursRarOpen(this, FirstName, password, Cancellation);
            DetoursSevenZipArchive archive = library.ReadRar(first, Format, callback, Cancellation, false);
            try {
                if (accepted != null && parts.Count != accepted.Length) throw new IOException("RAR accepted set contains unused parts.");
                bool selectedFound = false;
                foreach (Part part in parts) if (part.Name == selectedPart.Name && part.Identity == selectedPart.Identity &&
                    part.Volume == selectedPart.Volume && part.Version == selectedPart.Version && part.Hash == selectedPart.Hash) selectedFound = true;
                if (!selectedFound) throw new IOException("Selected RAR part does not belong to the complete archive.");
                Validate(); return archive;
            } catch { archive.Dispose(); throw; }
        }
        public void Validate() {
            foreach (Part expected in parts) {
                Part actual = Prove(expected.Name);
                if (actual.Volume != expected.Volume || actual.Identity != expected.Identity || actual.Version != expected.Version ||
                    actual.Length != expected.Length || actual.Hash != expected.Hash) throw new IOException("RAR part changed.");
            }
        }
        public void Dispose() { pin.Dispose(); }
    }
    """#
}
