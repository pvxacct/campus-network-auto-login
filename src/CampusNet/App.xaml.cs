using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Threading;
using CampusNet.Core;
using CampusNet.UI;

namespace CampusNet
{
    public partial class App : Application
    {
        private const string MutexName = @"Local\CampusNet.SingleInstance";
        private const string SelfTestMutexName = @"Local\CampusNet.SelfTest";
        private const string ShowEventName = @"Local\CampusNet.ShowWindow";

        private Mutex _instanceMutex;
        private EventWaitHandle _showEvent;
        private Logger _log;
        private LoginEngine _engine;
        private TrayIcon _tray;
        private MainWindow _window;
        private bool _shuttingDown;

        protected override void OnStartup(StartupEventArgs e)
        {
            base.OnStartup(e);
            ShutdownMode = ShutdownMode.OnExplicitShutdown;
            InstallCrashGuards();
            string[] args = ApplyDataDirOverride(e.Args ?? new string[0]);
            string head = args.Length > 0 ? args[0].ToLowerInvariant() : string.Empty;

            try
            {
                switch (head)
                {
                    case "--version":
                    case "-v":
                        ConsoleBridge.Attach();
                        ConsoleBridge.Line(AppPaths.Version);
                        Shutdown(0);
                        return;
                    case "--cleanup-legacy":
                        Environment.ExitCode = LegacyCleanup.RunAsHelper(HasFlag(args, "--delete-legacy-data"));
                        Shutdown(Environment.ExitCode);
                        return;
                    case "--set-credentials":
                        SetCredentials(args);
                        return;
                    case "--install":
                        RunSimple("安装", delegate(Logger log) { SelfInstaller.Install(log, HasFlag(args, "--desktop-shortcut")); });
                        return;
                    case "--uninstall":
                        // --check-only：只打印卸载计划（删哪些文件、文件什么时候消失），不删任何东西。
                        if (HasFlag(args, "--check-only"))
                        {
                            ConsoleBridge.Attach();
                            ConsoleBridge.Line("卸载计划（未执行）：");
                            foreach (string line in SelfInstaller.DescribeUninstallPlan(HasFlag(args, "--delete-data"), true))
                            {
                                ConsoleBridge.Line(line);
                            }
                            Shutdown(0);
                            return;
                        }
                        RunSimple("卸载", delegate(Logger log)
                        {
                            UninstallResult result = SelfInstaller.Uninstall(log, HasFlag(args, "--delete-data"), true);
                            if (result.WasInstalled)
                            {
                                ConsoleBridge.Line(result.DeleteScheduled
                                    ? "程序文件将在本进程退出后被删除：" + AppPaths.InstalledExe
                                    : "程序文件没能排入删除，请手动删除：" + AppPaths.InstalledExe);
                            }
                        });
                        return;
                    case "--autostart":
                        RunSimple("开机自启", delegate(Logger log)
                        {
                            bool on = args.Length > 1 && args[1].Equals("on", StringComparison.OrdinalIgnoreCase);
                            SelfInstaller.SetAutoStart(on, log);
                        });
                        return;
                    case "--status":
                        PrintStatus();
                        return;
                    case "--diagnose":
                        PrintDiagnose(HasFlag(args, "--with-log"));
                        return;
                    case "--clear-log":
                        ClearLog();
                        return;
                    case "--watchdog":
                        Environment.ExitCode = Watchdog.Run(HasFlag(args, "--check-only"));
                        Shutdown(Environment.ExitCode);
                        return;
                    case "--watchdog-loop":
                        Environment.ExitCode = Watchdog.RunLoop();
                        Shutdown(Environment.ExitCode);
                        return;
                    case "--once":
                        RunHeadless(12, false);
                        return;
                    case "--run-seconds":
                        RunHeadless(ArgInt(args, 1, 15), false);
                        return;
                    case "--relogin":
                        RunHeadlessRelogin(ArgInt(args, 1, 120));
                        return;
                    case "--selftest":
                        StartUi(false, true);
                        return;
                    case "--tray":
                        StartUi(true, false);
                        return;
                    default:
                        StartUi(false, false);
                        return;
                }
            }
            catch (Exception ex)
            {
                ConsoleBridge.Attach();
                ConsoleBridge.Line("发生错误：" + ex.Message);
                Shutdown(1);
            }
        }

        // ---------------------------------------------------------------- 命令行模式

        private static string[] ApplyDataDirOverride(string[] rawArgs)
        {
            var cleaned = new List<string>();
            for (int i = 0; i < rawArgs.Length; i++)
            {
                if (rawArgs[i].Equals("--data-dir", StringComparison.OrdinalIgnoreCase) && i + 1 < rawArgs.Length)
                {
                    AppPaths.DataDirOverride = rawArgs[i + 1];
                    i++;
                    continue;
                }
                cleaned.Add(rawArgs[i]);
            }
            return cleaned.ToArray();
        }

        private static bool HasFlag(string[] args, string flag)
        {
            foreach (string arg in args)
            {
                if (string.Equals(arg, flag, StringComparison.OrdinalIgnoreCase)) { return true; }
            }
            return false;
        }

        private static int ArgInt(string[] args, int index, int fallback)
        {
            if (args.Length <= index) { return fallback; }
            int value;
            return int.TryParse(args[index], NumberStyles.Integer, CultureInfo.InvariantCulture, out value) ? value : fallback;
        }

        // ---------------------------------------------------------------- 稳定性兜底

        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = false)]
        private static extern int RegisterApplicationRestart(string commandLine, int flags);

        /// <summary>崩溃后由 Windows 直接把它拉回来（命令行固定为 --tray），不必等人发现。</summary>
        private static void EnableAutoRestart()
        {
            try { RegisterApplicationRestart("--tray", 0); } catch { }
        }

        /// <summary>
        /// 任何一层未处理异常都不允许让后台「无声消失」：
        /// 界面线程异常吞掉并记日志（程序继续跑），后台线程异常至少留下 crash.log 给下次排查。
        /// </summary>
        private void InstallCrashGuards()
        {
            DispatcherUnhandledException += delegate(object sender, DispatcherUnhandledExceptionEventArgs e)
            {
                e.Handled = true;
                WriteCrash("界面线程未处理异常（已忽略，程序继续运行）", e.Exception);
                try { if (_log != null) { _log.Error("界面线程未处理异常（已忽略）：" + e.Exception.Message); } } catch { }
            };
            AppDomain.CurrentDomain.UnhandledException += delegate(object sender, UnhandledExceptionEventArgs e)
            {
                WriteCrash("后台线程未处理异常（进程即将退出）", e.ExceptionObject as Exception);
            };
            TaskScheduler.UnobservedTaskException += delegate(object sender, UnobservedTaskExceptionEventArgs e)
            {
                e.SetObserved();
                WriteCrash("未观察的任务异常（已忽略）", e.Exception);
            };
        }

        private static void WriteCrash(string title, Exception ex)
        {
            try
            {
                AppPaths.EnsureDataDir();
                var builder = new StringBuilder();
                builder.AppendLine("===== " + AppPaths.FormatTime(DateTime.Now) + " =====");
                builder.AppendLine(title);
                builder.AppendLine("版本：" + AppPaths.Version);
                builder.AppendLine("命令行：" + (Environment.CommandLine ?? string.Empty));
                builder.AppendLine(ex == null ? "（没有异常对象）" : ex.ToString());
                File.AppendAllText(AppPaths.CrashFile, builder.ToString(), new UTF8Encoding(true));
            }
            catch { }
        }

        private Logger CreateLogger()
        {
            AppPaths.EnsureDataDir();
            if (!System.IO.File.Exists(AppPaths.ConfigFile))
            {
                try { new AppConfig().Save(AppPaths.ConfigFile); } catch { }
            }
            return new Logger(AppPaths.LogFile, AppPaths.LogOldFile);
        }

        private void SetCredentials(string[] args)
        {
            ConsoleBridge.Attach();
            string user = args.Length > 1 ? (args[1] ?? string.Empty).Trim() : string.Empty;
            if (string.IsNullOrEmpty(user) || user.StartsWith("--", StringComparison.Ordinal))
            {
                ConsoleBridge.Line("用法：CampusNet.exe --set-credentials <账号> [--password-stdin]");
                ConsoleBridge.Line("  · 加 --password-stdin（或把密码用管道送进来）时，从标准输入读一行；");
                ConsoleBridge.Line("  · 不加时会在控制台提示输入密码，输入不回显；");
                ConsoleBridge.Line("  · 密码不再接受命令行参数（会留在 PowerShell 历史 / 进程列表 / 审计日志里）。");
                Shutdown(2);
                return;
            }

            // 老写法 --set-credentials <账号> <密码>：直接拒绝，并提示改用安全写法。
            if (args.Length > 2 && !args[2].StartsWith("--", StringComparison.Ordinal))
            {
                ConsoleBridge.Line("已拒绝：密码不能写在命令行里（会留在 PowerShell 历史、进程列表和审计日志中）。");
                ConsoleBridge.Line("请改用： CampusNet.exe --set-credentials " + user + " --password-stdin");
                ConsoleBridge.Line("       或打开图形界面 → 填写账号密码 → 保存。");
                Shutdown(2);
                return;
            }

            string password = ReadPassword(HasFlag(args, "--password-stdin"));
            if (string.IsNullOrEmpty(password))
            {
                ConsoleBridge.Line("没有读到密码，已取消（账号未改动）。");
                Shutdown(2);
                return;
            }
            AppPaths.EnsureDataDir();
            CredentialStore.Save(AppPaths.CredentialFile, user, password);
            Redact.SetSecrets(user, password);
            ConsoleBridge.Line("账号已保存（DPAPI 加密，仅当前 Windows 用户可解密）。");
            Shutdown(0);
        }

        /// <summary>
        /// 读密码：加 --password-stdin（或输入被重定向）时从标准输入读一行；
        /// 否则在控制台里提示输入并且不回显。
        /// </summary>
        private static string ReadPassword(bool stdin)
        {
            if (stdin)
            {
                try { return (Console.In.ReadLine() ?? string.Empty).Trim(); }
                catch { return string.Empty; }
            }

            try
            {
                ConsoleBridge.Line("请输入密码（输入不回显，回车确认；直接回车 = 取消）：");
                var builder = new StringBuilder();
                while (true)
                {
                    ConsoleKeyInfo key = Console.ReadKey(true);
                    if (key.Key == ConsoleKey.Enter) { Console.WriteLine(); break; }
                    if (key.Key == ConsoleKey.Backspace)
                    {
                        if (builder.Length > 0) { builder.Length--; Console.Write("\b \b"); }
                        continue;
                    }
                    if (char.IsControl(key.KeyChar)) { continue; }
                    builder.Append(key.KeyChar);
                    Console.Write('*');
                }
                return builder.ToString();
            }
            catch
            {
                // 没有可交互的控制台（例如管道输入）：退回标准输入读一行
                try { return (Console.In.ReadLine() ?? string.Empty).Trim(); }
                catch { return string.Empty; }
            }
        }

        private void RunSimple(string label, Action<Logger> action)
        {
            ConsoleBridge.Attach();
            Logger log = CreateLogger();
            try
            {
                action(log);
                ConsoleBridge.Line(label + "完成。");
                Shutdown(0);
            }
            catch (Exception ex)
            {
                ConsoleBridge.Line(label + "失败：" + ex.Message);
                Shutdown(1);
            }
        }

        private void PrintStatus()
        {
            ConsoleBridge.Attach();
            AppConfig config = AppConfig.Load(AppPaths.ConfigFile);
            AppState state = AppState.Load(AppPaths.StateFile);
            LegacyReport legacy = LegacyCleanup.Detect();
            ConsoleBridge.Line("状态：" + Describe(state.LastResult) + "（" + state.LastResult + "）");
            ConsoleBridge.Line("在线：" + (state.Online ? "是" : "否"));
            ConsoleBridge.Line("最近探测：" + Text(state.LastProbe) + Age(state.LastProbe));
            ConsoleBridge.Line("最近登录：" + Text(state.LastLoginSuccess));
            ConsoleBridge.Line("今日登录：确认成功 " + state.TodaySuccess(DateTime.Now) + " 次 / 提交 "
                + state.TodayAttempts(DateTime.Now) + " 次（" + AppState.TodayKey(DateTime.Now) + "）");
            ConsoleBridge.Line("连续失败：" + state.ConsecutiveFailures + "；本小时登录 " + state.LoginWindowCount + " 次");
            ConsoleBridge.Line("风控：" + "最小间隔 " + config.LoginMinIntervalSeconds + " 秒；每小时上限 "
                + config.LoginHourlyLimit + " 次");
            ConsoleBridge.Line("暂停：" + (state.Paused ? "是" : "否"));
            ConsoleBridge.Line("会话核对：" + (string.IsNullOrEmpty(state.LastSessionCheck)
                ? "尚未核对"
                : state.LastSessionCheck + "（" + SessionText(state.LastSessionResult)
                  + (string.IsNullOrEmpty(state.LastSessionCheckKind) ? string.Empty : " · " + SessionKindText(state.LastSessionCheckKind)) + "）")
                + "；间隔 " + (config.SessionCheckSeconds > 0 ? config.SessionCheckSeconds + " 秒" : "关闭"));
            ConsoleBridge.Line("开机自启：" + (SelfInstaller.IsAutoStartEnabled ? "已开启" : "已关闭"));
            ConsoleBridge.Line("守护      ：" + (SelfInstaller.IsWatchdogInstalled
                ? "已开启（守护进程每 " + Watchdog.LoopIntervalSeconds + " 秒检查一次）"
                : "未开启（崩溃后不会自动回来）"));
            ConsoleBridge.Line("已忽略提示：" + state.IgnoredPrompts + " 次"
                + (string.IsNullOrEmpty(state.LastIgnoredPrompt) ? string.Empty : "；最近：" + state.LastIgnoredPrompt));
            ConsoleBridge.Line("强制重登  ：" + (string.IsNullOrEmpty(state.LastForcedRelogin) ? "尚未发生" : state.LastForcedRelogin));
            ConsoleBridge.Line("Portal：" + config.PortalBase + config.StatusPath);
            if (config.Corrupted)
            {
                ConsoleBridge.Line("配置      ：已损坏（" + config.CorruptedReason + "）——已停止自动登录");
            }
            ConsoleBridge.Line("旧版残留：" + legacy.Describe());
            Shutdown(0);
        }

        private void PrintDiagnose(bool withLog)
        {
            ConsoleBridge.Attach();
            AppPaths.EnsureDataDir();
            Logger log = new Logger(AppPaths.LogFile, AppPaths.LogOldFile);
            var engine = new LoginEngine(log);
            engine.PrimeForDisplay();
            ConsoleBridge.Line(Diagnostics.Build(engine, log, withLog));
            Shutdown(0);
        }

        private void ClearLog()
        {
            ConsoleBridge.Attach();
            AppPaths.EnsureDataDir();
            var log = new Logger(AppPaths.LogFile, AppPaths.LogOldFile);
            log.Clear();
            ConsoleBridge.Line("日志已清空：" + AppPaths.LogFile);
            Shutdown(0);
        }

        private void RunHeadless(int seconds, bool relogin)
        {
            ConsoleBridge.Attach();
            AppPaths.EnsureDataDir();
            Logger log = CreateLogger();
            log.Info("命令行模式启动（" + (relogin ? "立即重连" : "单次检查") + "，运行 " + seconds + " 秒）。");
            var engine = new LoginEngine(log);
            engine.Start();
            if (relogin) { engine.Relogin(); }
            var deadline = DateTime.Now.AddSeconds(seconds);
            while (DateTime.Now < deadline) { Thread.Sleep(250); }
            EngineSnapshot snapshot = engine.Snapshot();
            engine.Dispose();
            ConsoleBridge.Line("状态：" + snapshot.StatusText);
            ConsoleBridge.Line("结果：" + snapshot.LastResult);
            ConsoleBridge.Line("在线：" + (snapshot.Online ? "是" : "否"));
            ConsoleBridge.Line("探测：" + snapshot.ProbeSummary);
            ConsoleBridge.Line("延迟：" + (snapshot.LatencyMs < 0 ? "未知" : snapshot.LatencyMs + " ms") + "；丢包：" + snapshot.LossPercent + "%");
            ConsoleBridge.Line("本小时登录：" + snapshot.LoginWindowCount + "；连续失败：" + snapshot.ConsecutiveFailures);
            ConsoleBridge.Line("今日登录：" + snapshot.DayLoginSuccess + " 次成功 / " + snapshot.DayLoginAttempts + " 次提交");
            ConsoleBridge.Line("恢复耗时：" + (snapshot.LastRecoverySeconds < 0
                ? "本次进程还没有成功样本"
                : "最近 " + snapshot.LastRecoverySeconds + " 秒；本次中位 " + snapshot.RecoveryMedianSeconds + " 秒"));
            ConsoleBridge.Line("累计检查：" + snapshot.RunCount);
            Shutdown(0);
        }

        /// <summary>
        /// --relogin：注销后重新登录，并且**等这一轮流程真正跑完**再退出。
        /// 老写法固定跑 25 秒，注销成功、等待 3 秒后就退出了，登录请求根本没提交 —— 账号会停在已注销状态。
        /// 现在用评估编号判断：等到「调用 Relogin 之后开始的那一轮」结束（Busy=false）为止，最多等 maxSeconds 秒。
        /// </summary>
        private void RunHeadlessRelogin(int maxSeconds)
        {
            ConsoleBridge.Attach();
            AppPaths.EnsureDataDir();
            Logger log = CreateLogger();
            int budget = Math.Max(10, maxSeconds);
            log.Info("命令行模式启动（立即重连，等待流程跑完，最长 " + budget + " 秒）。");
            var engine = new LoginEngine(log);
            engine.Start();
            long startId = engine.Snapshot().EvaluationId;
            engine.Relogin();

            var deadline = DateTime.Now.AddSeconds(budget);
            bool completed = false;
            while (DateTime.Now < deadline)
            {
                EngineSnapshot current = engine.Snapshot();
                if (current.EvaluationId > startId && !current.Busy) { completed = true; break; }
                Thread.Sleep(200);
            }

            EngineSnapshot snapshot = engine.Snapshot();
            engine.Dispose();
            if (!completed)
            {
                ConsoleBridge.Line("警告：等待 " + budget + " 秒仍未跑完（可能正在按最小间隔等待下一轮），当前状态如下。");
            }
            ConsoleBridge.Line("状态：" + snapshot.StatusText);
            ConsoleBridge.Line("结果：" + snapshot.LastResult);
            ConsoleBridge.Line("在线：" + (snapshot.Online ? "是" : "否"));
            ConsoleBridge.Line("探测：" + snapshot.ProbeSummary);
            ConsoleBridge.Line("延迟：" + (snapshot.LatencyMs < 0 ? "未知" : snapshot.LatencyMs + " ms") + "；丢包：" + snapshot.LossPercent + "%");
            ConsoleBridge.Line("本小时登录：" + snapshot.LoginWindowCount + "；连续失败：" + snapshot.ConsecutiveFailures);
            ConsoleBridge.Line("累计检查：" + snapshot.RunCount);
            Shutdown(0);
        }

        private static string Describe(string key)
        {
            switch (key)
            {
                case "online": return "网络正常";
                case "login-ok": return "自动登录成功";
                case "login-unconfirmed": return "登录已提交，等待确认";
                case "login-wait": return "等待下次登录";
                case "login-throttled": return "已触发频率上限";
                case "verifying": return "正在核对网络状态";
                case "tcp-only": return "只有 TCP 握手通过";
                case "session-check": return "正在核对 Portal 会话";
                case "offline-detected": return "检测到已离线";
                case "paused": return "已暂停";
                case "no-credential": return "未保存账号";
                case "unreachable": return "无法连接校园网";
                case "login-failed": return "登录失败";
                case "login-retry": return "登录提示已忽略，正在重试";
                case "upstream": return "上游异常";
                case "config-invalid": return "配置文件损坏，已停止登录";
                case "probe-config": return "探测目标配置无效，已停止登录";
                default: return key;
            }
        }

        private static string Text(string value)
        {
            return string.IsNullOrEmpty(value) ? "—" : value;
        }

        private static string SessionText(string key)
        {
            switch (key)
            {
                case "online": return "Portal 显示在线";
                case "offline": return "Portal 显示已离线";
                case "unreachable": return "Portal 不可达";
                default: return string.IsNullOrEmpty(key) ? "—" : key;
            }
        }

        /// <summary>会话核对的来源：定时巡检 / 疑似掉线核对。</summary>
        private static string SessionKindText(string kind)
        {
            switch (kind)
            {
                case "periodic": return "定时巡检";
                case "suspect": return "疑似掉线核对";
                default: return string.Empty;
            }
        }

        private static string Age(string value)
        {
            DateTime? time = AppPaths.ParseTime(value);
            if (!time.HasValue) { return string.Empty; }
            TimeSpan span = DateTime.Now - time.Value;
            if (span.TotalSeconds < 0) { return string.Empty; }
            if (span.TotalMinutes < 1) { return "（" + (int)span.TotalSeconds + " 秒前）"; }
            if (span.TotalHours < 1) { return "（" + (int)span.TotalMinutes + " 分钟前）"; }
            return "（" + (int)span.TotalHours + " 小时前）";
        }

        // ---------------------------------------------------------------- 界面模式

        private void StartUi(bool startHidden, bool selfTest)
        {
            bool createdNew;
            // 自检模式用另一个互斥体名字：它只活几秒、只读多看少写，
            // 不该因为「托盘里已经有一个实例」就悄悄跳过检查，也不该干扰守护的存活判断。
            _instanceMutex = new Mutex(true, selfTest ? SelfTestMutexName : MutexName, out createdNew);
            if (!createdNew && !selfTest)
            {
                try
                {
                    EventWaitHandle handle = EventWaitHandle.OpenExisting(ShowEventName);
                    handle.Set();
                }
                catch { }
                Shutdown(0);
                return;
            }

            _log = CreateLogger();
            EnableAutoRestart();
            _log.Info("程序启动：" + AppPaths.Version + "，" + (startHidden ? "托盘后台模式" : "主窗口模式")
                + "，数据目录 " + AppPaths.DataDir);
            // 守护进程：独立于本进程，主程序崩溃或卡死时由它拉起来（不需要管理员权限）
            Watchdog.ResetIntent();
            Watchdog.EnsureRunning(_log);
            _engine = new LoginEngine(_log);
            _engine.StatusChanged += OnEngineStatusChanged;
            _engine.Start();

            _tray = new TrayIcon(_engine.Config.ShowBalloon);
            _tray.OpenRequested += ShowWindow;
            _tray.ReloginRequested += delegate { _engine.Relogin(); ShowWindow(); };
            _tray.PauseRequested += delegate { _engine.Pause(TimeSpan.FromMinutes(30)); };
            _tray.ResumeRequested += delegate { _engine.Resume(); };
            _tray.ExitRequested += delegate { RequestExit(); };

            _window = new MainWindow(_engine, _log, _tray);
            WatchForShowRequest();

            if (startHidden && !selfTest)
            {
                _tray.ShowBalloon(AppPaths.DisplayName, "已在后台运行，网络异常时会自动登录。");
            }
            else
            {
                _window.Show();
                _window.Activate();
            }

            if (selfTest)
            {
                var timer = new System.Windows.Threading.DispatcherTimer();
                timer.Interval = TimeSpan.FromSeconds(3);
                timer.Tick += delegate
                {
                    timer.Stop();
                    ConsoleBridge.Attach();
                    bool ok = TraySelfTest();
                    ConsoleBridge.Line(ok
                        ? "界面自检通过：窗口已构建、完成一次刷新，托盘提示文本安全。"
                        : "界面自检失败：托盘提示文本没有被压缩到安全长度。");
                    Environment.ExitCode = ok ? 0 : 1;
                    Shutdown(Environment.ExitCode);
                };
                timer.Start();
            }
        }

        /// <summary>
        /// 回归用例：超长状态文本（例如「自动登录失败：账号已在别处在线…」）曾经把托盘打成
        /// ArgumentOutOfRangeException 并让整个后台进程消失，这里必须压到 63 字符以内。
        /// </summary>
        private bool TraySelfTest()
        {
            if (_tray == null) { return false; }
            string stress = new string('测', 200)
                + "自动登录失败：账号已在别处在线（Portal 提示：Msg=01, userid error2 -> 密码错误），本机复检仍不在线";
            _tray.Update("login-failed", stress, false);
            int length = _tray.LastTooltip == null ? -1 : _tray.LastTooltip.Length;
            ConsoleBridge.Line("托盘自检：状态文本 " + stress.Length + " 字 → 托盘提示 " + length
                + " 字（上限 " + TrayIcon.MaxTooltipChars + "）。");
            return length > 0 && length <= TrayIcon.MaxTooltipChars;
        }

        private void WatchForShowRequest()
        {
            bool created;
            _showEvent = new EventWaitHandle(false, EventResetMode.AutoReset, ShowEventName, out created);
            var thread = new Thread(delegate()
            {
                while (!_shuttingDown)
                {
                    try
                    {
                        if (!_showEvent.WaitOne(1000)) { continue; }
                        Dispatcher.BeginInvoke(new Action(ShowWindow));
                    }
                    catch { return; }
                }
            });
            thread.IsBackground = true;
            thread.Start();
        }

        private void OnEngineStatusChanged(EngineSnapshot snapshot)
        {
            if (_tray == null) { return; }
            try
            {
                Dispatcher.BeginInvoke(new Action(delegate
                {
                    _tray.Update(snapshot.StatusKey, snapshot.StatusText, snapshot.Paused);
                    if (snapshot.StatusKey == "login-ok") { _tray.ShowBalloon("已自动登录", "校园网连接已恢复。"); }
                    else if (snapshot.StatusKey == "unreachable") { _tray.ShowBalloon("网络异常", "当前无法连接校园网，正在持续重试。"); }
                }));
            }
            catch { }
        }

        private void ShowWindow()
        {
            if (_window == null) { return; }
            if (!_window.IsVisible) { _window.Show(); }
            if (_window.WindowState == WindowState.Minimized) { _window.WindowState = WindowState.Normal; }
            _window.Activate();
            _window.Topmost = true;
            _window.Topmost = false;
        }

        public void RequestExit()
        {
            MessageBoxResult answer = MessageBox.Show(
                "退出后，网络断开时不会再自动登录，需要手动重新打开。\n\n确定要退出吗？",
                AppPaths.DisplayName, MessageBoxButton.YesNo, MessageBoxImage.Question);
            if (answer != MessageBoxResult.Yes) { return; }

            ShutdownForUser(0);
        }

        /// <summary>
        /// 卸载后的退出：不再问一次（卸载本身已经确认过），但按「用户主动退出」处理——
        /// 停守护、释放单实例互斥体，最关键的是让本进程真的退出，
        /// 否则正在运行的 exe 删不掉，「已卸载」就成了假话。
        /// </summary>
        public void ExitAfterUninstall()
        {
            ShutdownForUser(0);
        }

        private void ShutdownForUser(int exitCode)
        {
            _shuttingDown = true;
            if (_window != null) { _window.AllowClose(); }
            if (_tray != null) { _tray.Dispose(); _tray = null; }
            if (_engine != null) { _engine.Dispose(); _engine = null; }
            // 用户主动退出：让守护进程也停下来，不然它过 30 秒又把程序拉起来
            Watchdog.SignalIntent();
            if (_showEvent != null) { try { _showEvent.Close(); } catch { } }
            if (_instanceMutex != null) { try { _instanceMutex.ReleaseMutex(); } catch { } }
            Shutdown(exitCode);
        }
    }
}
