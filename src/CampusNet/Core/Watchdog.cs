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
        /// <summary>state.json 里的最近触发时间超过这个秒数，就认为引擎卡死。</summary>
        public const int StaleSeconds = 180;
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

            double age = (DateTime.Now - heartbeat.Value).TotalSeconds;
            if (age > StaleSeconds)
            {
                detail = "引擎已经 " + (int)age + " 秒没有动静";
                return "stale";
            }
            detail = "最近一次检查在 " + (int)Math.Max(0, age) + " 秒前";
            return "alive";
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
                string exe = File.Exists(AppPaths.InstalledExe) ? AppPaths.InstalledExe : AppPaths.CurrentExe;
                var info = new ProcessStartInfo(exe, "--tray");
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
