using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Reflection;
using System.Runtime.InteropServices;
using System.Text;
using Microsoft.Win32;

namespace CampusNet.Core
{
    /// <summary>自安装 / 自卸载 / 开机自启 / 快捷方式。</summary>
    public static class SelfInstaller
    {
        private const string RunKeyPath = @"Software\Microsoft\Windows\CurrentVersion\Run";
        private const string RunValueName = "CampusNet";

        public static bool IsRunningFromInstallDir
        {
            get
            {
                string current = AppPaths.CurrentExe;
                return string.Equals(Path.GetFullPath(current), Path.GetFullPath(AppPaths.InstalledExe), StringComparison.OrdinalIgnoreCase);
            }
        }

        public static bool IsInstalled
        {
            get { return File.Exists(AppPaths.InstalledExe); }
        }

        public static void Install(Logger log, bool desktopShortcut)
        {
            Directory.CreateDirectory(AppPaths.InstallDir);
            if (!IsRunningFromInstallDir)
            {
                File.Copy(AppPaths.CurrentExe, AppPaths.InstalledExe, true);
                log.Info("已复制程序到 " + AppPaths.InstalledExe);
            }
            CreateShortcut(AppPaths.StartMenuShortcut, AppPaths.InstalledExe, "校园网自动登录（Dr.COM）");
            if (desktopShortcut) { CreateShortcut(AppPaths.DesktopShortcut, AppPaths.InstalledExe, "校园网自动登录（Dr.COM）"); }
            SetAutoStart(true, log);
            EnsureWatchdog(log);
        }

        /// <summary>
        /// 卸载：关自启、停守护、删快捷方式、（可选）删数据，最后安排删除程序文件。
        ///
        /// 为什么必须返回结果：正在运行的 exe 是删不掉的（Windows 不允许删除被映射的映像），
        /// 老实现却照样弹「已卸载」，于是出现「说卸载了、文件还在、按钮又变回卸载」的自相矛盾。
        /// 现在把「做了哪些事、文件什么时候消失」如实交给调用方，并由调用方在卸载后退出程序。
        /// </summary>
        public static UninstallResult Uninstall(Logger log, bool removeData, bool removeDesktopShortcut)
        {
            var result = new UninstallResult();
            result.WasInstalled = IsInstalled;
            SetAutoStart(false, log);
            RemoveWatchdog(log);
            TryDelete(AppPaths.StartMenuShortcut);
            if (removeDesktopShortcut) { TryDelete(AppPaths.DesktopShortcut); }
            if (removeData)
            {
                try
                {
                    if (Directory.Exists(AppPaths.DataDir)) { Directory.Delete(AppPaths.DataDir, true); }
                }
                catch (Exception ex) { log.Warn("删除数据目录失败：" + ex.Message); }
            }
            if (result.WasInstalled)
            {
                bool ok = ScheduleSelfDelete(AppPaths.InstalledExe, AppPaths.InstallDir, log,
                    out result.RebootFallback, out result.CleanupScript);
                result.DeleteScheduled = ok;
                log.Info(ok
                    ? "已安排删除 " + AppPaths.InstalledExe + "（本进程退出后由清理进程删除，重启后删除作兜底）。"
                    : "安排删除 " + AppPaths.InstalledExe + " 失败，请手动删除该文件。");
            }
            else
            {
                log.Info("本机没有已安装的程序文件（可能一直在便携模式运行），只清理了自启与快捷方式。");
            }
            return result;
        }

        /// <summary>卸载计划（--uninstall --check-only 打印，供人在动手前确认，也供自动化断言）。</summary>
        public static List<string> DescribeUninstallPlan(bool removeData, bool removeDesktopShortcut)
        {
            var lines = new List<string>();
            lines.Add("程序路径：" + AppPaths.CurrentExe);
            lines.Add("当前进程 PID：" + Process.GetCurrentProcess().Id);
            lines.Add("1. 关闭开机自启（注册表 Run 项：" + RunValueName + "）");
            lines.Add("2. 停止守护进程");
            lines.Add("3. 删除开始菜单快捷方式：" + AppPaths.StartMenuShortcut);
            lines.Add(removeDesktopShortcut
                ? "4. 删除桌面快捷方式：" + AppPaths.DesktopShortcut
                : "4. 保留桌面快捷方式");
            lines.Add(removeData
                ? "5. 删除数据目录：" + AppPaths.DataDir + "（账号、日志一并删除）"
                : "5. 保留数据目录：" + AppPaths.DataDir);
            if (IsInstalled)
            {
                lines.Add("6. 删除已安装的程序文件：" + AppPaths.InstalledExe);
                lines.Add("   · 本进程正在运行该文件，现在删不掉；会先写一个独立清理进程，");
                lines.Add("     等本进程退出后立即删除（最多等 240 秒），并删除空的安装目录；");
                lines.Add("   · 同时登记「重启后删除」作为兜底，删除失败时最迟下次重启消失。");
            }
            else
            {
                lines.Add("6. 本机没有已安装的程序文件（便携模式），无需删除");
            }
            lines.Add("（--check-only：以上只是计划，本次不删除任何文件）");
            return lines;
        }

        public static bool IsAutoStartEnabled
        {
            get
            {
                try
                {
                    using (RegistryKey key = Registry.CurrentUser.OpenSubKey(RunKeyPath, false))
                    {
                        if (key == null) { return false; }
                        object value = key.GetValue(RunValueName);
                        return value != null && value.ToString().IndexOf("CampusNet.exe", StringComparison.OrdinalIgnoreCase) >= 0;
                    }
                }
                catch { return false; }
            }
        }

        public static void SetAutoStart(bool enabled, Logger log)
        {
            try
            {
                using (RegistryKey key = Registry.CurrentUser.CreateSubKey(RunKeyPath))
                {
                    if (key == null) { return; }
                    if (enabled)
                    {
                        string target = IsInstalled ? AppPaths.InstalledExe : AppPaths.CurrentExe;
                        key.SetValue(RunValueName, "\"" + target + "\" --tray", RegistryValueKind.String);
                        if (log != null) { log.Info("已开启开机自启（登录后自动在托盘运行）。"); }
                    }
                    else
                    {
                        key.DeleteValue(RunValueName, false);
                        if (log != null) { log.Info("已关闭开机自启。"); }
                    }
                }
            }
            catch (Exception ex)
            {
                if (log != null) { log.Warn("设置开机自启失败：" + ex.Message); }
            }
        }

        // ---------------------------------------------------------------- 守护任务

        /// <summary>守护进程是否在跑。</summary>
        public static bool IsWatchdogInstalled
        {
            get { return Watchdog.IsRunning; }
        }

        /// <summary>
        /// 确保守护进程在跑。守护是一个独立的小进程（`--watchdog-loop`），每 30 秒看一眼主程序，
        /// 崩了/卡死了就把它拉起来——不需要管理员权限，也不需要注册计划任务。
        /// </summary>
        public static bool EnsureWatchdog(Logger log)
        {
            return Watchdog.EnsureRunning(log);
        }

        public static void RemoveWatchdog(Logger log)
        {
            Watchdog.Stop(log);
        }

        /// <summary>计划任务是否存在（schtasks 查询，普通权限即可）。</summary>
        public static bool TaskExists(string name)
        {
            return RunSchtasks("/query /tn \"" + name + "\"", 8000, null);
        }

        private static bool RunSchtasks(string arguments, int timeoutMs, Logger log)
        {
            try
            {
                var info = new ProcessStartInfo("schtasks.exe", arguments);
                info.UseShellExecute = false;
                info.CreateNoWindow = true;
                info.RedirectStandardOutput = true;
                info.RedirectStandardError = true;
                using (Process process = Process.Start(info))
                {
                    if (process == null) { return false; }
                    string output = process.StandardOutput.ReadToEnd();
                    string error = process.StandardError.ReadToEnd();
                    if (!process.WaitForExit(timeoutMs))
                    {
                        try { process.Kill(); } catch { }
                        if (log != null) { log.Warn("schtasks 超时：" + arguments); }
                        return false;
                    }
                    if (process.ExitCode != 0)
                    {
                        if (log != null)
                        {
                            string detail = (error + " " + output).Trim();
                            log.Warn("schtasks " + arguments + " 失败（" + process.ExitCode + "）：" + detail);
                        }
                        return false;
                    }
                    return true;
                }
            }
            catch (Exception ex)
            {
                if (log != null) { log.Warn("调用 schtasks 失败：" + ex.Message); }
                return false;
            }
        }

        public static void CreateShortcut(string path, string target, string description)
        {
            try
            {
                Directory.CreateDirectory(Path.GetDirectoryName(path));
                Type shellType = Type.GetTypeFromProgID("WScript.Shell");
                if (shellType == null) { return; }
                dynamic shell = Activator.CreateInstance(shellType);
                dynamic link = shell.CreateShortcut(path);
                link.TargetPath = target;
                link.WorkingDirectory = Path.GetDirectoryName(target);
                link.Description = description;
                link.IconLocation = target + ",0";
                link.Save();
            }
            catch { }
        }

        public static void TryDelete(string path)
        {
            try { if (File.Exists(path)) { File.Delete(path); } } catch { }
        }

        private const int MoveFileDelayUntilReboot = 0x4;

        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern bool MoveFileEx(string existingFileName, string newFileName, int flags);

        /// <summary>
        /// 安排删除「正在运行的自己」。
        ///
        /// 主路径：写一个独立 .cmd 到临时目录，由它等本进程退出后删除 exe、再删空的安装目录。
        /// 之所以落成脚本文件而不是把路径拼进命令行：路径不出现在命令行里就没有转义 / 注入问题
        /// （老实现是 cmd /c ping … &amp; del "路径"，路径里出现引号就会被截断）。
        /// 兜底：MoveFileEx(MOVEFILE_DELAY_UNTIL_REBOOT)，普通权限写不进
        /// PendingFileRenameOperations 时会失败，失败也无妨——主路径才是日常生效的那条。
        /// </summary>
        private static bool ScheduleSelfDelete(string exePath, string installDir, Logger log,
            out bool rebootFallback, out string scriptPath)
        {
            scriptPath = string.Empty;
            int pid = Process.GetCurrentProcess().Id;

            try { rebootFallback = MoveFileEx(exePath, null, MoveFileDelayUntilReboot); }
            catch { rebootFallback = false; }
            if (!rebootFallback && log != null)
            {
                log.Info("「重启后删除」登记未成功（普通权限下常见），改由清理进程在本进程退出后直接删除。");
            }

            try
            {
                scriptPath = Path.Combine(Path.GetTempPath(), "CampusNet-cleanup-" + pid + ".cmd");
                var text = new StringBuilder();
                text.AppendLine("@echo off");
                text.AppendLine("rem 由「校园网自动登录」生成：等主进程退出后删除程序文件。");
                text.AppendLine("setlocal");
                text.AppendLine("for /l %%i in (1,1,120) do (");
                text.AppendLine("  tasklist /fi \"PID eq " + pid + "\" /nh | find \"" + pid + "\" >nul || goto gone");
                text.AppendLine("  ping -n 2 127.0.0.1 >nul");
                text.AppendLine(")");
                text.AppendLine(":gone");
                text.AppendLine("for /l %%i in (1,1,15) do (");
                text.AppendLine("  del /f /q \"" + exePath + "\" >nul 2>nul");
                text.AppendLine("  if not exist \"" + exePath + "\" goto removed");
                text.AppendLine("  ping -n 2 127.0.0.1 >nul");
                text.AppendLine(")");
                text.AppendLine(":removed");
                text.AppendLine("rd \"" + installDir + "\" >nul 2>nul");
                text.AppendLine("del /f /q \"%~f0\" >nul 2>nul");
                File.WriteAllText(scriptPath, text.ToString(), Encoding.ASCII);

                var info = new ProcessStartInfo("cmd.exe", "/c \"" + scriptPath + "\"");
                info.UseShellExecute = false;
                info.CreateNoWindow = true;
                info.WindowStyle = ProcessWindowStyle.Hidden;
                Process.Start(info);
                return true;
            }
            catch (Exception ex)
            {
                if (log != null) { log.Warn("安排清理进程失败：" + ex.Message); }
                return false;
            }
        }
    }

    /// <summary>卸载到底做了什么：界面据此如实提示，不再出现「说卸载了但文件还在」。</summary>
    public sealed class UninstallResult
    {
        /// <summary>本机是否存在已安装的程序文件（便携模式运行时为 false）。</summary>
        public bool WasInstalled;
        /// <summary>是否已经安排好「本进程退出后删除程序文件」。</summary>
        public bool DeleteScheduled;
        /// <summary>是否成功登记了「重启后删除」兜底。</summary>
        public bool RebootFallback;
        /// <summary>清理脚本路径（排障用，正常用户看不到）。</summary>
        public string CleanupScript = string.Empty;
    }

    public sealed class LegacyReport
    {
        public bool ScheduledTask;
        public bool ScriptDir;
        public bool DataDir;

        public bool Any
        {
            get { return ScheduledTask || ScriptDir || DataDir; }
        }

        public string Describe()
        {
            var parts = new List<string>();
            if (ScheduledTask) { parts.Add("计划任务 " + AppPaths.LegacyTaskName); }
            if (ScriptDir) { parts.Add("脚本目录 " + AppPaths.LegacyScriptDir); }
            if (DataDir) { parts.Add("旧数据目录 CampusAutoLogin"); }
            return parts.Count == 0 ? "无" : string.Join("、", parts.ToArray());
        }
    }

    /// <summary>旧版（1.x PowerShell 版）残留的检测与清理。删除计划任务需要一次 UAC 提权。</summary>
    public static class LegacyCleanup
    {
        public static LegacyReport Detect()
        {
            var report = new LegacyReport();
            report.ScheduledTask = TaskExists();
            report.ScriptDir = Directory.Exists(AppPaths.LegacyScriptDir);
            report.DataDir = Directory.Exists(AppPaths.LegacyDataDir);
            return report;
        }

        public static bool TaskExists()
        {
            return SelfInstaller.TaskExists(AppPaths.LegacyTaskName);
        }

        /// <summary>提权执行清理（弹一次 UAC），返回是否成功。</summary>
        public static bool RunElevated(bool deleteLegacyData, Logger log)
        {
            try
            {
                string arguments = "--cleanup-legacy";
                if (deleteLegacyData) { arguments += " --delete-legacy-data"; }
                var info = new ProcessStartInfo(AppPaths.CurrentExe, arguments);
                info.UseShellExecute = true;
                info.Verb = "runas";
                using (Process process = Process.Start(info))
                {
                    process.WaitForExit();
                    log.Info("旧版清理程序已结束（退出码 " + process.ExitCode + "）。");
                    return process.ExitCode == 0;
                }
            }
            catch (Exception ex)
            {
                log.Warn("清理旧版需要管理员权限，本次未执行：" + ex.Message);
                return false;
            }
        }

        /// <summary>在提权进程里执行的实际清理动作。</summary>
        public static int RunAsHelper(bool deleteLegacyData)
        {
            var log = new Logger(AppPaths.LogFile, AppPaths.LogOldFile);
            log.Info("开始清理旧版残留（管理员权限）。");
            bool taskRemoved = false;
            try
            {
                var info = new ProcessStartInfo("schtasks.exe", "/delete /tn \"" + AppPaths.LegacyTaskName + "\" /f");
                info.UseShellExecute = false;
                info.CreateNoWindow = true;
                info.RedirectStandardOutput = true;
                info.RedirectStandardError = true;
                using (Process process = Process.Start(info))
                {
                    string output = process.StandardOutput.ReadToEnd() + process.StandardError.ReadToEnd();
                    process.WaitForExit(10000);
                    taskRemoved = process.HasExited && process.ExitCode == 0;
                    log.Info("删除旧计划任务：" + (taskRemoved ? "成功" : "失败或不存在") + " " + output.Trim());
                }
            }
            catch (Exception ex) { log.Warn("删除旧计划任务失败：" + ex.Message); }

            bool dirRemoved = RemoveDirectory(AppPaths.LegacyScriptDir, log, "旧脚本目录");
            bool dataRemoved = true;
            if (deleteLegacyData) { dataRemoved = RemoveDirectory(AppPaths.LegacyDataDir, log, "旧数据目录"); }
            else { log.Info("按设置保留旧数据目录：" + AppPaths.LegacyDataDir); }

            bool clean = !TaskExists() && !Directory.Exists(AppPaths.LegacyScriptDir);
            log.Info("旧版清理结束：" + (clean ? "已清理干净" : "仍有残留，请手动检查"));
            if (!taskRemoved && clean) { taskRemoved = true; }
            return clean && dataRemoved ? 0 : 1;
        }

        private static bool RemoveDirectory(string path, Logger log, string label)
        {
            if (!Directory.Exists(path)) { log.Info(label + "不存在，无需删除：" + path); return true; }
            try
            {
                Directory.Delete(path, true);
                log.Info("已删除" + label + "：" + path);
                return true;
            }
            catch (Exception ex)
            {
                log.Warn("删除" + label + "失败：" + ex.Message);
                return false;
            }
        }
    }

    /// <summary>一键诊断信息（可复制粘贴求助）。</summary>
    public static class Diagnostics
    {
        public static string Build(LoginEngine engine, Logger log, bool includeLog)
        {
            EngineSnapshot snapshot = engine.Snapshot();
            AppConfig config = engine.Config;
            var builder = new StringBuilder();
            builder.AppendLine("校园网自动登录 " + AppPaths.Version + " 诊断信息");
            builder.AppendLine("生成时间：" + AppPaths.FormatTime(DateTime.Now));
            builder.AppendLine("程序路径：" + AppPaths.CurrentExe);
            builder.AppendLine("已安装  ：" + (SelfInstaller.IsInstalled ? "是（" + AppPaths.InstalledExe + "）" : "否（便携运行）"));
            builder.AppendLine("开机自启：" + (SelfInstaller.IsAutoStartEnabled ? "已开启" : "已关闭"));
            builder.AppendLine("守护    ：" + (SelfInstaller.IsWatchdogInstalled
                ? "已开启（守护进程每 " + Watchdog.LoopIntervalSeconds + " 秒检查一次）"
                : "未开启（崩溃后不会自动回来）"));
            builder.AppendLine("数据目录：" + AppPaths.DataDir);
            builder.AppendLine("账号    ：" + (snapshot.HasCredential ? Mask(snapshot.UserName) : "未保存"));
            builder.AppendLine();
            builder.AppendLine("---- 运行状态 ----");
            builder.AppendLine("状态      ：" + snapshot.StatusText + "（" + snapshot.StatusKey + "）");
            builder.AppendLine("最近结果  ：" + snapshot.LastResult);
            builder.AppendLine("最近触发  ：" + Display(snapshot.LastTrigger) + Since(snapshot.LastTrigger));
            builder.AppendLine("最近探测  ：" + Display(snapshot.LastProbe) + Since(snapshot.LastProbe));
            builder.AppendLine("最近登录  ：" + Display(snapshot.LastLoginAttempt));
            builder.AppendLine("登录成功  ：" + Display(snapshot.LastLoginSuccess));
            builder.AppendLine("会话核对  ：" + (string.IsNullOrEmpty(snapshot.LastSessionCheck)
                ? "尚未核对"
                : Display(AppPaths.ParseTime(snapshot.LastSessionCheck)) + Since(AppPaths.ParseTime(snapshot.LastSessionCheck))
                    + "（" + DescribeSession(snapshot.LastSessionResult)
                    + (string.IsNullOrEmpty(snapshot.LastSessionCheckKind) ? string.Empty : " · " + DescribeSessionKind(snapshot.LastSessionCheckKind)) + "）"));
            builder.AppendLine("连续失败  ：" + snapshot.ConsecutiveFailures + " 次；本小时登录 " + snapshot.LoginWindowCount + " 次");
            builder.AppendLine("暂停      ：" + (snapshot.Paused ? "是" + (snapshot.PauseUntil.HasValue ? "，直到 " + Display(snapshot.PauseUntil) : string.Empty) : "否"));
            builder.AppendLine("最近错误  ：" + (string.IsNullOrEmpty(snapshot.LastError) ? "无" : snapshot.LastError));
            builder.AppendLine("已忽略提示：" + snapshot.IgnoredPrompts + " 次"
                + (string.IsNullOrEmpty(snapshot.LastIgnoredPrompt) ? string.Empty : "；最近：" + snapshot.LastIgnoredPrompt));
            builder.AppendLine("强制重登  ：" + (string.IsNullOrEmpty(snapshot.LastForcedRelogin)
                ? "尚未发生（本机不通而 Portal 说在线时才会自动注销重登）"
                : Display(AppPaths.ParseTime(snapshot.LastForcedRelogin)) + Since(AppPaths.ParseTime(snapshot.LastForcedRelogin))));
            builder.AppendLine("累计检查  ：" + snapshot.RunCount + " 次");
            builder.AppendLine("今日登录  ：确认成功 " + snapshot.DayLoginSuccess + " 次 / 提交 "
                + snapshot.DayLoginAttempts + " 次"
                + (string.IsNullOrEmpty(snapshot.DayKey) ? string.Empty : "（" + snapshot.DayKey + "）"));
            builder.AppendLine("恢复耗时  ：" + (snapshot.LastRecoverySeconds < 0
                ? "本次进程还没有成功样本"
                : "最近 " + snapshot.LastRecoverySeconds + " 秒；本次中位 " + snapshot.RecoveryMedianSeconds
                  + " 秒（" + snapshot.RecoverySampleCount + " 次样本）"));
            builder.AppendLine();
            builder.AppendLine("---- 网络 ----");
            builder.AppendLine("网卡      ：" + snapshot.Network.AdapterName + "（" + snapshot.Network.AdapterType + "）");
            builder.AppendLine("本机 IP   ：" + Display2(snapshot.Network.IPv4));
            builder.AppendLine("网关      ：" + Display2(snapshot.Network.Gateway));
            builder.AppendLine("DNS       ：" + Display2(snapshot.Network.Dns));
            builder.AppendLine("延迟/丢包 ：" + (snapshot.LatencyMs < 0 ? "未知" : snapshot.LatencyMs + " ms") + " / " + snapshot.LossPercent + "%");
            builder.AppendLine("探测结果  ：" + snapshot.ProbeSummary);
            builder.AppendLine();
            builder.AppendLine("---- 配置 ----");
            if (config.Corrupted)
            {
                builder.AppendLine("配置状态  ：已损坏（" + config.CorruptedReason + "）——已停止自动登录，请检查 " + AppPaths.ConfigFile);
            }
            if (ValidTargetCount(config) == 0)
            {
                builder.AppendLine("探测目标  ：没有任何一条合法目标——已停止自动登录，请修正 ProbeTargets");
            }
            builder.AppendLine("Portal    ：" + config.PortalBase + config.StatusPath);
            builder.AppendLine("探测节奏  ：在线每 " + config.OnlineProbeSeconds + " 秒；异常每 " + config.OfflineProbeSeconds + " 秒；确认 "
                + config.ConfirmAttempts + " 轮（间隔 " + config.ConfirmGapMs + " 毫秒）；兜底巡检每 " + config.UpstreamProbeSeconds + " 秒");
            builder.AppendLine("探测超时  ：TCP/ICMP " + config.ProbeTimeoutMs + " 毫秒；HTTP " + config.HttpProbeTimeoutMs
                + " 毫秒（并行探测，整轮约等于单次超时）");
            builder.AppendLine("风控闸门  ：最小间隔 " + config.LoginMinIntervalSeconds + " 秒；每小时上限 "
                + config.LoginHourlyLimit + " 次；登录前确认 " + config.LoginConfirmDelaySec + " 秒；会话核对每 "
                + (config.SessionCheckSeconds > 0 ? config.SessionCheckSeconds + " 秒" : "关闭"));
            builder.AppendLine("残留重登  ：" + (config.StuckReloginSeconds > 0
                ? "本机连续 " + config.StuckReloginSeconds + " 秒不通但 Portal 说在线时，自动注销并重新登录"
                : "关闭"));
            builder.AppendLine("探测目标  ：" + string.Join(", ", config.ProbeTargets.ToArray()));
            builder.AppendLine("探测方式  ：" + (HasContentTarget(config)
                ? "内容校验 + TCP 兜底（能识破网关代答）"
                : "仅 TCP 握手（无法识破网关代答，建议保留一个 http: 目标）"));
            builder.AppendLine();
            builder.AppendLine("---- 旧版残留 ----");
            LegacyReport legacy = LegacyCleanup.Detect();
            builder.AppendLine("检测结果  ：" + legacy.Describe());
            if (includeLog)
            {
                builder.AppendLine();
                builder.AppendLine("---- 最近日志 ----");
                builder.AppendLine(log.TailText(60));
            }
            return builder.ToString();
        }

        private static string Display(DateTime? time)
        {
            return time.HasValue ? AppPaths.FormatTime(time.Value) : "—";
        }

        private static string DescribeSession(string key)
        {
            switch (key)
            {
                case "online": return "Portal 显示账号在线";
                case "offline": return "Portal 显示账号已离线";
                case "unreachable": return "Portal 不可达";
                default: return string.IsNullOrEmpty(key) ? "—" : key;
            }
        }

        /// <summary>会话核对的来源：定时巡检 / 疑似掉线核对（后者说明本机探测已经不对劲）。</summary>
        private static string DescribeSessionKind(string kind)
        {
            switch (kind)
            {
                case "periodic": return "定时巡检";
                case "suspect": return "疑似掉线核对";
                default: return string.Empty;
            }
        }

        private static bool HasContentTarget(AppConfig config)
        {
            foreach (string text in config.ProbeTargets)
            {
                ProbeTarget target = ProbeTarget.Parse(text);
                if (target != null && target.ContentVerified) { return true; }
            }
            return false;
        }

        private static int ValidTargetCount(AppConfig config)
        {
            int count = 0;
            foreach (string text in config.ProbeTargets)
            {
                if (ProbeTarget.Parse(text) != null) { count++; }
            }
            return count;
        }

        private static string Since(DateTime? time)
        {
            if (!time.HasValue) { return string.Empty; }
            TimeSpan span = DateTime.Now - time.Value;
            if (span.TotalSeconds < 0) { span = TimeSpan.Zero; }
            if (span.TotalMinutes < 1) { return "（" + (int)span.TotalSeconds + " 秒前）"; }
            if (span.TotalHours < 1) { return "（" + (int)span.TotalMinutes + " 分钟前）"; }
            return "（" + (int)span.TotalHours + " 小时前）";
        }

        private static string Display2(string text)
        {
            return string.IsNullOrEmpty(text) ? "—" : text;
        }

        private static string Mask(string userName)
        {
            if (string.IsNullOrEmpty(userName)) { return "未设置"; }
            if (userName.Length <= 3) { return userName.Substring(0, 1) + "**"; }
            return userName.Substring(0, 3) + new string('*', Math.Max(1, userName.Length - 3));
        }
    }
}
