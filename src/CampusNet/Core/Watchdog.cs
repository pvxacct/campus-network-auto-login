using System;
using System.Diagnostics;
using System.IO;
using System.Text;
using System.Threading;

namespace CampusNet.Core
{
    /// <summary>
    /// 守护：由计划任务每 2 分钟唤起一次，检查主程序是不是还活着
    /// （既看进程在不在，也看引擎心跳新不新鲜），不在或卡死就把它重新拉起来。
    ///
    /// 这是最后一道保险：程序崩溃时 Windows 还会通过 RegisterApplicationRestart 立刻重启一次，
    /// 但「崩溃后一直没人管」「进程在、引擎假死」这两种情况只能靠它兜住。
    /// </summary>
    public static class Watchdog
    {
        public const string MutexName = @"Local\CampusNet.SingleInstance";
        /// <summary>守护进程自己的互斥体：保证同一时间只有一个守护。</summary>
        public const string LoopMutexName = @"Local\CampusNet.Watchdog";
        /// <summary>「用户主动退出」信号：置位后守护不再拉起主程序，而是自己退出。</summary>
        public const string IntentionalExitEventName = @"Local\CampusNet.IntentionalExit";
        /// <summary>state.json 里的最近触发时间超过这个秒数（且没有正在进行的登录）就认为引擎卡死。</summary>
        public const int StaleSeconds = 180;
        /// <summary>动态阈值的上限：再怎么算也不能无限等下去。</summary>
        public const int MaxStaleSeconds = 900;
        /// <summary>守护进程的检查间隔。</summary>
        public const int LoopIntervalSeconds = 30;
        private const int RestartCooldownSeconds = 15;
        private const int FastCrashSeconds = 90;
        private const int FastCrashLimit = 3;
        private const int SlowIntervalSeconds = 300;
        private const long MaxLogBytes = 64 * 1024;

        /// <summary>检查并（必要时）自愈。返回进程退出码：0 = 正常/已拉起，1 = 出了点问题。</summary>
        public static int Run(bool checkOnly)
        {
            string detail;
            string decision = Decide(out detail);

            if (checkOnly)
            {
                ConsoleBridge.Attach();
                ConsoleBridge.Line(decision + "：" + detail);
                ConsoleBridge.Line("卡死阈值：" + EffectiveStaleSeconds() + " 秒（按当前配置的重试次数与超时算出，默认 "
                    + StaleSeconds + " 秒，上限 " + MaxStaleSeconds + " 秒）");
                ConsoleBridge.Line("重启命令：" + MainCommandLine(ResolveExe()));
                return decision == "alive" ? 0 : (decision == "stale" ? 1 : 2);
            }

            if (decision == "alive") { return 0; }

            string label = decision == "stale" ? "重启" : "拉起";
            Log("判定 " + decision + "（" + detail + "）→ " + label);
            if (decision == "stale")
            {
                KillMainInstances();
                Thread.Sleep(1500);
            }
            bool started = StartMainInstance();
            Log(started ? "已" + label + "主程序（--tray）" : "启动主程序失败，请手动打开一次");
            return started ? 0 : 1;
        }

        // ---------------------------------------------------------------- 常驻守护进程

        /// <summary>守护进程是否正在运行。</summary>
        public static bool IsRunning
        {
            get
            {
                try
                {
                    using (Mutex probe = Mutex.OpenExisting(LoopMutexName)) { return probe != null; }
                }
                catch { return false; }
            }
        }

        /// <summary>
        /// 守护进程主循环：每 30 秒确认一次「主程序还在、引擎还有心跳」，
        /// 不在就把它拉起来，卡死就结束它再拉起来。只有用户主动退出（托盘 → 退出 / 卸载）
        /// 才会收到信号并自己退出。
        /// </summary>
        public static int RunLoop()
        {
            bool createdNew;
            using (var guard = new Mutex(true, LoopMutexName, out createdNew))
            {
                if (!createdNew) { return 0; }   // 已经有一个守护在跑，直接退出

                EventWaitHandle stop = null;
                try { stop = new EventWaitHandle(false, EventResetMode.AutoReset, IntentionalExitEventName); }
                catch { }

                Log("守护进程启动（PID " + Process.GetCurrentProcess().Id + "，每 " + LoopIntervalSeconds + " 秒检查一次）");
                int fastCrashes = 0;
                // 降速后的节奏必须跨轮保留：以前 wait 在循环里被重新赋值为 LoopIntervalSeconds，
                // 于是「放慢到 300 秒」从来没能生效，一直在按 30 秒拉起崩溃的程序。
                int wait = LoopIntervalSeconds;
                DateTime? lastStart = null;
                while (true)
                {
                    // 先等一轮再检查：守护总是由活着的主程序启动的，刚启动时立刻判定没有意义
                    // （主程序可能还没来得及写第一份 state.json）；等待期间也随时响应「主动退出」。
                    if (stop == null)
                    {
                        Thread.Sleep(TimeSpan.FromSeconds(wait));
                    }
                    else if (stop.WaitOne(TimeSpan.FromSeconds(wait)))
                    {
                        Log("收到「主动退出」信号，守护进程退出");
                        return 0;
                    }

                    try
                    {
                        string detail;
                        string decision = Decide(out detail);
                        if (decision != "alive")
                        {
                            bool quick = lastStart.HasValue
                                && (DateTime.Now - lastStart.Value).TotalSeconds < FastCrashSeconds;
                            fastCrashes = quick ? fastCrashes + 1 : 0;
                            if (fastCrashes >= FastCrashLimit && wait != SlowIntervalSeconds)
                            {
                                wait = SlowIntervalSeconds;
                                Log("短时间内已第 " + fastCrashes + " 次拉起，放慢到每 " + SlowIntervalSeconds + " 秒一次");
                            }
                            bool restart = decision == "stale";
                            Log("判定 " + decision + "（" + detail + "）→ " + (restart ? "重启" : "拉起"));
                            if (restart)
                            {
                                KillMainInstances();
                                Thread.Sleep(1500);
                            }
                            if (StartMainInstance())
                            {
                                lastStart = DateTime.Now;
                                Log("已" + (restart ? "重启" : "拉起") + "主程序（--tray）");
                            }
                            else
                            {
                                Log("拉起失败，等下一轮再试");
                            }
                        }
                        else if (wait != LoopIntervalSeconds)
                        {
                            wait = LoopIntervalSeconds;
                            fastCrashes = 0;
                            Log("主程序恢复正常，守护节奏回到每 " + LoopIntervalSeconds + " 秒一次");
                        }
                    }
                    catch (Exception ex)
                    {
                        Log("检查出错（已忽略）：" + ex.Message);
                    }
                }
            }
        }

        /// <summary>主程序启动时清掉「主动退出」标记，让守护重新开始看守。</summary>
        public static void ResetIntent()
        {
            try
            {
                EventWaitHandle handle;
                if (EventWaitHandle.TryOpenExisting(IntentionalExitEventName, out handle))
                {
                    using (handle) { handle.Reset(); }
                }
            }
            catch { }
        }

        /// <summary>告诉守护「这次是用户主动退出，别再拉起来」。</summary>
        public static void SignalIntent()
        {
            try
            {
                EventWaitHandle handle;
                if (EventWaitHandle.TryOpenExisting(IntentionalExitEventName, out handle))
                {
                    using (handle) { handle.Set(); }
                }
                else
                {
                    using (var created = new EventWaitHandle(false, EventResetMode.AutoReset, IntentionalExitEventName))
                    {
                        created.Set();
                    }
                }
            }
            catch { }
        }

        /// <summary>确保守护进程在跑（不在就拉起一个独立的 --watchdog-loop）。</summary>
        public static bool EnsureRunning(Logger log)
        {
            if (IsRunning) { return true; }
            try
            {
                string exe = ResolveExe();
                var info = new ProcessStartInfo(exe, "--watchdog-loop" + DataDirArgument());
                // UseShellExecute：让守护成为独立进程，主程序退出/崩溃都不会带走它
                info.UseShellExecute = true;
                info.WorkingDirectory = Path.GetDirectoryName(exe);
                Process.Start(info);
                Log("已启动守护进程：" + exe + " --watchdog-loop" + DataDirArgument());
                if (log != null)
                {
                    log.Info("守护进程已启动（每 " + LoopIntervalSeconds + " 秒检查一次，主程序崩溃或卡死会自动拉起）。");
                }
                return true;
            }
            catch (Exception ex)
            {
                Log("启动守护进程失败：" + ex.Message);
                if (log != null) { log.Warn("守护进程启动失败：" + ex.Message + "（自动登录本身不受影响）"); }
                return false;
            }
        }

        /// <summary>停止守护：信号发出后它会在几秒内自己退出。</summary>
        public static void Stop(Logger log)
        {
            if (!IsRunning) { return; }
            SignalIntent();
            if (log != null) { log.Info("已通知守护进程退出。"); }
        }

        /// <summary>alive = 进程在且心跳新鲜；stale = 进程在但引擎卡死；dead = 进程不在。</summary>
        public static string Decide(out string detail)
        {
            if (!IsMainInstanceRunning())
            {
                detail = "没有检测到运行中的主程序";
                return "dead";
            }

            DateTime? heartbeat = ReadHeartbeat();
            if (!heartbeat.HasValue)
            {
                detail = "状态文件缺少最近触发时间";
                return "stale";
            }

            int limit = EffectiveStaleSeconds();
            double age = (DateTime.Now - heartbeat.Value).TotalSeconds;
            if (age > limit)
            {
                detail = "引擎已经 " + (int)age + " 秒没有动静（阈值 " + limit + " 秒）";
                return "stale";
            }
            detail = "最近一次检查在 " + (int)Math.Max(0, age) + " 秒前（阈值 " + limit + " 秒）";
            return "alive";
        }

        /// <summary>
        /// 「卡死」阈值不能永远是 180 秒：把 RetryCount 调大后，一次登录流程本身就可能超过 180 秒
        /// （每次提交都要等登录超时 + 状态查询超时），守护会把正在登录的进程杀掉重启，
        /// 反而让网络更久不能恢复。这里按当前配置算出「一轮评估最多能花多久」，再加 90 秒余量，
        /// 并夹在 [180, 900] 秒之间；引擎在登录流程里也会强制刷新心跳，两边互为保险。
        /// </summary>
        public static int EffectiveStaleSeconds()
        {
            int budgetSeconds = 0;
            try
            {
                AppConfig config = AppConfig.Load(AppPaths.ConfigFile);
                if (!config.Corrupted)
                {
                    // 探测：并行的每一轮约等于单条目标超时，复检 N 轮 + 内容补测两轮
                    int perProbeMs = Math.Max(500, Math.Max(config.HttpProbeTimeoutMs, config.ProbeTimeoutMs)) + 1500;
                    int probeRounds = Math.Max(1, config.ConfirmAttempts) + 2;
                    // 登录：每次提交 = 登录超时 + 状态查询超时 + 登录前二次确认 + 3 秒短窗
                    // + 30 秒密集复检窗口（2.1.3-pre.1 起，每次提交都要跑满它）。
                    int perAttemptSeconds = Math.Max(1, config.LoginTimeoutSec)
                        + Math.Max(1, config.StatusTimeoutSec)
                        + Math.Max(0, config.LoginConfirmDelaySec)
                        + LoginEngine.RecoveryShortWatchSeconds
                        + LoginEngine.RecoveryWatchSeconds;
                    int loginSeconds = Math.Max(1, config.RetryCount) * perAttemptSeconds;
                    budgetSeconds = (probeRounds * perProbeMs) / 1000
                        + loginSeconds
                        + (Math.Max(0, config.ConfirmGapMs) / 1000) + 1;
                }
            }
            catch { }
            int value = Math.Max(StaleSeconds, budgetSeconds + 90);
            return Math.Min(MaxStaleSeconds, value);
        }

        private static bool IsMainInstanceRunning()
        {
            try
            {
                using (Mutex probe = Mutex.OpenExisting(MutexName))
                {
                    return probe != null;
                }
            }
            catch { return false; }
        }

        private static DateTime? ReadHeartbeat()
        {
            try
            {
                if (!File.Exists(AppPaths.StateFile)) { return null; }
                AppState state = AppState.Load(AppPaths.StateFile);
                return state.LastTriggerTime;
            }
            catch { return null; }
        }

        private static void KillMainInstances()
        {
            int self = Process.GetCurrentProcess().Id;
            foreach (Process process in Process.GetProcessesByName("CampusNet"))
            {
                try
                {
                    if (process.Id == self) { continue; }
                    Log("结束卡死的进程 PID " + process.Id);
                    process.Kill();
                    process.WaitForExit(5000);
                }
                catch { }
                finally { try { process.Dispose(); } catch { } }
            }
        }

        private static bool StartMainInstance()
        {
            try
            {
                string exe = ResolveExe();
                // 数据目录必须原样透传：主程序支持 --data-dir，守护却按默认目录拉起的话，
                // 会用错的配置和错的账号把程序重新拉起来（自定义数据目录的场景直接崩坏）。
                var info = new ProcessStartInfo(exe, "--tray" + DataDirArgument());
                info.UseShellExecute = false;
                info.CreateNoWindow = true;
                info.WorkingDirectory = Path.GetDirectoryName(exe);
                Process.Start(info);
                return true;
            }
            catch (Exception ex)
            {
                Log("启动失败：" + ex.Message);
                return false;
            }
        }

        /// <summary>要拉起的可执行文件：装过就用安装目录里的，否则用当前正在跑的这份。</summary>
        private static string ResolveExe()
        {
            return File.Exists(AppPaths.InstalledExe) ? AppPaths.InstalledExe : AppPaths.CurrentExe;
        }

        /// <summary>`--data-dir "…"`：守护进程自己就是带着它启动的，拉起别人时必须原样透传。</summary>
        public static string DataDirArgument()
        {
            string dir = AppPaths.DataDir;
            return string.IsNullOrEmpty(dir) ? string.Empty : " --data-dir \"" + dir + "\"";
        }

        /// <summary>守护拉起主程序时用的完整命令行（--watchdog --check-only 会打印它，便于排查）。</summary>
        public static string MainCommandLine(string exe)
        {
            return "\"" + exe + "\" --tray" + DataDirArgument();
        }

        /// <summary>守护自己的小日志：只保留最近一小段，避免无限增长。</summary>
        private static void Log(string message)
        {
            try
            {
                AppPaths.EnsureDataDir();
                string path = AppPaths.WatchdogLogFile;
                var info = new FileInfo(path);
                if (info.Exists && info.Length > MaxLogBytes) { File.Delete(path); }
                File.AppendAllText(path,
                    AppPaths.FormatTime(DateTime.Now) + " " + message + Environment.NewLine,
                    new UTF8Encoding(true));
            }
            catch { }
        }
    }
}
