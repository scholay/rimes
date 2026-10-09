using System;
using System.Collections.Generic;
using System.IO;
using System.IO.Compression;
using System.Security.Cryptography;
using System.Text;

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
    public static int Main()
    {
        var root = Path.Combine(Path.GetTempPath(), "RIMES setup tests 中文 ' " + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(root);
        try
        {
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
            Console.WriteLine("PASS: " + checks + " installer payload cases");
            return 0;
        }
        finally { Directory.Delete(root, true); }
    }
}
