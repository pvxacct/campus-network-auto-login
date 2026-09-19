using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Security.Cryptography;
using System.Text;

namespace CampusNet.Core
{
    /// <summary>用户配置：门户地址、探测节奏、风控闸门、表单固定字段等。</summary>
    public sealed class AppConfig
    {
        /// <summary>配置文件结构版本：小于当前值的老配置会在加载时自动迁移一次。</summary>
        public const int CurrentConfigVersion = 7;

        public const string DefaultUserAgent =
            "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0 Safari/537.36";

        public int ConfigVersion = CurrentConfigVersion;

        /// <summary>
        /// 配置文件存在但读不出来 / 解析不了时为 true。
        /// 此时必须停止自动登录：否则会拿着「默认 Portal + 已有凭据」去登录，
        /// 用户自定义的地址一旦丢失就会把账号密码发到错误的地方。
        /// </summary>
        public bool Corrupted;
        public string CorruptedReason = string.Empty;

        /// <summary>Portal 协议：http（默认，校园网 ePortal 基本都是明文）或 https。</summary>
        public string PortalScheme = "http";

        public string PortalHost = "10.66.209.2";
        public int EportalPort = 801;
        public string StatusPath = "/drcom/chkstatus";
        public string LoginPath = "/drcom/login";
        public string LogoutPath = "/drcom/logout";
        public string ErrorPromptPath = "/eportal/portal/err_code/loadErrorPrompt";
        public string UserAgent = DefaultUserAgent;

        /// <summary>网络正常时的探测间隔（秒）。只要探测能通就不碰 Portal。</summary>
        public int OnlineProbeSeconds = 20;

        /// <summary>探测失败后的快速复检间隔（秒），用于尽快发现断网并重连。</summary>
        public int OfflineProbeSeconds = 5;

        /// <summary>「本机探测不通、但 Portal 显示账号在线」时的兜底巡检间隔（秒）。</summary>
        public int UpstreamProbeSeconds = 300;

        public int ProbeTimeoutMs = 1500;
        /// <summary>
        /// HTTP / HTTPS 探测目标的单次超时（毫秒）。比 TCP 握手短得多：
        /// 内容校验目标正常只要几十毫秒，完全断网时这个值直接决定「多久能判定掉线」。
        /// </summary>
        public int HttpProbeTimeoutMs = 3000;
        /// <summary>探测不通后的快速复检轮数（每轮并行跑所有目标）。</summary>
        public int ConfirmAttempts = 2;
        public int ConfirmGapMs = 500;

        public List<string> ProbeTargets = new List<string>
        {
            "http:connect.rom.miui.com/generate_204|204",
            "http:www.baidu.com/robots.txt|Baiduspider",
            "http:www.msftconnecttest.com/connecttest.txt|Microsoft Connect Test",
            "tcp:223.5.5.5:443"
        };

        /// <summary>pre.2 及更早版本的默认探测列表：全是纯 TCP 握手，会被网关「代答」骗过。</summary>
        private static readonly List<string> LegacyProbeTargets = new List<string>
        {
            "tcp:223.5.5.5:443",
            "tcp:114.114.114.114:53",
            "tcp:www.msftconnecttest.com:80"
        };

        /// <summary>pre.3 ~ pre.5 的默认探测列表：只有一个内容校验目标，实测约 10% 单次抖动。</summary>
        private static readonly List<string> LegacyProbeTargetsV3 = new List<string>
        {
            "http:www.msftconnecttest.com/connecttest.txt|Microsoft Connect Test",
            "tcp:223.5.5.5:443",
            "tcp:114.114.114.114:53"
        };

        /// <summary>
        /// 判定离线后、真正提交登录前的二次确认延迟（秒）。
        /// 真机 50 次自然掉线实测：这条确认一次都没拦下过登录，3 秒纯粹是白等；
        /// 1 秒足够挡住「上一轮状态陈旧」这类误判，又把「发现 → 提交」压到约 1 秒。
        /// </summary>
        public int LoginConfirmDelaySec = 1;
        public int LoginMinIntervalSeconds = 60;
        public int LoginHourlyLimit = 12;

        /// <summary>
        /// 在线时每隔多少秒只读核对一次 Portal 会话（0 = 关闭）。
        /// 这是「账号被踢下线」最主要的发现途径：间隔越短，被踢后恢复得越快。
        /// 默认 120 秒 —— 实测 300 秒时「发现断网」的中位延迟高达 166 秒（最坏 410 秒）。
        /// </summary>
        public int SessionCheckSeconds = 120;

        /// <summary>
        /// 本机探测连续不通、但 Portal 说账号还在线时的容忍秒数；
        /// 超过它判定为「残留会话挡路」，自动注销后重新登录（0 = 关闭）。</summary>
        public int StuckReloginSeconds = 60;

        public int StatusTimeoutSec = 8;
        public int LoginTimeoutSec = 15;
        public int RetryCount = 1;

        public bool AutoStart = true;
        public bool ShowBalloon = true;

        public Dictionary<string, string> StaticFields = new Dictionary<string, string>
        {
            { "0MKKey", "123456" },
            { "R1", "0" },
            { "R2", "0" },
            { "R3", "0" },
            { "R6", "0" },
            { "para", "00" },
            { "v6ip", "" },
            { "terminal_type", "1" },
            { "lang", "zh" }
        };

        public string PortalBase { get { return NormalizeScheme(PortalScheme) + "://" + PortalHost; } }

        public string StatusUrl { get { return PortalBase + StatusPath; } }
        public string LoginUrl { get { return PortalBase + LoginPath; } }
        public string LogoutUrl { get { return PortalBase + LogoutPath; } }

        public string ErrorUrl
        {
            get
            {
                // PortalHost 自带端口时（例如 127.0.0.1:8099）直接沿用，否则补上 eportal 端口
                string host = PortalHost.IndexOf(':') >= 0
                    ? PortalHost
                    : PortalHost + ":" + EportalPort.ToString(CultureInfo.InvariantCulture);
                return NormalizeScheme(PortalScheme) + "://" + host + ErrorPromptPath;
            }
        }

        private static string NormalizeScheme(string value)
        {
            return string.Equals((value ?? string.Empty).Trim(), "https", StringComparison.OrdinalIgnoreCase)
                ? "https"
                : "http";
        }

        public static AppConfig Load(string path)
        {
            var config = new AppConfig();
            if (!File.Exists(path)) { return config; }   // 首次运行：用默认配置，不算损坏

            string rawText;
            try { rawText = File.ReadAllText(path, Encoding.UTF8); }
            catch (Exception ex)
            {
                config.Corrupted = true;
                config.CorruptedReason = "读取失败：" + ex.Message;
                return config;
            }
            if (string.IsNullOrWhiteSpace(rawText))
            {
                // 空文件几乎总是上一次写入被打断留下的。绝不能当成「没有配置」继续跑：
                // 那样会拿默认 Portal 去登录，用户自定义的地址就此被悄悄绕过。
                config.Corrupted = true;
                config.CorruptedReason = "配置文件是空的（上一次写入可能被中断）";
                return config;
            }

            Dictionary<string, object> map = null;
            try { map = Json.ReadObjectFromText(rawText); }
            catch (Exception ex)
            {
                config.Corrupted = true;
                config.CorruptedReason = "内容不是合法 JSON：" + ex.Message;
                return config;
            }
            if (map == null)
            {
                config.Corrupted = true;
                config.CorruptedReason = "内容不是 JSON 对象";
                return config;
            }

            config.PortalScheme = NormalizeScheme(Json.GetString(map, "PortalScheme", config.PortalScheme));
            config.PortalHost = Json.GetString(map, "PortalHost", config.PortalHost);
            // 兼容把协议直接写进地址的写法（https://10.66.209.2）
            if (config.PortalHost.StartsWith("http://", StringComparison.OrdinalIgnoreCase))
            {
                config.PortalScheme = "http";
                config.PortalHost = config.PortalHost.Substring(7);
            }
            else if (config.PortalHost.StartsWith("https://", StringComparison.OrdinalIgnoreCase))
            {
                config.PortalScheme = "https";
                config.PortalHost = config.PortalHost.Substring(8);
            }
            config.EportalPort = Json.GetInt(map, "EportalPort", config.EportalPort);
            config.StatusPath = Json.GetString(map, "StatusPath", config.StatusPath);
            config.LoginPath = Json.GetString(map, "LoginPath", config.LoginPath);
            config.LogoutPath = Json.GetString(map, "LogoutPath", config.LogoutPath);
            config.ErrorPromptPath = Json.GetString(map, "ErrorPromptPath", config.ErrorPromptPath);
            config.UserAgent = Json.GetString(map, "UserAgent", config.UserAgent);

            config.ConfigVersion = Json.GetInt(map, "ConfigVersion", 1);
            config.OnlineProbeSeconds = Clamp(Json.GetInt(map, "OnlineProbeSeconds", config.OnlineProbeSeconds), 5, 3600);
            config.OfflineProbeSeconds = Clamp(Json.GetInt(map, "OfflineProbeSeconds", config.OfflineProbeSeconds), 1, 600);
            config.UpstreamProbeSeconds = Clamp(Json.GetInt(map, "UpstreamProbeSeconds", config.UpstreamProbeSeconds), 30, 3600);
            config.ProbeTimeoutMs = Clamp(Json.GetInt(map, "ProbeTimeoutMs", config.ProbeTimeoutMs), 200, 10000);
            config.HttpProbeTimeoutMs = Clamp(Json.GetInt(map, "HttpProbeTimeoutMs", config.HttpProbeTimeoutMs), 500, 10000);
            config.ConfirmAttempts = Clamp(Json.GetInt(map, "ConfirmAttempts", config.ConfirmAttempts), 1, 10);
            config.ConfirmGapMs = Clamp(Json.GetInt(map, "ConfirmGapMs", config.ConfirmGapMs), 100, 5000);

            config.LoginConfirmDelaySec = Clamp(Json.GetInt(map, "LoginConfirmDelaySec", config.LoginConfirmDelaySec), 0, 60);
            config.LoginMinIntervalSeconds = Clamp(Json.GetInt(map, "LoginMinIntervalSeconds", config.LoginMinIntervalSeconds), 0, 3600);
            config.LoginHourlyLimit = Clamp(Json.GetInt(map, "LoginHourlyLimit", config.LoginHourlyLimit), 0, 240);
            config.SessionCheckSeconds = Clamp(Json.GetInt(map, "SessionCheckSeconds", config.SessionCheckSeconds), 0, 3600);
            config.StuckReloginSeconds = Clamp(Json.GetInt(map, "StuckReloginSeconds", config.StuckReloginSeconds), 0, 3600);
            config.StatusTimeoutSec = Clamp(Json.GetInt(map, "StatusTimeoutSec", config.StatusTimeoutSec), 2, 60);
            config.LoginTimeoutSec = Clamp(Json.GetInt(map, "LoginTimeoutSec", config.LoginTimeoutSec), 2, 60);
            config.RetryCount = Clamp(Json.GetInt(map, "RetryCount", config.RetryCount), 1, 5);

            config.AutoStart = Json.GetBool(map, "AutoStart", config.AutoStart);
            config.ShowBalloon = Json.GetBool(map, "ShowBalloon", config.ShowBalloon);

            object targets;
            if (map.TryGetValue("ProbeTargets", out targets))
            {
                var list = new List<string>();
                var array = targets as object[];
                if (array != null)
                {
                    foreach (object item in array)
                    {
                        string text = Convert.ToString(item, CultureInfo.InvariantCulture);
                        if (!string.IsNullOrWhiteSpace(text)) { list.Add(text.Trim()); }
                    }
                }
                if (list.Count > 0) { config.ProbeTargets = list; }
            }

            object staticFields;
            if (map.TryGetValue("StaticFields", out staticFields))
            {
                var dict = staticFields as Dictionary<string, object>;
                if (dict != null && dict.Count > 0)
                {
                    var copy = new Dictionary<string, string>();
                    foreach (var pair in dict)
                    {
                        copy[pair.Key] = pair.Value == null ? string.Empty : Convert.ToString(pair.Value, CultureInfo.InvariantCulture);
                    }
                    config.StaticFields = copy;
                }
            }

            if (string.IsNullOrWhiteSpace(config.PortalHost)) { config.PortalHost = "10.66.209.2"; }

            // 旧配置一次性迁移，迁移后回写一次（写失败不影响运行）：
            //   v1 -> v2：在线探测 60 秒的旧默认值升级为 20 秒。
            //   v2 -> v3：pre.2 的纯 TCP 默认探测列表换成带内容校验的新默认；
            //             老列表会被校园网关「替任意地址代答 TCP 握手」骗过，导致永远判定在线。
            //   v3 -> v4：pre.3 ~ pre.5 的默认探测列表（只有微软一个内容校验目标，实测约 10% 抖动）
            //             换成「小米 204 + 百度 + 微软 + TCP 兜底」四条，误判与状态闪跳都明显更少。
            //   v4 -> v5：复检默认值 3 轮 / 1000 毫秒 收紧为 2 轮 / 500 毫秒。
            //             配合「每个目标并行探测」，完全断网时从判定到提交登录由几十秒压到十几秒。
            //   v5 -> v6：会话核对间隔默认 300 秒缩短为 120 秒（被踢下线后发现的更快），
            //             疑似掉线核对的最小间隔由 60 秒降到 20 秒（内部常量，不占配置键）。
            //   v6 -> v7：登录前二次确认默认 3 秒缩短为 1 秒，只改「等于旧默认值 3」的那一份。
            if (config.ConfigVersion < CurrentConfigVersion)
            {
                if (SameTargets(config.ProbeTargets, LegacyProbeTargets)
                    || SameTargets(config.ProbeTargets, LegacyProbeTargetsV3))
                {
                    config.ProbeTargets = new List<string>(new AppConfig().ProbeTargets);
                }
                if (config.OnlineProbeSeconds == 60) { config.OnlineProbeSeconds = 20; }
                // 只改「等于旧默认值 300」的那一份；用户自己填过的值（例如 240 / 600）原样保留。
                if (config.SessionCheckSeconds == 300) { config.SessionCheckSeconds = 120; }
                // 同上：只改等于旧默认值 3 的那一份；用户自己填的 5 / 10 之类原样保留。
                if (config.LoginConfirmDelaySec == 3) { config.LoginConfirmDelaySec = new AppConfig().LoginConfirmDelaySec; }
                if (config.ConfirmAttempts == 3 && config.ConfirmGapMs == 1000)
                {
                    config.ConfirmAttempts = new AppConfig().ConfirmAttempts;
                    config.ConfirmGapMs = new AppConfig().ConfirmGapMs;
                }
                config.ConfigVersion = CurrentConfigVersion;
                try { config.Save(path); } catch { }
            }
            return config;
        }

        private static bool SameTargets(List<string> left, List<string> right)
        {
            if (left == null || right == null || left.Count != right.Count) { return false; }
            for (int i = 0; i < left.Count; i++)
            {
                if (string.Compare(left[i].Trim(), right[i].Trim(), StringComparison.OrdinalIgnoreCase) != 0) { return false; }
            }
            return true;
        }

        public void Save(string path)
        {
            var builder = new StringBuilder();
            builder.AppendLine("{");
            builder.AppendLine("  " + Json.Number("ConfigVersion", ConfigVersion) + ",");
            builder.AppendLine("  " + Json.String("PortalScheme", PortalScheme) + ",");
            builder.AppendLine("  " + Json.String("PortalHost", PortalHost) + ",");
            builder.AppendLine("  " + Json.Number("EportalPort", EportalPort) + ",");
            builder.AppendLine("  " + Json.String("StatusPath", StatusPath) + ",");
            builder.AppendLine("  " + Json.String("LoginPath", LoginPath) + ",");
            builder.AppendLine("  " + Json.String("LogoutPath", LogoutPath) + ",");
            builder.AppendLine("  " + Json.String("ErrorPromptPath", ErrorPromptPath) + ",");
            builder.AppendLine("  " + Json.String("UserAgent", UserAgent) + ",");
            builder.AppendLine("  " + Json.Number("OnlineProbeSeconds", OnlineProbeSeconds) + ",");
            builder.AppendLine("  " + Json.Number("OfflineProbeSeconds", OfflineProbeSeconds) + ",");
            builder.AppendLine("  " + Json.Number("UpstreamProbeSeconds", UpstreamProbeSeconds) + ",");
            builder.AppendLine("  " + Json.Number("ProbeTimeoutMs", ProbeTimeoutMs) + ",");
            builder.AppendLine("  " + Json.Number("HttpProbeTimeoutMs", HttpProbeTimeoutMs) + ",");
            builder.AppendLine("  " + Json.Number("ConfirmAttempts", ConfirmAttempts) + ",");
            builder.AppendLine("  " + Json.Number("ConfirmGapMs", ConfirmGapMs) + ",");
            builder.AppendLine("  \"ProbeTargets\": [" + JoinQuoted(ProbeTargets) + "],");
            builder.AppendLine("  " + Json.Number("LoginConfirmDelaySec", LoginConfirmDelaySec) + ",");
            builder.AppendLine("  " + Json.Number("LoginMinIntervalSeconds", LoginMinIntervalSeconds) + ",");
            builder.AppendLine("  " + Json.Number("LoginHourlyLimit", LoginHourlyLimit) + ",");
            builder.AppendLine("  " + Json.Number("SessionCheckSeconds", SessionCheckSeconds) + ",");
            builder.AppendLine("  " + Json.Number("StuckReloginSeconds", StuckReloginSeconds) + ",");
            builder.AppendLine("  " + Json.Number("StatusTimeoutSec", StatusTimeoutSec) + ",");
            builder.AppendLine("  " + Json.Number("LoginTimeoutSec", LoginTimeoutSec) + ",");
            builder.AppendLine("  " + Json.Number("RetryCount", RetryCount) + ",");
            builder.AppendLine("  " + Json.Bool("AutoStart", AutoStart) + ",");
            builder.AppendLine("  " + Json.Bool("ShowBalloon", ShowBalloon) + ",");
            var fields = new List<string>();
            foreach (var pair in StaticFields) { fields.Add(Json.String(pair.Key) + ": " + Json.String(pair.Value)); }
            builder.AppendLine("  \"StaticFields\": { " + string.Join(", ", fields.ToArray()) + " }");
            builder.AppendLine("}");
            Json.WriteText(path, builder.ToString());
        }

        private static string JoinQuoted(List<string> items)
        {
            var parts = new List<string>();
            foreach (string item in items) { parts.Add(Json.String(item)); }
            return string.Join(", ", parts.ToArray());
        }

        private static int Clamp(int value, int min, int max)
        {
            if (value < min) { return min; }
            if (value > max) { return max; }
            return value;
        }
    }

    public sealed class Credential
    {
        public string UserName = string.Empty;
        public string Password = string.Empty;

        public bool IsUsable
        {
            get { return !string.IsNullOrEmpty(UserName) && !string.IsNullOrEmpty(Password); }
        }
    }

    /// <summary>账号密码用 DPAPI（当前用户范围）加密，文件里不会出现明文。</summary>
    public static class CredentialStore
    {
        public static Credential Load(string path)
        {
            if (!File.Exists(path)) { return null; }
            var map = Json.ReadObject(path);
            if (map == null) { return null; }
            string user = Json.GetString(map, "UserName", string.Empty);
            string protectedText = Json.GetString(map, "Protected", string.Empty);
            if (string.IsNullOrEmpty(protectedText)) { return null; }
            byte[] blob = Convert.FromBase64String(protectedText);
            byte[] plain = ProtectedData.Unprotect(blob, null, DataProtectionScope.CurrentUser);
            var credential = new Credential();
            credential.UserName = user;
            credential.Password = Encoding.UTF8.GetString(plain);
            Array.Clear(plain, 0, plain.Length);
            return credential;
        }

        public static void Save(string path, string userName, string password)
        {
            byte[] plain = Encoding.UTF8.GetBytes(password ?? string.Empty);
            byte[] blob = ProtectedData.Protect(plain, null, DataProtectionScope.CurrentUser);
            Array.Clear(plain, 0, plain.Length);
            var builder = new StringBuilder();
            builder.AppendLine("{");
            builder.AppendLine("  " + Json.String("UserName", userName) + ",");
            builder.AppendLine("  " + Json.String("Protected", Convert.ToBase64String(blob)) + ",");
            builder.AppendLine("  " + Json.String("SavedAt", AppPaths.FormatTime(DateTime.Now)) + ",");
            builder.AppendLine("  " + Json.String("Note", "DPAPI 加密，仅当前 Windows 用户可解密") + "");
            builder.AppendLine("}");
            Json.WriteText(path, builder.ToString());
        }

        public static void Delete(string path)
        {
            try { if (File.Exists(path)) { File.Delete(path); } } catch { }
        }
    }

    /// <summary>运行状态快照，写入 state.json 供界面与诊断读取。</summary>
    public sealed class AppState
    {
        public string Version = AppPaths.Version;
        public string LastTrigger = string.Empty;
        public string LastProbe = string.Empty;
        public string LastResult = "idle";
        public bool Online;
        public string LastError = string.Empty;
        public int ConsecutiveFailures;
        public string LastLoginAttempt = string.Empty;
        public string LastLoginSuccess = string.Empty;
        public string LastSessionCheck = string.Empty;
        public string LastSessionResult = string.Empty;
        /// <summary>上一次会话核对的来源：periodic（定时巡检）/ suspect（疑似掉线核对）。</summary>
        public string LastSessionCheckKind = string.Empty;
        public string LoginWindowStart = string.Empty;
        public int LoginWindowCount;
        public long RunCount;
        public bool Paused;
        public string PauseUntil = string.Empty;
        public string LastMessage = string.Empty;

        /// <summary>被忽略的 Portal 业务提示（「账号已在别处在线」「密码错误」等）的累计次数与最近一条。</summary>
        public int IgnoredPrompts;
        public string LastIgnoredPrompt = string.Empty;

        /// <summary>最近一次「残留会话挡路 → 自动注销重登」的时间。</summary>
        public string LastForcedRelogin = string.Empty;

        public static AppState Load(string path)
        {
            var state = new AppState();
            Dictionary<string, object> map = null;
            try { map = Json.ReadObject(path); } catch { map = null; }
            if (map == null) { return state; }
            state.Version = Json.GetString(map, "Version", state.Version);
            state.LastTrigger = Json.GetString(map, "LastTrigger", string.Empty);
            state.LastProbe = Json.GetString(map, "LastProbe", string.Empty);
            state.LastResult = Json.GetString(map, "LastResult", state.LastResult);
            state.Online = Json.GetBool(map, "Online", false);
            state.LastError = Json.GetString(map, "LastError", string.Empty);
            state.ConsecutiveFailures = Json.GetInt(map, "ConsecutiveFailures", 0);
            state.LastLoginAttempt = Json.GetString(map, "LastLoginAttempt", string.Empty);
            state.LastLoginSuccess = Json.GetString(map, "LastLoginSuccess", string.Empty);
            state.LastSessionCheck = Json.GetString(map, "LastSessionCheck", string.Empty);
            state.LastSessionResult = Json.GetString(map, "LastSessionResult", string.Empty);
            state.LastSessionCheckKind = Json.GetString(map, "LastSessionCheckKind", string.Empty);
            state.LoginWindowStart = Json.GetString(map, "LoginWindowStart", string.Empty);
            state.LoginWindowCount = Json.GetInt(map, "LoginWindowCount", 0);
            state.RunCount = Json.GetInt(map, "RunCount", 0);
            state.Paused = Json.GetBool(map, "Paused", false);
            state.PauseUntil = Json.GetString(map, "PauseUntil", string.Empty);
            state.LastMessage = Json.GetString(map, "LastMessage", string.Empty);
            state.IgnoredPrompts = Json.GetInt(map, "IgnoredPrompts", 0);
            state.LastIgnoredPrompt = Json.GetString(map, "LastIgnoredPrompt", string.Empty);
            state.LastForcedRelogin = Json.GetString(map, "LastForcedRelogin", string.Empty);
            return state;
        }

        public void Save(string path)
        {
            // 写盘前统一脱敏：Portal 的响应原文可能带着提交过的表单（含密码），
            // 日志与状态文件都从这一个入口过一遍，避免哪条路径漏掉。
            LastError = Redact.Text(LastError);
            LastMessage = Redact.Text(LastMessage);
            LastIgnoredPrompt = Redact.Text(LastIgnoredPrompt);
            var builder = new StringBuilder();
            builder.AppendLine("{");
            builder.AppendLine("  " + Json.String("Version", Version) + ",");
            builder.AppendLine("  " + Json.String("LastTrigger", LastTrigger) + ",");
            builder.AppendLine("  " + Json.String("LastProbe", LastProbe) + ",");
            builder.AppendLine("  " + Json.String("LastResult", LastResult) + ",");
            builder.AppendLine("  " + Json.Bool("Online", Online) + ",");
            builder.AppendLine("  " + Json.String("LastError", LastError) + ",");
            builder.AppendLine("  " + Json.Number("ConsecutiveFailures", ConsecutiveFailures) + ",");
            builder.AppendLine("  " + Json.String("LastLoginAttempt", LastLoginAttempt) + ",");
            builder.AppendLine("  " + Json.String("LastLoginSuccess", LastLoginSuccess) + ",");
            builder.AppendLine("  " + Json.String("LastSessionCheck", LastSessionCheck) + ",");
            builder.AppendLine("  " + Json.String("LastSessionResult", LastSessionResult) + ",");
            builder.AppendLine("  " + Json.String("LastSessionCheckKind", LastSessionCheckKind) + ",");
            builder.AppendLine("  " + Json.String("LoginWindowStart", LoginWindowStart) + ",");
            builder.AppendLine("  " + Json.Number("LoginWindowCount", LoginWindowCount) + ",");
            builder.AppendLine("  " + Json.Number("RunCount", RunCount) + ",");
            builder.AppendLine("  " + Json.Bool("Paused", Paused) + ",");
            builder.AppendLine("  " + Json.String("PauseUntil", PauseUntil) + ",");
            builder.AppendLine("  " + Json.String("LastMessage", LastMessage) + ",");
            builder.AppendLine("  " + Json.Number("IgnoredPrompts", IgnoredPrompts) + ",");
            builder.AppendLine("  " + Json.String("LastIgnoredPrompt", LastIgnoredPrompt) + ",");
            builder.AppendLine("  " + Json.String("LastForcedRelogin", LastForcedRelogin));
            builder.AppendLine("}");
            Json.WriteText(path, builder.ToString());
        }

        /// <summary>
        /// 用磁盘上的内容刷新本对象（重载配置 / 凭据时用）。
        /// 关键点：永远不替换对象本身——后台线程每一轮都在往同一个对象里写状态，
        /// 换成新对象会让那一轮的写入落进旧对象（本轮结果丢失，甚至用旧内容覆盖状态文件）。
        /// </summary>
        public void CopyFrom(AppState other)
        {
            if (other == null) { return; }
            Version = other.Version;
            LastTrigger = other.LastTrigger;
            LastProbe = other.LastProbe;
            LastResult = other.LastResult;
            Online = other.Online;
            LastError = other.LastError;
            ConsecutiveFailures = other.ConsecutiveFailures;
            LastLoginAttempt = other.LastLoginAttempt;
            LastLoginSuccess = other.LastLoginSuccess;
            LastSessionCheck = other.LastSessionCheck;
            LastSessionResult = other.LastSessionResult;
            LastSessionCheckKind = other.LastSessionCheckKind;
            LoginWindowStart = other.LoginWindowStart;
            LoginWindowCount = other.LoginWindowCount;
            RunCount = other.RunCount;
            Paused = other.Paused;
            PauseUntil = other.PauseUntil;
            LastMessage = other.LastMessage;
            IgnoredPrompts = other.IgnoredPrompts;
            LastIgnoredPrompt = other.LastIgnoredPrompt;
            LastForcedRelogin = other.LastForcedRelogin;
        }

        /// <summary>引擎心跳：每轮评估都会更新，写入节流最多滞后 60 秒。</summary>
        public DateTime? LastTriggerTime { get { return AppPaths.ParseTime(LastTrigger); } }
        public DateTime? LastProbeTime { get { return AppPaths.ParseTime(LastProbe); } }
        public DateTime? LastLoginAttemptTime { get { return AppPaths.ParseTime(LastLoginAttempt); } }
        public DateTime? LastLoginSuccessTime { get { return AppPaths.ParseTime(LastLoginSuccess); } }
        public DateTime? LastSessionCheckTime { get { return AppPaths.ParseTime(LastSessionCheck); } }
        public DateTime? PauseUntilTime { get { return AppPaths.ParseTime(PauseUntil); } }
        public DateTime? LoginWindowStartTime { get { return AppPaths.ParseTime(LoginWindowStart); } }
        public DateTime? LastForcedReloginTime { get { return AppPaths.ParseTime(LastForcedRelogin); } }

    }
}
