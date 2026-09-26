import Foundation

extension WindowsOperationScripts {
    static let archiveProcessHelpers = #"""
    if (-not ('DetoursArchiveProcess' -as [type])) {
    Add-Type -TypeDefinition @'
    using System;
    using System.IO;
    using System.Text;
    using System.Diagnostics;
    using System.Threading.Tasks;
    public sealed class DetoursArchiveProcess : IDisposable {
        private Process process;
        private Task output;
        private Task<string> errors;
        private static string Quote(string value) {
            StringBuilder result = new StringBuilder("\"");
            int slashes = 0;
            foreach (char item in value) {
                if (item == '\\') { slashes++; continue; }
                if (item == '"') { result.Append('\\', slashes * 2 + 1); result.Append(item); }
                else { result.Append('\\', slashes); result.Append(item); }
                slashes = 0;
            }
            result.Append('\\', slashes * 2); result.Append('"'); return result.ToString();
        }
        public DetoursArchiveProcess(string executable, string[] arguments, string directory, Stream destination) {
            StringBuilder command = new StringBuilder();
            foreach (string argument in arguments) { if (command.Length > 0) command.Append(' '); command.Append(Quote(argument)); }
            process = new Process();
            process.StartInfo = new ProcessStartInfo(executable, command.ToString()) {
                UseShellExecute = false, CreateNoWindow = true, RedirectStandardOutput = true,
                RedirectStandardError = true, WorkingDirectory = directory
            };
            if (!process.Start()) throw new IOException("Archive process did not start.");
            errors = process.StandardError.ReadToEndAsync();
            output = process.StandardOutput.BaseStream.CopyToAsync(destination);
        }
        public bool Wait(int milliseconds) { return process.WaitForExit(milliseconds); }
        public void Complete() {
            output.GetAwaiter().GetResult();
            string error = errors.GetAwaiter().GetResult();
            if (process.ExitCode != 0) throw new IOException("Archive process failed (" + process.ExitCode + "): " + error);
        }
        public void Dispose() {
            try {
                if (!process.HasExited) { process.Kill(); if (!process.WaitForExit(5000)) throw new IOException("Archive process did not stop."); }
                output.GetAwaiter().GetResult();
                errors.GetAwaiter().GetResult();
            } finally { process.Dispose(); }
        }
    }
'@
    }
    function Write-WindowsArchiveProcess($Context, [string]$Executable, [string[]]$CommandArguments, [string]$Directory, $Output) {
        $process = [DetoursArchiveProcess]::new($Executable, $CommandArguments, $Directory, $Output)
        try {
            while (-not $process.Wait(100)) { Assert-WindowsOperationActive $Context }
            $process.Complete()
            Assert-WindowsOperationActive $Context
        } finally { $process.Dispose() }
    }
    """#
}
