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
        public const string DefaultUserAgent =
            "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0 Safari/537.36";

        public string PortalHost = "10.66.209.2";
        public int EportalPort = 801;
        public string StatusPath = "/drcom/chkstatus";
        public string LoginPath = "/drcom/login";
        public string LogoutPath = "/drcom/logout";
        public string ErrorPromptPath = "/eportal/portal/err_code/loadErrorPrompt";
        public string UserAgent = DefaultUserAgent;

        /// <summary>网络正常时的探测间隔（秒）。只要探测能通就不碰 Portal。</summary>
        public int OnlineProbeSeconds = 60;

        /// <summary>探测失败后的快速复检间隔（秒），用于尽快发现断网并重连。</summary>
        public int OfflineProbeSeconds = 5;

        public int ProbeTimeoutMs = 1500;
        public int ConfirmAttempts = 3;
        public int ConfirmGapMs = 1000;

        public List<string> ProbeTargets = new List<string>
        {
            "tcp:223.5.5.5:443",
            "tcp:114.114.114.114:53",
            "tcp:www.msftconnecttest.com:80"
        };

        public int LoginConfirmDelaySec = 3;
        public int LoginMinIntervalSeconds = 60;
        public int LoginHourlyLimit = 12;
        public int LoginCooldownMinutes = 30;
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

        public string StatusUrl { get { return "http://" + PortalHost + StatusPath; } }
        public string LoginUrl { get { return "http://" + PortalHost + LoginPath; } }
        public string LogoutUrl { get { return "http://" + PortalHost + LogoutPath; } }

        public string ErrorUrl
        {
            get
            {
                // PortalHost 自带端口时（例如 127.0.0.1:8099）直接沿用，否则补上 eportal 端口
                string host = PortalHost.IndexOf(':') >= 0
                    ? PortalHost
                    : PortalHost + ":" + EportalPort.ToString(CultureInfo.InvariantCulture);
                return "http://" + host + ErrorPromptPath;
            }
        }

        public static AppConfig Load(string path)
        {
            var config = new AppConfig();
            Dictionary<string, object> map = null;
            try { map = Json.ReadObject(path); } catch { map = null; }
            if (map == null) { return config; }

            config.PortalHost = Json.GetString(map, "PortalHost", config.PortalHost);
            config.EportalPort = Json.GetInt(map, "EportalPort", config.EportalPort);
            config.StatusPath = Json.GetString(map, "StatusPath", config.StatusPath);
            config.LoginPath = Json.GetString(map, "LoginPath", config.LoginPath);
            config.LogoutPath = Json.GetString(map, "LogoutPath", config.LogoutPath);
            config.ErrorPromptPath = Json.GetString(map, "ErrorPromptPath", config.ErrorPromptPath);
            config.UserAgent = Json.GetString(map, "UserAgent", config.UserAgent);

            config.OnlineProbeSeconds = Clamp(Json.GetInt(map, "OnlineProbeSeconds", config.OnlineProbeSeconds), 5, 3600);
            config.OfflineProbeSeconds = Clamp(Json.GetInt(map, "OfflineProbeSeconds", config.OfflineProbeSeconds), 1, 600);
            config.ProbeTimeoutMs = Clamp(Json.GetInt(map, "ProbeTimeoutMs", config.ProbeTimeoutMs), 200, 10000);
            config.ConfirmAttempts = Clamp(Json.GetInt(map, "ConfirmAttempts", config.ConfirmAttempts), 1, 10);
            config.ConfirmGapMs = Clamp(Json.GetInt(map, "ConfirmGapMs", config.ConfirmGapMs), 100, 5000);

            config.LoginConfirmDelaySec = Clamp(Json.GetInt(map, "LoginConfirmDelaySec", config.LoginConfirmDelaySec), 0, 60);
            config.LoginMinIntervalSeconds = Clamp(Json.GetInt(map, "LoginMinIntervalSeconds", config.LoginMinIntervalSeconds), 0, 3600);
            config.LoginHourlyLimit = Clamp(Json.GetInt(map, "LoginHourlyLimit", config.LoginHourlyLimit), 0, 240);
            config.LoginCooldownMinutes = Clamp(Json.GetInt(map, "LoginCooldownMinutes", config.LoginCooldownMinutes), 0, 1440);
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
            return config;
        }

        public void Save(string path)
        {
            var builder = new StringBuilder();
            builder.AppendLine("{");
            builder.AppendLine("  " + Json.String("PortalHost", PortalHost) + ",");
            builder.AppendLine("  " + Json.Number("EportalPort", EportalPort) + ",");
            builder.AppendLine("  " + Json.String("StatusPath", StatusPath) + ",");
            builder.AppendLine("  " + Json.String("LoginPath", LoginPath) + ",");
            builder.AppendLine("  " + Json.String("LogoutPath", LogoutPath) + ",");
            builder.AppendLine("  " + Json.String("ErrorPromptPath", ErrorPromptPath) + ",");
            builder.AppendLine("  " + Json.String("UserAgent", UserAgent) + ",");
            builder.AppendLine("  " + Json.Number("OnlineProbeSeconds", OnlineProbeSeconds) + ",");
            builder.AppendLine("  " + Json.Number("OfflineProbeSeconds", OfflineProbeSeconds) + ",");
            builder.AppendLine("  " + Json.Number("ProbeTimeoutMs", ProbeTimeoutMs) + ",");
            builder.AppendLine("  " + Json.Number("ConfirmAttempts", ConfirmAttempts) + ",");
            builder.AppendLine("  " + Json.Number("ConfirmGapMs", ConfirmGapMs) + ",");
            builder.AppendLine("  \"ProbeTargets\": [" + JoinQuoted(ProbeTargets) + "],");
            builder.AppendLine("  " + Json.Number("LoginConfirmDelaySec", LoginConfirmDelaySec) + ",");
            builder.AppendLine("  " + Json.Number("LoginMinIntervalSeconds", LoginMinIntervalSeconds) + ",");
            builder.AppendLine("  " + Json.Number("LoginHourlyLimit", LoginHourlyLimit) + ",");
            builder.AppendLine("  " + Json.Number("LoginCooldownMinutes", LoginCooldownMinutes) + ",");
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
        public string CooldownUntil = string.Empty;
        public string CooldownReason = string.Empty;
        public string LastLoginAttempt = string.Empty;
        public string LastLoginSuccess = string.Empty;
        public string LoginWindowStart = string.Empty;
        public int LoginWindowCount;
        public long RunCount;
        public bool Paused;
        public string PauseUntil = string.Empty;
        public string LastMessage = string.Empty;

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
            state.CooldownUntil = Json.GetString(map, "CooldownUntil", string.Empty);
            state.CooldownReason = Json.GetString(map, "CooldownReason", string.Empty);
            state.LastLoginAttempt = Json.GetString(map, "LastLoginAttempt", string.Empty);
            state.LastLoginSuccess = Json.GetString(map, "LastLoginSuccess", string.Empty);
            state.LoginWindowStart = Json.GetString(map, "LoginWindowStart", string.Empty);
            state.LoginWindowCount = Json.GetInt(map, "LoginWindowCount", 0);
            state.RunCount = Json.GetInt(map, "RunCount", 0);
            state.Paused = Json.GetBool(map, "Paused", false);
            state.PauseUntil = Json.GetString(map, "PauseUntil", string.Empty);
            state.LastMessage = Json.GetString(map, "LastMessage", string.Empty);
            return state;
        }

        public void Save(string path)
        {
            var builder = new StringBuilder();
            builder.AppendLine("{");
            builder.AppendLine("  " + Json.String("Version", Version) + ",");
            builder.AppendLine("  " + Json.String("LastTrigger", LastTrigger) + ",");
            builder.AppendLine("  " + Json.String("LastProbe", LastProbe) + ",");
            builder.AppendLine("  " + Json.String("LastResult", LastResult) + ",");
            builder.AppendLine("  " + Json.Bool("Online", Online) + ",");
            builder.AppendLine("  " + Json.String("LastError", LastError) + ",");
            builder.AppendLine("  " + Json.Number("ConsecutiveFailures", ConsecutiveFailures) + ",");
            builder.AppendLine("  " + Json.String("CooldownUntil", CooldownUntil) + ",");
            builder.AppendLine("  " + Json.String("CooldownReason", CooldownReason) + ",");
            builder.AppendLine("  " + Json.String("LastLoginAttempt", LastLoginAttempt) + ",");
            builder.AppendLine("  " + Json.String("LastLoginSuccess", LastLoginSuccess) + ",");
            builder.AppendLine("  " + Json.String("LoginWindowStart", LoginWindowStart) + ",");
            builder.AppendLine("  " + Json.Number("LoginWindowCount", LoginWindowCount) + ",");
            builder.AppendLine("  " + Json.Number("RunCount", RunCount) + ",");
            builder.AppendLine("  " + Json.Bool("Paused", Paused) + ",");
            builder.AppendLine("  " + Json.String("PauseUntil", PauseUntil) + ",");
            builder.AppendLine("  " + Json.String("LastMessage", LastMessage));
            builder.AppendLine("}");
            Json.WriteText(path, builder.ToString());
        }

        public DateTime? CooldownUntilTime { get { return AppPaths.ParseTime(CooldownUntil); } }
        public DateTime? LastProbeTime { get { return AppPaths.ParseTime(LastProbe); } }
        public DateTime? LastLoginAttemptTime { get { return AppPaths.ParseTime(LastLoginAttempt); } }
        public DateTime? LastLoginSuccessTime { get { return AppPaths.ParseTime(LastLoginSuccess); } }
        public DateTime? PauseUntilTime { get { return AppPaths.ParseTime(PauseUntil); } }
        public DateTime? LoginWindowStartTime { get { return AppPaths.ParseTime(LoginWindowStart); } }

        public int CooldownRemainingSeconds
        {
            get
            {
                DateTime? until = CooldownUntilTime;
                if (!until.HasValue) { return 0; }
                double seconds = (until.Value - DateTime.Now).TotalSeconds;
                return seconds <= 0 ? 0 : (int)Math.Ceiling(seconds);
            }
        }
    }
}
