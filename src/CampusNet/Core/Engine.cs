using System;
using System.Collections.Generic;
using System.Globalization;
using System.Threading;

namespace CampusNet.Core
{
    /// <summary>界面 / 托盘读取的状态快照（深拷贝，线程安全）。</summary>
    public sealed class EngineSnapshot
    {
        public string StatusKey = "starting";
        public string StatusText = "正在启动…";
        public bool Online;
        public string LastResult = "idle";
        public string LastMessage = string.Empty;
        public string LastError = string.Empty;
        public string ProbeSummary = string.Empty;
        public int ConsecutiveFailures;
        public int LoginWindowCount;
        public long RunCount;
        public DateTime? LastTrigger;
        public DateTime? LastProbe;
        public DateTime? LastLoginAttempt;
        public DateTime? LastLoginSuccess;
        public bool Paused;
        public DateTime? PauseUntil;
        public bool HasCredential;
        public string UserName = string.Empty;
        public int LatencyMs = -1;
        public int LossPercent = 100;
        public NetworkInfo Network = new NetworkInfo();
        public readonly List<int> LatencyHistory = new List<int>();
        public readonly List<string> StatusHistory = new List<string>();

        public string StatusColorKey
        {
            get
            {
                switch (StatusKey)
                {
                    case "online":
                    case "login-ok": return "green";
                    case "paused": return "gray";
                    case "no-credential":
                    case "bad-credential":
                    case "login-failed":
                    case "unreachable": return "red";
                    default: return "amber";
                }
            }
        }
    }

    /// <summary>
    /// 自动登录引擎：常驻后台线程，按“平时少触发、断网快触发”的策略循环。
    /// 只要本地探测能通就完全不碰 Portal；只有探测彻底不通时才查询状态并登录。
    /// </summary>
    public sealed class LoginEngine : IDisposable
    {
        private const int HistoryLength = 60;
        private const int ReloginWaitSec = 3;
        private const int PersistMinIntervalSeconds = 60;

        private readonly object _gate = new object();
        private readonly Logger _log;
        private readonly ManualResetEventSlim _wake = new ManualResetEventSlim(false);

        private AppConfig _config;
        private Credential _credential;
        private AppState _state;
        private PortalClient _portal;
        private EngineSnapshot _snapshot = new EngineSnapshot();
        private Thread _worker;
        private volatile bool _stop;
        private bool _pendingRelogin;

        private DateTime _lastPersistUtc = DateTime.MinValue;
        private string _persistedStatusKey;
        private bool _persistedOnline;
        private bool _persistedPaused;
        private int _persistedFailureCount;
        private int _persistedLoginCount;

        public LoginEngine(Logger log)
        {
            _log = log;
            Reload();
            RebuildSnapshot();
        }

        /// <summary>状态发生实质变化时触发（后台线程）。</summary>
        public event Action<EngineSnapshot> StatusChanged;

        public AppConfig Config { get { return _config; } }

        public void Reload()
        {
            lock (_gate)
            {
                _config = AppConfig.Load(AppPaths.ConfigFile);
                _portal = new PortalClient(_config);
                try { _credential = CredentialStore.Load(AppPaths.CredentialFile); }
                catch (Exception ex) { _credential = null; _log.Error("读取凭据失败（凭据与当前 Windows 用户绑定，换用户后需要重新保存）：" + ex.Message); }
                _state = AppState.Load(AppPaths.StateFile);
                ResetPersistGate();
            }
        }

        /// <summary>让下一次持久化真正落盘（配置 / 凭据 / 暂停状态变化后调用）。</summary>
        private void ResetPersistGate()
        {
            _lastPersistUtc = DateTime.MinValue;
            _persistedStatusKey = null;
        }

        public void Start()
        {
            if (_worker != null) { return; }
            _worker = new Thread(Worker);
            _worker.IsBackground = true;
            _worker.Name = "CampusNet-Engine";
            _worker.Start();
        }

        public void Dispose()
        {
            _stop = true;
            try { _wake.Set(); } catch { }
            Thread worker = _worker;
            if (worker != null)
            {
                try { worker.Join(3000); } catch { }
            }
        }

        /// <summary>立即重连：注销当前会话后重新登录。</summary>
        public void Relogin()
        {
            lock (_gate) { _pendingRelogin = true; }
            _log.Info("用户手动触发“立即重连”，将在下一次检查时注销并重新登录。");
            _wake.Set();
        }

        /// <summary>立即进行一次检查（探测 + 必要时登录）。</summary>
        public void CheckNow()
        {
            _wake.Set();
        }

        public void Pause(TimeSpan? duration)
        {
            lock (_gate)
            {
                _state.Paused = true;
                _state.PauseUntil = duration.HasValue ? AppPaths.FormatTime(DateTime.Now + duration.Value) : string.Empty;
                _state.Save(AppPaths.StateFile);
                ResetPersistGate();
            }
            _log.Warn(duration.HasValue
                ? "已暂停自动登录，约 " + Math.Round(duration.Value.TotalMinutes) + " 分钟后自动恢复。"
                : "已暂停自动登录，直到手动恢复。");
            _wake.Set();
        }

        public void Resume()
        {
            lock (_gate)
            {
                if (!_state.Paused) { return; }
                _state.Paused = false;
                _state.PauseUntil = string.Empty;
                _state.Save(AppPaths.StateFile);
                ResetPersistGate();
            }
            _log.Info("已恢复自动登录。");
            _wake.Set();
        }

        public bool IsPaused
        {
            get { lock (_gate) { return _state.Paused; } }
        }

        public EngineSnapshot Snapshot()
        {
            lock (_gate)
            {
                var copy = new EngineSnapshot();
                EngineSnapshot from = _snapshot;
                copy.StatusKey = from.StatusKey;
                copy.StatusText = from.StatusText;
                copy.Online = from.Online;
                copy.LastResult = from.LastResult;
                copy.LastMessage = from.LastMessage;
                copy.LastError = from.LastError;
                copy.ProbeSummary = from.ProbeSummary;
                copy.ConsecutiveFailures = from.ConsecutiveFailures;
                copy.LoginWindowCount = from.LoginWindowCount;
                copy.RunCount = from.RunCount;
                copy.LastTrigger = from.LastTrigger;
                copy.LastProbe = from.LastProbe;
                copy.LastLoginAttempt = from.LastLoginAttempt;
                copy.LastLoginSuccess = from.LastLoginSuccess;
                copy.Paused = from.Paused;
                copy.PauseUntil = from.PauseUntil;
                copy.HasCredential = from.HasCredential;
                copy.UserName = from.UserName;
                copy.LatencyMs = from.LatencyMs;
                copy.LossPercent = from.LossPercent;
                copy.Network = from.Network;
                copy.LatencyHistory.AddRange(from.LatencyHistory);
                copy.StatusHistory.AddRange(from.StatusHistory);
                return copy;
            }
        }

        /// <summary>不触发任何登录动作，只做一次本地探测并刷新快照，供诊断使用。</summary>
        public void PrimeForDisplay()
        {
            RebuildSnapshot();
            ProbeOutcome probe = NetworkProbe.Probe(_config, 1, 0);
            UpdateNetwork(probe);
            Persist(probe.LatencyMs, probe.LossPercent);
            SetStatus(probe.Online ? "online" : "unreachable",
                probe.Online ? "在线（延迟 " + probe.LatencyMs + " ms）" : "当前探测不通");
        }

        private void Worker()
        {
            while (!_stop)
            {
                // 先清掉唤醒信号，再去评估：避免「评估结束到开始等待」之间到达的唤醒被丢掉，
                // 那样会白等一个完整周期（例如手动「立即重连」要等 20 秒才生效）。
                try { _wake.Reset(); } catch { }
                int waitSeconds;
                try
                {
                    waitSeconds = Evaluate();
                }
                catch (Exception ex)
                {
                    _log.Error("内部异常：" + ex.Message);
                    foreach (string line in ex.ToString().Split(new[] { '\r', '\n' }, StringSplitOptions.RemoveEmptyEntries))
                    {
                        _log.Error("异常堆栈：" + line.Trim());
                    }
                    waitSeconds = 30;
                }
                if (_stop) { break; }
                try { _wake.Wait(TimeSpan.FromSeconds(Math.Max(1, waitSeconds))); } catch { }
            }
        }

        private int Evaluate()
        {
            DateTime now = DateTime.Now;
            bool relogin;
            AppConfig config;
            Credential credential;
            lock (_gate)
            {
                relogin = _pendingRelogin;
                _pendingRelogin = false;
                config = _config;
                credential = _credential;
                _state.RunCount++;
                _state.LastTrigger = AppPaths.FormatTime(now);
            }

            // ---------- 暂停 ----------
            if (_state.Paused)
            {
                DateTime? until = _state.PauseUntilTime;
                if (until.HasValue && now >= until.Value)
                {
                    lock (_gate) { _state.Paused = false; _state.PauseUntil = string.Empty; }
                    _log.Info("暂停时间结束，恢复自动登录。");
                }
                else
                {
                    SetStatus("paused", until.HasValue
                        ? "已暂停，约 " + Remaining(until.Value) + " 后恢复"
                        : "已暂停（手动恢复）");
                    Persist(0, 100);
                    return 20;
                }
            }

            // ---------- 探测（不发任何 Portal 请求）----------
            ProbeOutcome probe = NetworkProbe.Probe(config, 1, 0);
            // 联网状态发生翻转时立即刷新网卡信息缓存，平时走短时缓存，不每轮枚举网卡
            if (probe.Online != _state.Online) { NetworkProbe.InvalidateNetworkInfo(); }
            UpdateNetwork(probe);
            _state.LastProbe = AppPaths.FormatTime(now);

            if (probe.Online && !relogin)
            {
                OnOnline(probe, "网络正常");
                Persist(probe.LatencyMs, probe.LossPercent);
                return config.OnlineProbeSeconds;
            }

            if (!probe.Online)
            {
                // 快速复检：断网瞬间往往是抖动，连续几次都不通才动手
                ProbeOutcome confirm = NetworkProbe.Probe(config, config.ConfirmAttempts, config.ConfirmGapMs);
                UpdateNetwork(confirm);
                if (confirm.Online)
                {
                    OnOnline(confirm, "网络正常（刚才只是抖动）");
                    Persist(confirm.LatencyMs, confirm.LossPercent);
                    return config.OnlineProbeSeconds;
                }
                probe = confirm;
            }

            // ---------- 凭据（缺凭据时不查 Portal，避免无意义的请求）----------
            if (credential == null || string.IsNullOrEmpty(credential.Password))
            {
                SetStatus("no-credential", "网络不通，但还没保存账号密码");
                _log.WarnOnce("no-credential", "尚未保存校园网账号密码，请在本窗口填写后点击“保存账号密码”。");
                Persist(probe.LatencyMs, probe.LossPercent);
                return 30;
            }

            // ---------- 探测不通：只有这时才查询 Portal ----------
            StatusResult status = _portal.GetStatus();
            if (!status.Reachable)
            {
                SetStatus("unreachable", "连不上校园网，等待网络恢复");
                _log.WarnOnce("unreachable", "探测与 Portal 都不通，暂不尝试登录：" + status.Error);
                Persist(probe.LatencyMs, probe.LossPercent);
                return config.OfflineProbeSeconds;
            }

            if (status.Online && !relogin)
            {
                SetStatus("upstream", "本机探测不通，但 Portal 显示账号在线");
                _log.WarnOnce("upstream", "本地探测全部失败，但 Portal 显示账号仍在线（可能是上游故障或网卡问题），暂不登录。");
                Persist(probe.LatencyMs, probe.LossPercent);
                return config.UpstreamProbeSeconds;
            }

            return LoginFlow(probe, status, relogin);
        }

        private int LoginFlow(ProbeOutcome probe, StatusResult status, bool relogin)
        {
            DateTime now = DateTime.Now;
            AppConfig config = _config;
            Credential credential = _credential;

            if (relogin)
            {
                _log.Info("立即重连：先注销当前会话。");
                bool loggedOut = _portal.Logout();
                if (loggedOut)
                {
                    _log.Info("注销成功，等待 " + ReloginWaitSec + " 秒（Portal 要求至少 3 秒）。");
                    Thread.Sleep(ReloginWaitSec * 1000);
                }
                else
                {
                    _log.Warn("注销未成功，继续尝试直接登录。");
                }
            }

            // 闸门 1：两次登录之间的最小间隔
            if (config.LoginMinIntervalSeconds > 0)
            {
                DateTime? reference = _state.LastLoginAttemptTime;
                DateTime? lastSuccess = _state.LastLoginSuccessTime;
                if (lastSuccess.HasValue && (!reference.HasValue || lastSuccess.Value > reference.Value)) { reference = lastSuccess; }
                if (reference.HasValue)
                {
                    double elapsed = (now - reference.Value).TotalSeconds;
                    if (elapsed < config.LoginMinIntervalSeconds)
                    {
                        int wait = (int)Math.Ceiling(config.LoginMinIntervalSeconds - elapsed);
                        SetStatus("login-wait", "刚登录过，约 " + wait + " 秒后再试");
                        Persist(probe.LatencyMs, probe.LossPercent);
                        return Math.Max(5, wait);
                    }
                }
            }

            // 闸门 2：每小时登录次数上限
            if (config.LoginHourlyLimit > 0)
            {
                DateTime? windowStart = _state.LoginWindowStartTime;
                if (!windowStart.HasValue || (now - windowStart.Value).TotalHours >= 1)
                {
                    _state.LoginWindowStart = AppPaths.FormatTime(now);
                    _state.LoginWindowCount = 0;
                    windowStart = now;
                }
                if (_state.LoginWindowCount >= config.LoginHourlyLimit)
                {
                    int waitMinutes = (int)Math.Ceiling(60 - (now - windowStart.Value).TotalMinutes);
                    if (waitMinutes < 1) { waitMinutes = 1; }
                    SetStatus("login-throttled", "1 小时内已登录 " + _state.LoginWindowCount + " 次，约 " + waitMinutes + " 分钟后恢复");
                    _log.WarnOnce("login-throttled", "最近 1 小时登录次数已达上限（" + config.LoginHourlyLimit + " 次），为避免风控本次不登录。");
                    Persist(probe.LatencyMs, probe.LossPercent);
                    return Math.Max(10, waitMinutes * 60 / 4);
                }
            }

            // 闸门 3：登录前二次确认
            if (config.LoginConfirmDelaySec > 0 && !relogin)
            {
                Thread.Sleep(config.LoginConfirmDelaySec * 1000);
                StatusResult confirm = _portal.GetStatus();
                if (!confirm.Reachable)
                {
                    SetStatus("unreachable", "连不上校园网，等待网络恢复");
                    Persist(probe.LatencyMs, probe.LossPercent);
                    return config.OfflineProbeSeconds;
                }
                if (confirm.Online)
                {
                    OnOnline(probe, "复检时已在线，无需登录");
                    Persist(probe.LatencyMs, probe.LossPercent);
                    return config.OnlineProbeSeconds;
                }
            }

            // ---------- 提交登录 ----------
            SetStatus("login-attempt", "检测到掉线，正在登录…");
            Persist(probe.LatencyMs, probe.LossPercent);

            if (config.LoginHourlyLimit > 0)
            {
                lock (_gate)
                {
                    _state.LoginWindowCount++;
                    _state.LastLoginAttempt = AppPaths.FormatTime(now);
                }
            }
            else
            {
                lock (_gate) { _state.LastLoginAttempt = AppPaths.FormatTime(now); }
            }

            bool success = false;
            string lastMessage = string.Empty;
            string limitReason = string.Empty;
            for (int attempt = 1; attempt <= config.RetryCount; attempt++)
            {
                _log.Info("第 " + attempt + "/" + config.RetryCount + " 次尝试登录（账号 " + credential.UserName + "）。");
                PortalLoginResult result = _portal.Login(credential.UserName, credential.Password);
                lastMessage = result.Message;

                if (result.Success)
                {
                    Thread.Sleep(2000);
                    StatusResult after = _portal.GetStatus();
                    if (after.Online || !after.Reachable)
                    {
                        success = true;
                        break;
                    }
                    _log.Warn("登录接口返回成功，但复检仍未在线。");
                }
                else if (result.AlreadyOnline)
                {
                    _log.Warn("Portal 提示账号已在别处在线：" + result.Message);
                    Thread.Sleep(2000);
                    StatusResult after = _portal.GetStatus();
                    if (after.Reachable && after.Online)
                    {
                        success = true;
                        break;
                    }
                    limitReason = "重复认证冲突（Portal 提示账号已在别处在线，本机复检仍不在线）";
                    _log.Warn("复检仍未在线，判定为重复认证冲突，本次不再重试登录。");
                    break;
                }
                else if (result.RateLimited)
                {
                    limitReason = "Portal 明确限流（请求过于频繁）";
                    _log.Warn("Portal 明确限流：" + result.Message + "，不再重试。");
                    break;
                }
                else
                {
                    _log.Error("登录失败（第 " + attempt + " 次尝试）：" + result.Message);
                }

                if (attempt < config.RetryCount) { Thread.Sleep(2000); }
            }

            if (success)
            {
                lock (_gate)
                {
                    _state.Online = true;
                    _state.LastResult = "login-ok";
                    _state.LastError = string.Empty;
                    _state.LastMessage = "自动登录成功";
                    _state.ConsecutiveFailures = 0;
                    _state.LastLoginSuccess = AppPaths.FormatTime(DateTime.Now);
                }
                _log.Info("自动登录成功，网络已恢复。");
                SetStatus("online", "在线（刚刚自动登录）");
                Persist(-1, 0);
                return config.OnlineProbeSeconds;
            }

            lock (_gate) { _state.ConsecutiveFailures++; }
            if (!string.IsNullOrEmpty(limitReason))
            {
                // 限流 / 重复认证冲突：不做冷却，只记原因；后续按最小间隔与每小时上限的节奏继续尝试
                string key = limitReason.StartsWith("Portal 明确限流", StringComparison.Ordinal)
                    ? "login-throttled"
                    : "login-conflict";
                string text = key == "login-throttled"
                    ? "Portal 限流，稍后按节奏重试"
                    : "重复认证冲突，稍后按节奏重试";
                _log.Warn(limitReason + "；本次不重试，将按最小间隔 " + config.LoginMinIntervalSeconds
                    + " 秒、每小时上限 " + config.LoginHourlyLimit + " 次的节奏继续尝试。");
                lock (_gate)
                {
                    _state.Online = false;
                    _state.LastError = limitReason + "：" + lastMessage;
                    _state.LastMessage = limitReason;
                    _state.LastResult = key;
                }
                SetStatus(key, text);
            }
            else
            {
                _log.Error("自动登录失败（已连续失败 " + _state.ConsecutiveFailures + " 次）：" + lastMessage);
                lock (_gate)
                {
                    _state.Online = false;
                    _state.LastError = lastMessage;
                    _state.LastMessage = lastMessage;
                    _state.LastResult = "login-failed";
                }
                SetStatus("login-failed", "自动登录失败：" + Shorten(lastMessage));
            }
            Persist(probe.LatencyMs, probe.LossPercent);
            return Math.Max(5, config.OfflineProbeSeconds);
        }

        private void OnOnline(ProbeOutcome probe, string message)
        {
            bool wasOnline = _state.Online;
            lock (_gate)
            {
                _state.Online = true;
                _state.LastResult = "online";
                _state.LastError = string.Empty;
                _state.LastMessage = message;
                _state.ConsecutiveFailures = 0;
            }
            if (!wasOnline) { _log.Info("网络已恢复：" + message + "（" + probe.Summary + "）。"); }
            SetStatus("online", "在线（延迟 " + (probe.LatencyMs < 0 ? "未知" : probe.LatencyMs + " ms") + "）");
        }

        private void UpdateNetwork(ProbeOutcome probe)
        {
            NetworkInfo info = NetworkProbe.GetNetworkInfo();
            lock (_gate)
            {
                _snapshot.Network = info;
                _snapshot.LatencyMs = probe.LatencyMs;
                _snapshot.LossPercent = probe.LossPercent;
                _snapshot.ProbeSummary = probe.Summary;
                _snapshot.LatencyHistory.Add(probe.Online ? probe.LatencyMs : -1);
                while (_snapshot.LatencyHistory.Count > HistoryLength) { _snapshot.LatencyHistory.RemoveAt(0); }
            }
        }

        private void SetStatus(string key, string text)
        {
            bool changed;
            lock (_gate)
            {
                changed = _snapshot.StatusKey != key;
                _snapshot.StatusKey = key;
                _snapshot.StatusText = text;
                _snapshot.LastResult = key;
                _snapshot.Online = _state.Online;
                _snapshot.LastMessage = _state.LastMessage;
                _snapshot.LastError = _state.LastError;
            }
            if (!changed) { return; }
            lock (_gate)
            {
                _snapshot.StatusHistory.Add(key);
                while (_snapshot.StatusHistory.Count > HistoryLength) { _snapshot.StatusHistory.RemoveAt(0); }
            }
            var handler = StatusChanged;
            if (handler != null) { try { handler(Snapshot()); } catch { } }
        }

        private void Persist(int latencyMs, int lossPercent)
        {
            lock (_gate)
            {
                _state.Version = AppPaths.Version;
                // state.json 写入节流：状态实质变化时立刻写，否则最多每 60 秒写一次，
                // 避免常驻进程每 20 秒就落盘一次（SSD 写入与磁盘抖动）。内存快照不受影响。
                bool changed = _persistedStatusKey == null
                    || !string.Equals(_persistedStatusKey, _state.LastResult, StringComparison.Ordinal)
                    || _persistedOnline != _state.Online
                    || _persistedPaused != _state.Paused
                    || _persistedFailureCount != _state.ConsecutiveFailures
                    || _persistedLoginCount != _state.LoginWindowCount;
                if (changed || (DateTime.UtcNow - _lastPersistUtc).TotalSeconds >= PersistMinIntervalSeconds)
                {
                    try { _state.Save(AppPaths.StateFile); } catch { }
                    _lastPersistUtc = DateTime.UtcNow;
                    _persistedStatusKey = _state.LastResult;
                    _persistedOnline = _state.Online;
                    _persistedPaused = _state.Paused;
                    _persistedFailureCount = _state.ConsecutiveFailures;
                    _persistedLoginCount = _state.LoginWindowCount;
                }
                _snapshot.LastResult = _state.LastResult;
                _snapshot.Online = _state.Online;
                _snapshot.LastMessage = _state.LastMessage;
                _snapshot.LastError = _state.LastError;
                _snapshot.ConsecutiveFailures = _state.ConsecutiveFailures;
                _snapshot.LoginWindowCount = _state.LoginWindowCount;
                _snapshot.RunCount = _state.RunCount;
                _snapshot.LastTrigger = AppPaths.ParseTime(_state.LastTrigger);
                _snapshot.LastProbe = _state.LastProbeTime;
                _snapshot.LastLoginAttempt = _state.LastLoginAttemptTime;
                _snapshot.LastLoginSuccess = _state.LastLoginSuccessTime;
                _snapshot.Paused = _state.Paused;
                _snapshot.PauseUntil = _state.PauseUntilTime;
                _snapshot.HasCredential = _credential != null && _credential.IsUsable;
                _snapshot.UserName = _credential != null ? _credential.UserName : string.Empty;
                if (latencyMs >= 0) { _snapshot.LatencyMs = latencyMs; }
                if (lossPercent >= 0) { _snapshot.LossPercent = lossPercent; }
            }
        }

        private void RebuildSnapshot()
        {
            lock (_gate)
            {
                _snapshot.StatusKey = "starting";
                _snapshot.StatusText = "正在启动…";
                _snapshot.HasCredential = _credential != null && _credential.IsUsable;
                _snapshot.UserName = _credential != null ? _credential.UserName : string.Empty;
                _snapshot.Paused = _state.Paused;
                _snapshot.PauseUntil = _state.PauseUntilTime;
                _snapshot.LastLoginSuccess = _state.LastLoginSuccessTime;
                _snapshot.LastProbe = _state.LastProbeTime;
                _snapshot.LastTrigger = AppPaths.ParseTime(_state.LastTrigger);
                _snapshot.ConsecutiveFailures = _state.ConsecutiveFailures;
                _snapshot.LoginWindowCount = _state.LoginWindowCount;
                _snapshot.RunCount = _state.RunCount;
            }
        }

        private static string Remaining(DateTime? until)
        {
            if (!until.HasValue) { return "未知"; }
            TimeSpan span = until.Value - DateTime.Now;
            if (span.TotalSeconds <= 0) { return "0 秒"; }
            if (span.TotalMinutes >= 1) { return ((int)Math.Ceiling(span.TotalMinutes)).ToString(CultureInfo.InvariantCulture) + " 分钟"; }
            return ((int)Math.Ceiling(span.TotalSeconds)).ToString(CultureInfo.InvariantCulture) + " 秒";
        }

        private static string Shorten(string text)
        {
            if (string.IsNullOrEmpty(text)) { return string.Empty; }
            return text.Length > 160 ? text.Substring(0, 160) : text;
        }
    }

    /// <summary>让“同一种状态只记一次日志”，避免日志被刷屏。</summary>
    internal static class LoggerExtensions
    {
        private static readonly Dictionary<string, string> LastKeys = new Dictionary<string, string>();
        private static readonly object Gate = new object();

        public static void WarnOnce(this Logger logger, string key, string message)
        {
            lock (Gate)
            {
                string previous;
                if (LastKeys.TryGetValue(key, out previous) && previous == message) { return; }
                LastKeys[key] = message;
            }
            logger.Warn(message);
        }
    }
}
