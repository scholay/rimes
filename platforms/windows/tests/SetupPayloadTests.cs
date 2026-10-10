using System;
using System.Collections.Generic;
using System.IO;
using System.IO.Compression;
using System.Security.Cryptography;
using System.Text;
using System.Threading;

internal static class SetupPayloadTests
{
    private static int checks;
    private static MemoryStream Archive(params string[] names)
    {
        var stream = new MemoryStream();
        using (var archive = new ZipArchive(stream, ZipArchiveMode.Create, true))
            foreach (var name in names)
                using (var writer = new StreamWriter(archive.CreateEntry(name).Open(), new UTF8Encoding(false)))
                    writer.Write("test content");
        stream.Position = 0;
        return stream;
    }
    private static string Hash(MemoryStream stream)
    {
        using (var sha = SHA256.Create())
        {
            var result = BitConverter.ToString(sha.ComputeHash(stream)).Replace("-", "").ToLowerInvariant();
            stream.Position = 0;
            return result;
        }
    }
    private static void Case(string root, bool valid, bool wrongHash, params string[] names)
    {
        var destination = Path.Combine(root, Guid.NewGuid().ToString("N"));
        using (var stream = Archive(names))
        {
            var rejected = false;
            try { Payload.Extract(stream, wrongHash ? new string('0', 64) : Hash(stream), destination); }
            catch (InvalidDataException) { rejected = true; }
            if (valid == rejected) throw new Exception("Unexpected extraction result: " + String.Join(", ", names));
            if (valid && File.ReadAllText(Path.Combine(destination, names[0])) != "test content")
                throw new Exception("Extracted content changed");
        }
        checks++;
    }
    public static int Main(string[] args)
    {
        if (args.Length == 1 && args[0] == "--broker-name") {
            using (var identity = System.Security.Principal.WindowsIdentity.GetCurrent())
                Console.WriteLine(InstallationGate.BrokerMutexName(identity.User.Value, System.Diagnostics.Process.GetCurrentProcess().SessionId));
            return 0;
        }
        if (args.Length != 0) return 2;
        var root = Path.Combine(Path.GetTempPath(), "RIMES setup tests 中文 ' " + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(root);
        try
        {
            var previousModulePath = Environment.GetEnvironmentVariable("PSModulePath");
            System.Diagnostics.ProcessStartInfo transport;
            try {
                Environment.SetEnvironmentVariable("PSModulePath", Path.Combine(root, "incompatible-modules"));
                transport = Payload.PowerShellStartInfo(
                    "$ErrorActionPreference='Stop'; [Console]::OutputEncoding=[Text.UTF8Encoding]::new(); " +
                    "$hash=Get-FileHash -InputStream ([IO.MemoryStream]::new([Text.Encoding]::UTF8.GetBytes('test content'))) -Algorithm SHA256; " +
                    "if($PSVersionTable.PSEdition -ne 'Desktop'){exit 2}; [Console]::WriteLine($hash.Hash.ToLowerInvariant())");
            } finally { Environment.SetEnvironmentVariable("PSModulePath", previousModulePath); }
            var systemModules = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.Windows),
                @"System32\WindowsPowerShell\v1.0\Modules");
            if (transport.EnvironmentVariables["PSModulePath"] != systemModules ||
                transport.UseShellExecute || !transport.CreateNoWindow)
                throw new Exception("Installer inherited caller modules or an interactive transport");
            checks++;
            using (var process = System.Diagnostics.Process.Start(transport)) {
                var output = process.StandardOutput.ReadToEndAsync();
                var error = process.StandardError.ReadToEndAsync();
                if (!process.WaitForExit(15000)) { process.Kill(); throw new Exception("PowerShell transport test timed out"); }
                System.Threading.Tasks.Task.WaitAll(output, error);
                using (var stream = new MemoryStream(Encoding.UTF8.GetBytes("test content")))
                    if (process.ExitCode != 0 || output.Result.Trim() != Hash(stream))
                        throw new Exception("System PowerShell hashing failed with caller modules: " + error.Result);
            }
            checks++;
            Case(root, true, false, "folder/file.txt");
            Case(root, false, true, "file.txt");
            Case(root, false, false, "../escape.txt");
            Case(root, false, false, "folder/../../escape.txt");
            Case(root, false, false, "/absolute.txt");
            Case(root, false, false, "C:/absolute.txt");
            Case(root, false, false, "file.txt:stream");
            Case(root, false, false, "same.txt", "SAME.txt");
            Case(root, false, false, "folder./file.txt");
            Case(root, false, false, "folder /file.txt");
            if (File.Exists(Path.Combine(root, "escape.txt"))) throw new Exception("Extraction escaped its destination");
            foreach (var exitCode in new[] { 1, 1602, 1223, 1603 })
            {
                bool called = false, rejected = false;
                try { SetupProgram.CompleteUserAfterMachine(exitCode, delegate { called = true; return null; }); }
                catch (InvalidOperationException) { rejected = true; }
                if (called || !rejected) throw new Exception("User setup ran after a failed/cancelled machine phase");
                checks++;
            }
            foreach (var exitCode in new[] { 0, 3010 })
            {
                var callerThread = System.Threading.Thread.CurrentThread.ManagedThreadId;
                bool called = false;
                var result = SetupProgram.CompleteUserAfterMachine(exitCode, delegate {
                    if (System.Threading.Thread.CurrentThread.ManagedThreadId != callerThread)
                        throw new Exception("User setup left the initiating execution context");
                    called = true;
                    return new Dictionary<string, object> { { "requiresRestart", false }, { "installed", true } };
                });
                if (!called || (bool)result["requiresRestart"] != (exitCode == 3010))
                    throw new Exception("Completion lost the runtime restart requirement");
                checks++;
            }
            bool userFailureReported = false;
            try { SetupProgram.CompleteUserAfterMachine(3010, delegate { throw new IOException("fixture user initialization failure"); }); }
            catch (InvalidOperationException error) { userFailureReported = error.Message.Contains("restart") && error.InnerException is IOException; }
            if (!userFailureReported) throw new Exception("User setup failure lost the pending restart");
            checks++;
            var name = "Local\\RIMES.SetupTests-" + Guid.NewGuid().ToString("N");
            using (var gate = new InstallationGate(name))
            {
                bool created;
                using (var attemptedBroker = new Mutex(false, name, out created))
                    if (created) throw new Exception("TSF could start a Broker during installation");
                checks++;
                bool rejected = false;
                try { using (var concurrent = new InstallationGate(name)) { } }
                catch (InvalidOperationException) { rejected = true; }
                if (!rejected) throw new Exception("Concurrent setup was accepted");
                checks++;
                Exception failure = null;
                var child = new Thread(delegate() {
                    try {
                        using (var deployment = Mutex.OpenExisting(name)) {
                            if (!deployment.WaitOne(0)) throw new Exception("Deployment could not take the unowned reservation");
                            deployment.ReleaseMutex();
                        }
                    } catch (Exception error) { failure = error; }
                });
                child.Start(); child.Join();
                if (failure != null) throw failure;
                using (var attemptedBroker = new Mutex(false, name, out created))
                    if (created) throw new Exception("Reservation disappeared after dictionary deployment");
                checks++;
            }
            bool newObject;
            using (var afterCompletion = new Mutex(false, name, out newObject))
                if (!newObject) throw new Exception("Installation leaked its Broker reservation");
            checks++;
            using (var existingBroker = new Mutex(false, name))
            {
                using (var gate = new InstallationGate(name)) {
                    existingBroker.Dispose();
                    using (var restartedBroker = new Mutex(false, name, out newObject))
                        if (newObject) throw new Exception("Stopping the live Broker lost the maintenance reservation");
                    checks++;
                }
                using (var companion = new Mutex(false, name + ".setup", out newObject))
                    if (!newObject) throw new Exception("Completed setup leaked its companion gate");
                checks++;
            }
            foreach (var machineExit in new[] { 1602, 1603 }) {
                try { using (var gate = new InstallationGate(name))
                    SetupProgram.CompleteUserAfterMachine(machineExit, delegate { throw new Exception("Unexpected user setup"); }); }
                catch (InvalidOperationException) { }
                using (var recovered = new Mutex(false, name, out newObject))
                    if (!newObject) throw new Exception("Failed machine setup leaked its reservation");
                checks++;
            }
            var diagnostic = SetupProgram.ElevationFailureMessage(8235);
            if (!diagnostic.Contains("8235") || !diagnostic.Contains("VC++") ||
                !(diagnostic.Contains("UAC")) || !diagnostic.Contains(SetupWindow.T("签名", "signature")))
                throw new Exception("Signature-policy diagnostic is incomplete");
            checks++;
            if (!SetupProgram.ElevationFailureMessage(5).Contains("(5)"))
                throw new Exception("Unrelated Windows error was relabelled as a signature failure");
            checks++;
            Console.WriteLine("PASS: " + checks + " installer payload cases");
            return 0;
        }
        finally { Directory.Delete(root, true); }
    }
}
