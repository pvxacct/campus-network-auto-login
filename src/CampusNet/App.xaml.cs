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
                        RunSimple("卸载", delegate(Logger log)
                        {
                            SelfInstaller.Uninstall(log, HasFlag(args, "--delete-data"), true);
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
                        RunHeadless(ArgInt(args, 1, 25), true);
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
            if (args.Length < 3)
            {
                ConsoleBridge.Line("用法：CampusNet.exe --set-credentials <账号> <密码>");
                Shutdown(2);
                return;
            }
            AppPaths.EnsureDataDir();
            CredentialStore.Save(AppPaths.CredentialFile, args[1], args[2]);
            ConsoleBridge.Line("账号已保存（DPAPI 加密，仅当前 Windows 用户可解密）。");
            Shutdown(0);
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
            ConsoleBridge.Line("连续失败：" + state.ConsecutiveFailures + "；本小时登录 " + state.LoginWindowCount + " 次");
            ConsoleBridge.Line("风控：" + "最小间隔 " + config.LoginMinIntervalSeconds + " 秒；每小时上限 "
                + config.LoginHourlyLimit + " 次");
            ConsoleBridge.Line("暂停：" + (state.Paused ? "是" : "否"));
            ConsoleBridge.Line("会话核对：" + (string.IsNullOrEmpty(state.LastSessionCheck)
                ? "尚未核对"
                : state.LastSessionCheck + "（" + SessionText(state.LastSessionResult) + "）")
                + "；间隔 " + (config.SessionCheckSeconds > 0 ? config.SessionCheckSeconds + " 秒" : "关闭"));
            ConsoleBridge.Line("开机自启：" + (SelfInstaller.IsAutoStartEnabled ? "已开启" : "已关闭"));
            ConsoleBridge.Line("守护      ：" + (SelfInstaller.IsWatchdogInstalled
                ? "已开启（守护进程每 " + Watchdog.LoopIntervalSeconds + " 秒检查一次）"
                : "未开启（崩溃后不会自动回来）"));
            ConsoleBridge.Line("已忽略提示：" + state.IgnoredPrompts + " 次"
                + (string.IsNullOrEmpty(state.LastIgnoredPrompt) ? string.Empty : "；最近：" + state.LastIgnoredPrompt));
            ConsoleBridge.Line("强制重登  ：" + (string.IsNullOrEmpty(state.LastForcedRelogin) ? "尚未发生" : state.LastForcedRelogin));
            ConsoleBridge.Line("Portal：" + config.PortalHost + config.StatusPath);
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
            ConsoleBridge.Line("累计检查：" + snapshot.RunCount);
            Shutdown(0);
        }

        private static string Describe(string key)
        {
            switch (key)
            {
                case "online": return "网络正常";
                case "login-ok": return "自动登录成功";
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

            _shuttingDown = true;
            if (_window != null) { _window.AllowClose(); }
            if (_tray != null) { _tray.Dispose(); _tray = null; }
            if (_engine != null) { _engine.Dispose(); _engine = null; }
            // 用户主动退出：让守护进程也停下来，不然它过 30 秒又把程序拉起来
            Watchdog.SignalIntent();
            if (_showEvent != null) { try { _showEvent.Close(); } catch { } }
            if (_instanceMutex != null) { try { _instanceMutex.ReleaseMutex(); } catch { } }
            Shutdown(0);
        }
    }
}
