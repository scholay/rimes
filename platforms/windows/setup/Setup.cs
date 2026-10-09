using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.Diagnostics;
using System.Drawing;
using System.IO;
using System.IO.Compression;
using System.Linq;
using System.Reflection;
using System.Security.AccessControl;
using System.Security.Cryptography;
using System.Security.Principal;
using System.Text;
using System.Threading;
using System.Threading.Tasks;
using System.Web.Script.Serialization;
using System.Windows.Forms;

internal static class Payload
{
    internal static ProcessStartInfo PowerShellStartInfo(string command)
    {
        var windowsPowerShell = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.Windows),
            @"System32\WindowsPowerShell\v1.0");
        var start = new ProcessStartInfo(Path.Combine(windowsPowerShell, "powershell.exe"),
            "-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -EncodedCommand " +
            Convert.ToBase64String(Encoding.Unicode.GetBytes(command)));
        // A PowerShell 7 parent may export incompatible modules ahead of the
        // Windows PowerShell modules. Setup only needs Windows built-ins; do
        // not discover commands from user or caller-controlled module paths.
        start.EnvironmentVariables["PSModulePath"] = Path.Combine(windowsPowerShell, "Modules");
        start.UseShellExecute = false;
        start.CreateNoWindow = true;
        start.RedirectStandardOutput = true;
        start.RedirectStandardError = true;
        start.StandardOutputEncoding = Encoding.UTF8;
        start.StandardErrorEncoding = Encoding.UTF8;
        return start;
    }

    internal static void Extract(Stream stream, string expectedHash, string destination)
    {
        using (var sha = SHA256.Create())
        {
            var hash = BitConverter.ToString(sha.ComputeHash(stream)).Replace("-", "").ToLowerInvariant();
            if (!String.Equals(hash, expectedHash, StringComparison.Ordinal))
                throw new InvalidDataException("Installer payload checksum failed. Download the installer again.");
        }
        stream.Position = 0;
        if (Directory.Exists(destination)) throw new IOException("Extraction directory already exists.");
        var access = new DirectorySecurity();
        access.SetAccessRuleProtection(true, false);
        foreach (var sid in new[] { WindowsIdentity.GetCurrent().User,
            new SecurityIdentifier(WellKnownSidType.LocalSystemSid, null),
            new SecurityIdentifier(WellKnownSidType.BuiltinAdministratorsSid, null) })
            access.AddAccessRule(new FileSystemAccessRule(sid, FileSystemRights.FullControl,
                InheritanceFlags.ContainerInherit | InheritanceFlags.ObjectInherit,
                PropagationFlags.None, AccessControlType.Allow));
        Directory.CreateDirectory(destination, access);
        var root = Path.GetFullPath(destination).TrimEnd(Path.DirectorySeparatorChar) + Path.DirectorySeparatorChar;
        var seen = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        long total = 0;
        using (var archive = new ZipArchive(stream, ZipArchiveMode.Read, true))
        {
            if (archive.Entries.Count > 5000) throw new InvalidDataException("Too many payload files.");
            foreach (var entry in archive.Entries)
            {
                var relative = entry.FullName.Replace('/', '\\');
                var parts = relative.TrimEnd('\\').Split('\\');
                if (Path.IsPathRooted(relative) || parts.Any(p => p.Length == 0 || p == "." || p == ".." ||
                    p.EndsWith(".") || p.EndsWith(" ") || p.IndexOfAny(Path.GetInvalidFileNameChars()) >= 0) ||
                    ((entry.ExternalAttributes >> 16) & 0xF000) == 0xA000)
                    throw new InvalidDataException("Invalid payload path.");
                var path = Path.GetFullPath(Path.Combine(root, relative));
                if (!path.StartsWith(root, StringComparison.OrdinalIgnoreCase) || !seen.Add(path))
                    throw new InvalidDataException("Duplicate or escaping payload path.");
                if (relative.EndsWith("\\")) { Directory.CreateDirectory(path); continue; }
                total = checked(total + entry.Length);
                if (entry.Length < 0 || total > 1024L * 1024 * 1024)
                    throw new InvalidDataException("Installer payload exceeds the size limit.");
                Directory.CreateDirectory(Path.GetDirectoryName(path));
                using (var input = entry.Open())
                using (var output = new FileStream(path, FileMode.CreateNew, FileAccess.Write, FileShare.None))
                {
                    var buffer = new byte[65536];
                    long copied = 0;
                    int count;
                    while ((count = input.Read(buffer, 0, buffer.Length)) > 0)
                    {
                        copied += count;
                        if (copied > entry.Length) throw new InvalidDataException("Invalid payload length.");
                        output.Write(buffer, 0, count);
                    }
                    if (copied != entry.Length) throw new InvalidDataException("Incomplete payload file.");
                }
            }
        }
    }

    internal static Dictionary<string, object> Run(bool install, bool autostart, string machineUserSid = null, string startupSnapshot = null)
    {
        var directory = Path.Combine(Path.GetTempPath(), "RIMES-Setup-" + Guid.NewGuid().ToString("N"));
        try
        {
            using (var stream = Assembly.GetExecutingAssembly().GetManifestResourceStream("RIMES.Payload.zip"))
            {
                if (stream == null) throw new InvalidDataException("Installer payload is missing.");
                Extract(stream, BuildInfo.PayloadHash, directory);
            }
            var script = Path.Combine(directory, "Setup.ps1").Replace("'", "''");
            var command = "$ErrorActionPreference='Stop'; $ProgressPreference='SilentlyContinue'; " +
                "[Console]::OutputEncoding=[Text.UTF8Encoding]::new(); try { & '" + script + "' -Action " +
                (install ? (machineUserSid == null ? "CompleteUser" : "Install") : "Verify") +
                (machineUserSid == null ? "" : " -MachineOnly -UserSid '" + new SecurityIdentifier(machineUserSid).Value + "'") +
                (startupSnapshot == null ? "" : " -UserAutostartSnapshot '" + startupSnapshot + "'") +
                (autostart ? "" : " -NoAutostart") +
                " } catch { [Console]::Error.WriteLine($_.Exception.Message); exit 1 }; exit 0";
            var start = PowerShellStartInfo(command);
            using (var process = Process.Start(start))
            {
                var stdout = process.StandardOutput.ReadToEndAsync();
                var stderr = process.StandardError.ReadToEndAsync();
                process.WaitForExit();
                Task.WaitAll(stdout, stderr);
                if (process.ExitCode != 0)
                    throw new InvalidOperationException(String.IsNullOrWhiteSpace(stderr.Result) ?
                        "Installer failed (exit " + process.ExitCode + ")." : stderr.Result.Trim());
                var line = stdout.Result.Split(new[] { '\r', '\n' }, StringSplitOptions.RemoveEmptyEntries).LastOrDefault();
                var result = new JavaScriptSerializer().Deserialize<Dictionary<string, object>>(line ?? "{}");
                if (!result.ContainsKey("verified") || !(bool)result["verified"] ||
                    !result.ContainsKey("installed") || (bool)result["installed"] != install ||
                    !result.ContainsKey("version") || (string)result["version"] != BuildInfo.Version)
                    throw new InvalidDataException("Installation verification did not confirm this version.");
                return result;
            }
        }
        finally
        {
            if (Directory.Exists(directory))
            {
                try { Directory.Delete(directory, true); }
                catch (IOException) { /* A runtime installer can briefly retain a file. */ }
                catch (UnauthorizedAccessException) { }
            }
        }
    }
}

// Broker treats the existence of its secured per-session mutex as its startup
// gate, independently of ownership. Retain an UNOWNED handle across elevation
// and user completion; the original-user deploy child can then own it without
// leaving a window in which a cached TSF DLL starts another dictionary engine.
internal sealed class InstallationGate : IDisposable
{
    private Mutex broker;
    private Mutex setup;
    private bool ownsSetup;

    internal static string BrokerMutexName(string sid, int session)
    {
        ulong hash = 14695981039346656037UL;
        unchecked { foreach (var unit in sid) { hash ^= unit; hash *= 1099511628211UL; } }
        return "Local\\RIMES.Broker.v2.session-" + session + ".user-" + hash.ToString("x16");
    }

    internal InstallationGate(string testName = null)
    {
        using (var identity = WindowsIdentity.GetCurrent())
        {
            var name = testName ?? BrokerMutexName(identity.User.Value, Process.GetCurrentProcess().SessionId);
            var security = new MutexSecurity();
            security.SetAccessRuleProtection(true, false);
            security.AddAccessRule(new MutexAccessRule(identity.User, MutexRights.FullControl, AccessControlType.Allow));
            try
            {
                bool created;
                setup = new Mutex(true, name + ".setup", out created, security);
                ownsSetup = created;
                if (!created) throw new InvalidOperationException("Another RIMES installation is in progress. Wait for it to finish.");
                broker = new Mutex(false, name, out created, security);
                if (!created) throw new InvalidOperationException(SetupWindow.T(
                    "请先保存 Buffer 内容并从托盘退出 RIMES，然后重试。安装器不会停止正在运行的输入法。",
                    "Save Buffer text and exit RIMES from the tray, then retry. Setup does not stop a running input method."));
            }
            catch { Dispose(); throw; }
        }
    }

    public void Dispose()
    {
        if (broker != null) { broker.Dispose(); broker = null; }
        if (setup != null)
        {
            if (ownsSetup) setup.ReleaseMutex();
            setup.Dispose(); setup = null; ownsSetup = false;
        }
    }
}

internal sealed class SetupWindow : Form
{
    private readonly Label message = new Label();
    private readonly Button install = new Button();
    private readonly Button close = new Button();
    private readonly CheckBox autostart = new CheckBox();
    private readonly ProgressBar progress = new ProgressBar();
    private bool busy;
    internal int ExitCode = 1602;

    internal static string T(string chinese, string english)
    {
        return System.Globalization.CultureInfo.CurrentUICulture.TwoLetterISOLanguageName == "zh" ? chinese : english;
    }

    internal SetupWindow()
    {
        Text = "RIMES " + BuildInfo.Version + T(" 安装", " Setup");
        Icon = System.Drawing.Icon.ExtractAssociatedIcon(Application.ExecutablePath);
        Font = new Font("Segoe UI", 10);
        ClientSize = new Size(600, 350);
        FormBorderStyle = FormBorderStyle.FixedDialog;
        MaximizeBox = false;
        StartPosition = FormStartPosition.CenterScreen;
        AutoScaleMode = AutoScaleMode.Dpi;
        var heading = new Label { Text = T("安装 RIMES 输入法", "Install RIMES"),
            Font = new Font(Font.FontFamily, 18, FontStyle.Bold), AutoSize = true, Location = new Point(24, 20) };
        message.SetBounds(24, 72, 552, 145);
        message.Text = T(
            "安装到此电脑，保留已有词库和设置。\n\n安装前请保存 Buffer 内容，并从托盘退出 RIMES。升级若需注销，安装完成后会提示；不会自动注销。",
            "Install on this computer while keeping existing dictionaries and settings.\n\nSave your Buffer text and exit RIMES from the tray first. Setup will tell you if sign-out is needed; it will not sign you out.");
        autostart.Text = T("登录后启动 RIMES", "Start RIMES when I sign in");
        autostart.Checked = true;
        autostart.SetBounds(24, 218, 550, 28);
        progress.SetBounds(24, 260, 552, 8);
        progress.Visible = false;
        install.Text = T("安装 / 升级", "Install / Update");
        install.SetBounds(326, 292, 140, 34);
        close.Text = T("关闭", "Close");
        close.SetBounds(478, 292, 98, 34);
        Controls.AddRange(new Control[] { heading, message, autostart, progress, install, close });
        close.Click += delegate { Close(); };
        install.Click += Install;
        FormClosing += delegate(object sender, FormClosingEventArgs e) { if (busy) e.Cancel = true; };
    }

    private void Install(object sender, EventArgs args)
    {
        busy = true;
        install.Enabled = close.Enabled = autostart.Enabled = false;
        progress.Visible = true;
        progress.Style = ProgressBarStyle.Marquee;
        message.Text = T("正在验证安装包、安装运行库并部署输入法。完整词库首次部署可能需要几分钟。",
            "Verifying the package, installing runtimes, and deploying RIMES. The initial dictionary deployment may take several minutes.");
        var startAtLogin = autostart.Checked;
        var worker = new BackgroundWorker();
        worker.DoWork += delegate(object s, DoWorkEventArgs e) { e.Result = SetupProgram.InstallForCurrentUser(startAtLogin); };
        worker.RunWorkerCompleted += delegate(object s, RunWorkerCompletedEventArgs e)
        {
            busy = false;
            close.Enabled = true;
            progress.Visible = false;
            if (e.Error != null)
            {
                ExitCode = 1603;
                message.Text = T("安装未完成。请按错误提示处理后重试。", "Installation was not completed. Resolve the error and try again.");
                install.Enabled = autostart.Enabled = true;
                MessageBox.Show(this, e.Error.Message, Text, MessageBoxButtons.OK, MessageBoxIcon.Error);
            }
            else
            {
                ExitCode = 0;
                var result = (Dictionary<string, object>)e.Result;
                var restart = (bool)result["requiresRestart"];
                var signOut = (bool)result["requiresSignOut"];
                message.Text = restart ? T("安装完成。请保存其他工作并重启 Windows，随后用 Win+Space 选择 RIMES。", "Installed. Save your work and restart Windows, then select RIMES with Win+Space.") :
                    signOut ? T("安装完成。请保存其他工作，注销并重新登录，让所有应用载入新版输入法。随后用 Win+Space 选择 RIMES。", "Installed. Save your work, sign out and sign in again so all apps load the new input method. Then select RIMES with Win+Space.") :
                    T("安装完成。用 Win+Space 选择 RIMES。已有词库和设置已保留。", "Installed. Select RIMES with Win+Space. Existing dictionaries and settings were retained.");
            }
            worker.Dispose();
        };
        worker.RunWorkerAsync();
    }
}

internal static class SetupProgram
{
    [STAThread]
    private static int Main(string[] args)
    {
        try
        {
            if (args.Length == 2 && args[0] == "--verify-only")
            {
                var result = Payload.Run(false, true);
                result["setupSHA256"] = HashFile(Assembly.GetExecutingAssembly().Location);
                result["payloadSHA256"] = BuildInfo.PayloadHash;
                File.WriteAllText(Path.GetFullPath(args[1]), new JavaScriptSerializer().Serialize(result), new UTF8Encoding(false));
                return 0;
            }
            if (!Environment.Is64BitOperatingSystem || !Environment.Is64BitProcess)
                throw new PlatformNotSupportedException("RIMES requires Windows x64.");
            // The UI stays under the initiating token even when RunAs uses a
            // different administrator. Only this explicit worker is elevated.
            if (args.Length == 3 && args[0] == "--install-machine")
            {
                var sid = new SecurityIdentifier(args[1]).Value;
                using (var identity = WindowsIdentity.GetCurrent())
                    if (!(new WindowsPrincipal(identity)).IsInRole(WindowsBuiltInRole.Administrator))
                        throw new InvalidOperationException("The system installation phase requires administrator approval.");
                // Validate the transport before including it in the PowerShell command.
                var snapshot = Convert.ToBase64String(Convert.FromBase64String(args[2]));
                if (args[2].Length > 8192) throw new ArgumentException("Startup snapshot is too large.");
                var result = Payload.Run(true, false, sid, snapshot);
                return (bool)result["requiresRestart"] ? 3010 : 0;
            }
            if (args.Length != 0) throw new ArgumentException("Unsupported installer arguments.");
            Application.EnableVisualStyles();
            Application.SetCompatibleTextRenderingDefault(false);
            using (var window = new SetupWindow())
            {
                Application.Run(window);
                return window.ExitCode;
            }
        }
        catch (Exception error)
        {
            if (args.Length > 0 && args[0] == "--verify-only") Console.Error.WriteLine(error.Message);
            else if (!(error is Win32Exception && ((Win32Exception)error).NativeErrorCode == 1223))
                MessageBox.Show(error.Message, "RIMES Setup", MessageBoxButtons.OK, MessageBoxIcon.Error);
            return 1;
        }
    }

    internal static Dictionary<string, object> InstallForCurrentUser(bool autostart)
    {
        string sid;
        using (var identity = WindowsIdentity.GetCurrent()) sid = identity.User.Value;
        object previousAutostart = null;
        using (var key = Microsoft.Win32.Registry.CurrentUser.OpenSubKey(@"Software\Microsoft\Windows\CurrentVersion\Run"))
            if (key != null) previousAutostart = key.GetValue("RimesBroker", null);
        if (previousAutostart != null && !(previousAutostart is string))
            throw new InvalidOperationException("The existing RIMES startup entry is not a text command.");
        var snapshot = Convert.ToBase64String(Encoding.UTF8.GetBytes(new JavaScriptSerializer().Serialize(
            new Dictionary<string, object> { { "userSid", sid }, { "autostart", previousAutostart } })));
        if (snapshot.Length > 8192) throw new InvalidOperationException("The existing RIMES startup entry is too large.");
        var start = new ProcessStartInfo(Assembly.GetExecutingAssembly().Location, "--install-machine " + sid + " " + snapshot);
        start.UseShellExecute = true;
        start.Verb = "runas";
        using (var gate = new InstallationGate())
        {
            int exitCode;
            try { using (var process = Process.Start(start)) { process.WaitForExit(); exitCode = process.ExitCode; } }
            catch (Win32Exception error)
            {
                if (error.NativeErrorCode != 8235) throw;
                throw new InvalidOperationException(ElevationFailureMessage(error.NativeErrorCode), error);
            }
            return CompleteUserAfterMachine(exitCode, delegate { return Payload.Run(true, autostart); });
        }
    }

    internal static string ElevationFailureMessage(int code)
    {
        if (code != 8235) return "Windows administrator approval failed (" + code + ").";
        return SetupWindow.T(
            "Windows 拒绝了安装程序的管理员提权（8235：从服务器返回了一个参照）。这不是安装器必须联网的提示。\n\n" +
            "请让管理员核查“仅提升签名并验证的可执行文件”策略及代码签名证书信任链。未签名测试包不能满足要求受信任签名的内网策略；需要 IT 批准的签名安装包及离线证书信任部署。\n\n" +
            "安装包已内置词库和 VC++ 运行库；安装器不会关闭 UAC、修改安全策略或跳过签名校验。",
            "Windows rejected administrator elevation (8235: A referral was returned from the server). This does not mean Setup requires an internet connection.\n\n" +
            "Ask IT to check the signed-and-validated elevation policy and the code-signing certificate trust chain. An unsigned preview cannot satisfy a trusted-signature policy; use an IT-approved signed package and offline certificate trust deployment.\n\n" +
            "Dictionaries and VC++ runtimes are bundled. Setup will not disable UAC, change security policy, or bypass signature validation.");
    }

    // Completion is deliberately executed by the original process, never by
    // the elevated worker or an account selected from a profile path.
    internal static Dictionary<string, object> CompleteUserAfterMachine(int exitCode,
        Func<Dictionary<string, object>> completeUser)
    {
        if (exitCode == 1223 || exitCode == 1602)
            throw new InvalidOperationException("Administrator approval was cancelled. Setup was not completed.");
        if (exitCode != 0 && exitCode != 3010)
            throw new InvalidOperationException("The system installation phase failed. User setup was not started.");
        Dictionary<string, object> result;
        try { result = completeUser(); }
        catch (Exception error)
        {
            if (exitCode == 3010)
                throw new InvalidOperationException("System changes require a Windows restart. User setup was not completed; restart and run Setup again from your account. " + error.Message, error);
            throw;
        }
        result["requiresRestart"] = (bool)result["requiresRestart"] || exitCode == 3010;
        return result;
    }

    private static string HashFile(string path)
    {
        using (var stream = File.OpenRead(path))
        using (var sha = SHA256.Create())
            return BitConverter.ToString(sha.ComputeHash(stream)).Replace("-", "").ToLowerInvariant();
    }
}
