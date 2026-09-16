using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Reflection;
using System.Runtime.InteropServices;
using System.Text;
using System.Web.Script.Serialization;

namespace CampusNet.Core
{
    /// <summary>程序用到的全部路径与固定常量。</summary>
    public static class AppPaths
    {
        public const string AppName = "CampusNet";
        public const string DisplayName = "校园网自动登录";
        public const string Version = "2.0.0-pre.7";

        /// <summary>旧版（1.x PowerShell 版）残留位置，仅用于检测与清理。</summary>
        public const string LegacyScriptDir = @"C:\CampusAutoLogin";
        public const string LegacyTaskName = "CampusAutoLogin";

        private static string LocalAppData
        {
            get { return Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData); }
        }

        /// <summary>测试用：把数据目录指向别处（为空时使用默认位置）。</summary>
        public static string DataDirOverride;

        public static string DataDir
        {
            get
            {
                return string.IsNullOrEmpty(DataDirOverride)
                    ? Path.Combine(LocalAppData, "CampusNet")
                    : DataDirOverride;
            }
        }

        public static string LegacyDataDir
        {
            get { return Path.Combine(LocalAppData, "CampusAutoLogin"); }
        }

        public static string InstallDir
        {
            get { return Path.Combine(LocalAppData, "Programs", "CampusNet"); }
        }

        public static string InstalledExe
        {
            get { return Path.Combine(InstallDir, "CampusNet.exe"); }
        }

        public static string ConfigFile
        {
            get { return Path.Combine(DataDir, "config.json"); }
        }

        public static string CredentialFile
        {
            get { return Path.Combine(DataDir, "credentials.dat"); }
        }

        public static string StateFile
        {
            get { return Path.Combine(DataDir, "state.json"); }
        }

        public static string LogFile
        {
            get { return Path.Combine(DataDir, "login.log"); }
        }

        public static string LogOldFile
        {
            get { return Path.Combine(DataDir, "login.log.old"); }
        }

        /// <summary>未处理异常（崩溃 / 界面异常）的记录，正常运行时不存在。</summary>
        public static string CrashFile
        {
            get { return Path.Combine(DataDir, "crash.log"); }
        }

        /// <summary>守护进程的拉起 / 重启记录。</summary>
        public static string WatchdogLogFile
        {
            get { return Path.Combine(DataDir, "watchdog.log"); }
        }

        public static string StartMenuDir
        {
            get
            {
                return Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData),
                    @"Microsoft\Windows\Start Menu\Programs");
            }
        }

        public static string StartMenuShortcut
        {
            get { return Path.Combine(StartMenuDir, DisplayName + ".lnk"); }
        }

        public static string DesktopShortcut
        {
            get
            {
                return Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.DesktopDirectory),
                    DisplayName + ".lnk");
            }
        }

        public static string CurrentExe
        {
            get
            {
                try
                {
                    string path = Assembly.GetEntryAssembly().Location;
                    if (!string.IsNullOrEmpty(path)) { return path; }
                }
                catch { }
                return Path.Combine(AppDomain.CurrentDomain.BaseDirectory, "CampusNet.exe");
            }
        }

        public static void EnsureDataDir()
        {
            Directory.CreateDirectory(DataDir);
        }

        public static string FormatTime(DateTime time)
        {
            return time.ToString("yyyy-MM-dd HH:mm:ss", CultureInfo.InvariantCulture);
        }

        public static string FormatTime(DateTime? time)
        {
            return time.HasValue ? FormatTime(time.Value) : string.Empty;
        }

        public static DateTime? ParseTime(string text)
        {
            if (string.IsNullOrEmpty(text)) { return null; }
            DateTime value;
            if (DateTime.TryParse(text, CultureInfo.InvariantCulture, DateTimeStyles.None, out value)) { return value; }
            if (DateTime.TryParse(text, CultureInfo.CurrentCulture, DateTimeStyles.None, out value)) { return value; }
            return null;
        }
    }

    /// <summary>极简 JSON 读写（读取用 JavaScriptSerializer，写出用受控的字符串拼接）。</summary>
    public static class Json
    {
        private static readonly JavaScriptSerializer Serializer = CreateSerializer();

        private static JavaScriptSerializer CreateSerializer()
        {
            var serializer = new JavaScriptSerializer();
            serializer.MaxJsonLength = int.MaxValue;
            serializer.RecursionLimit = 40;
            return serializer;
        }

        public static Dictionary<string, object> ReadObject(string path)
        {
            if (!File.Exists(path)) { return null; }
            string text = File.ReadAllText(path, Encoding.UTF8);
            if (string.IsNullOrWhiteSpace(text)) { return null; }
            return ReadObjectFromText(text);
        }

        public static Dictionary<string, object> ReadObjectFromText(string text)
        {
            if (string.IsNullOrWhiteSpace(text)) { return null; }
            object parsed = Serializer.DeserializeObject(text);
            return parsed as Dictionary<string, object>;
        }

        /// <summary>
        /// 原子写入文本文件（先写临时文件再替换，避免断电或崩溃留下半截文件）。
        /// 统一带 UTF-8 BOM：Windows 上的记事本、PowerShell 5.1 等工具默认按 ANSI 读取，
        /// 没有 BOM 时中文会乱码。
        ///
        /// 这里刻意不用「先删目标再改名」：那中间有一瞬间文件是不存在的，
        /// 此刻断电 / 崩溃就会把用户配置整个丢掉（丢掉配置 = 下次启动用默认 Portal 登录）。
        /// 先用 File.Replace 原地替换，只有它不被支持时才退回删除 + 改名。
        /// 临时文件名带随机后缀：并发写入（界面保存 + 后台线程）不会互相踩。
        /// </summary>
        public static void WriteText(string path, string text)
        {
            string dir = Path.GetDirectoryName(path);
            if (!string.IsNullOrEmpty(dir)) { Directory.CreateDirectory(dir); }
            string temp = path + "." + Guid.NewGuid().ToString("N").Substring(0, 8) + ".tmp";
            try
            {
                using (var stream = new FileStream(temp, FileMode.Create, FileAccess.Write, FileShare.None))
                using (var writer = new StreamWriter(stream, Utf8WithBom))
                {
                    writer.Write(text);
                    writer.Flush();
                    stream.Flush(true);   // 落到磁盘之后再替换，断电也不会得到半截内容
                }
                if (File.Exists(path))
                {
                    try
                    {
                        File.Replace(temp, path, null, true);
                        return;
                    }
                    catch (PlatformNotSupportedException) { }
                    catch (IOException) { }
                    catch (UnauthorizedAccessException) { }
                }
                if (File.Exists(path)) { File.Delete(path); }
                File.Move(temp, path);
            }
            finally
            {
                try { if (File.Exists(temp)) { File.Delete(temp); } } catch { }
            }
        }

        public static readonly UTF8Encoding Utf8WithBom = new UTF8Encoding(true);

        public static string Escape(string value)
        {
            if (value == null) { return string.Empty; }
            var builder = new StringBuilder(value.Length + 16);
            foreach (char ch in value)
            {
                switch (ch)
                {
                    case '"': builder.Append("\\\""); break;
                    case '\\': builder.Append("\\\\"); break;
                    case '\r': builder.Append("\\r"); break;
                    case '\n': builder.Append("\\n"); break;
                    case '\t': builder.Append("\\t"); break;
                    default:
                        if (ch < ' ') { builder.Append("\\u").Append(((int)ch).ToString("x4", CultureInfo.InvariantCulture)); }
                        else { builder.Append(ch); }
                        break;
                }
            }
            return builder.ToString();
        }

        public static string String(string value)
        {
            return "\"" + Escape(value) + "\"";
        }

        public static string String(string name, string value)
        {
            return String(name) + ": " + String(value);
        }

        public static string Number(string name, long value)
        {
            return String(name) + ": " + value.ToString(CultureInfo.InvariantCulture);
        }

        public static string Bool(string name, bool value)
        {
            return String(name) + ": " + (value ? "true" : "false");
        }

        public static string GetString(Dictionary<string, object> map, string key, string fallback)
        {
            if (map == null || !map.ContainsKey(key) || map[key] == null) { return fallback; }
            string value = Convert.ToString(map[key], CultureInfo.InvariantCulture);
            return string.IsNullOrEmpty(value) ? fallback : value;
        }

        public static int GetInt(Dictionary<string, object> map, string key, int fallback)
        {
            if (map == null || !map.ContainsKey(key) || map[key] == null) { return fallback; }
            try { return Convert.ToInt32(map[key], CultureInfo.InvariantCulture); }
            catch { return fallback; }
        }

        public static bool GetBool(Dictionary<string, object> map, string key, bool fallback)
        {
            if (map == null || !map.ContainsKey(key) || map[key] == null) { return fallback; }
            object raw = map[key];
            if (raw is bool) { return (bool)raw; }
            string text = Convert.ToString(raw, CultureInfo.InvariantCulture);
            if (string.IsNullOrEmpty(text)) { return fallback; }
            return text.Equals("true", StringComparison.OrdinalIgnoreCase) || text == "1";
        }
    }

    /// <summary>滚动日志：写入 login.log，超过阈值后滚动到 login.log.old；同时在内存保留最近若干行供界面显示。</summary>
    public sealed class Logger
    {
        public const int MaxBytes = 5 * 1024 * 1024;
        private const int MemoryLines = 400;

        private readonly object _gate = new object();
        private readonly string _path;
        private readonly string _oldPath;
        private readonly LinkedList<string> _recent = new LinkedList<string>();

        public Logger(string path, string oldPath)
        {
            _path = path;
            _oldPath = oldPath;
            LoadRecent();
        }

        /// <summary>新日志产生时触发（可能来自后台线程）。</summary>
        public event Action<string> LineWritten;

        private void LoadRecent()
        {
            try
            {
                if (!File.Exists(_path)) { return; }
                var lines = new List<string>();
                using (var stream = new FileStream(_path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite))
                using (var reader = new StreamReader(stream, Encoding.UTF8))
                {
                    string line;
                    while ((line = reader.ReadLine()) != null)
                    {
                        lines.Add(line);
                        if (lines.Count > MemoryLines * 2) { lines.RemoveRange(0, MemoryLines); }
                    }
                }
                int start = Math.Max(0, lines.Count - MemoryLines);
                for (int i = start; i < lines.Count; i++) { _recent.AddLast(lines[i]); }
            }
            catch { }
        }

        public void Info(string message) { Write("INFO", message); }
        public void Warn(string message) { Write("WARN", message); }
        public void Error(string message) { Write("ERROR", message); }

        public void Write(string level, string message)
        {
            string line = AppPaths.FormatTime(DateTime.Now) + " [" + level + "] " + message;
            lock (_gate)
            {
                _recent.AddLast(line);
                while (_recent.Count > MemoryLines) { _recent.RemoveFirst(); }
                try
                {
                    Directory.CreateDirectory(Path.GetDirectoryName(_path));
                    RotateIfNeeded();
            File.AppendAllText(_path, line + Environment.NewLine, Json.Utf8WithBom);
                }
                catch { }
            }
            var handler = LineWritten;
            if (handler != null) { try { handler(line); } catch { } }
        }

        private void RotateIfNeeded()
        {
            var info = new FileInfo(_path);
            if (!info.Exists || info.Length < MaxBytes) { return; }
            if (File.Exists(_oldPath)) { File.Delete(_oldPath); }
            File.Move(_path, _oldPath);
        }

        public List<string> Recent(int count, bool warningsOnly)
        {
            var result = new List<string>();
            lock (_gate)
            {
                var node = _recent.Last;
                while (node != null && result.Count < count)
                {
                    if (!warningsOnly || node.Value.IndexOf("[WARN]", StringComparison.Ordinal) >= 0 ||
                        node.Value.IndexOf("[ERROR]", StringComparison.Ordinal) >= 0)
                    {
                        result.Insert(0, node.Value);
                    }
                    node = node.Previous;
                }
            }
            return result;
        }

        /// <summary>
        /// 清空日志：删除 login.log 与 login.log.old，并清掉内存缓存，最后留一行「日志已清空」。
        /// 界面上的「清空日志」按钮与 --clear-log 参数都走这里。
        /// </summary>
        public void Clear()
        {
            var problems = new List<string>();
            lock (_gate)
            {
                _recent.Clear();
                foreach (string path in new[] { _path, _oldPath })
                {
                    try
                    {
                        if (!File.Exists(path)) { continue; }
                        File.Delete(path);
                    }
                    catch
                    {
                        // 文件被别的程序打开着（例如正被记事本 / 另一个实例读）时删不掉，
                        // 退而求其次把内容截断成空文件，别让「清空日志」看起来生效了却留着旧内容。
                        try { File.WriteAllText(path, string.Empty, Json.Utf8WithBom); }
                        catch (Exception ex) { problems.Add(Path.GetFileName(path) + "（" + ex.Message + "）"); }
                    }
                }
            }
            Write("INFO", "日志已清空");
            foreach (string problem in problems)
            {
                Warn("清空日志时有文件没能处理干净：" + problem);
            }
        }

        public string TailText(int count)
        {
            var lines = Recent(count, false);
            return string.Join(Environment.NewLine, lines.ToArray());
        }
    }

    /// <summary>命令行模式下把输出接回调用方控制台（WinExe 默认没有控制台）。</summary>
    public static class ConsoleBridge
    {
        private const int AttachParentProcess = -1;
        private const int StdOutputHandle = -11;
        private const int StdErrorHandle = -12;

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool AttachConsole(int processId);

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool AllocConsole();

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern IntPtr GetStdHandle(int stdHandle);

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern uint GetFileType(IntPtr handle);

        private const uint FileTypeDisk = 1;
        private const uint FileTypePipe = 3;

        private static bool _ready;

        public static void Attach()
        {
            if (_ready) { return; }
            _ready = true;
            try
            {
                // 输出已被重定向（管道 / 文件）时直接沿用，避免被 AllocConsole 抢走
                if (!IsRedirected())
                {
                    if (!AttachConsole(AttachParentProcess)) { AllocConsole(); }
                }
                var stdout = new StreamWriter(Console.OpenStandardOutput()) { AutoFlush = true };
                Console.SetOut(stdout);
                var stderr = new StreamWriter(Console.OpenStandardError()) { AutoFlush = true };
                Console.SetError(stderr);
            }
            catch { }
        }

        private static bool IsRedirected()
        {
            try
            {
                foreach (int handle in new[] { StdOutputHandle, StdErrorHandle })
                {
                    uint type = GetFileType(GetStdHandle(handle));
                    if (type == FileTypeDisk || type == FileTypePipe) { return true; }
                }
            }
            catch { }
            return false;
        }

        public static void Line(string text)
        {
            try { Console.Out.WriteLine(text); } catch { }
        }
    }
}
