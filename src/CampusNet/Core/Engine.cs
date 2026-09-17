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
        public string LastSessionCheck = string.Empty;
        public string LastSessionResult = string.Empty;
        public bool Paused;
        public DateTime? PauseUntil;
        public int IgnoredPrompts;
        public string LastIgnoredPrompt = string.Empty;
        public string LastForcedRelogin = string.Empty;
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
                    case "config-invalid":
                    case "probe-config":
                    case "unreachable": return "red";
                    // 其余（含 verifying / tcp-only / session-check / login-wait / login-throttled）统一为黄色
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
        /// <summary>连续多少轮拿不到内容校验才认定「疑似掉线」并发起 Portal 核对（配合 20 秒节奏约 40 秒）。</summary>
        private const int SuspectStreakForVerify = 2;
        /// <summary>疑似掉线期间向 Portal 求证的最小间隔，避免每一轮都去打扰 Portal。</summary>
        private const int SuspectVerifyMinSeconds = 60;
        /// <summary>忽略 Portal 业务提示后的复检节奏：3 / 5 / 12 秒，累计约 20 秒。</summary>
        private const int RecoveryFirstDelaySec = 3;
        private const int RecoverySecondDelaySec = 5;
        private const int RecoveryThirdDelaySec = 12;

        private readonly object _gate = new object();
        private readonly Logger _log;
        private readonly ManualResetEventSlim _wake = new ManualResetEventSlim(false);

        private AppConfig _config;
        private Credential _credential;
        private readonly AppState _state = new AppState();
        private PortalClient _portal;
        private EngineSnapshot _snapshot = new EngineSnapshot();
        private Thread _worker;
        private volatile bool _stop;
        private bool _pendingRelogin;
        /// <summary>本次启动（或最近一次配置重载）的时间，用作会话核对的初始锚点。</summary>
        private DateTime _startedAt = DateTime.Now;
        /// <summary>连续多少轮内容校验没过（单次抖动会被补测挡掉，不计入）。</summary>
        private int _suspectStreak;
        /// <summary>本轮「疑似掉线」从什么时候开始的，用于判断是否属于「残留会话挡路」。</summary>
        private DateTime? _suspectSince;
        /// <summary>上一次因为「疑似掉线」主动向 Portal 求证的时间。</summary>
        private DateTime? _lastSuspectVerifyUtc;
        /// <summary>本轮疑似掉线是否已经自动注销重登过一次（避免热循环）。</summary>
        private bool _stuckReloginRequested;

        private DateTime _lastPersistUtc = DateTime.MinValue;
        private string _persistedStatusKey;
        private bool _persistedOnline;
        private bool _persistedPaused;
        private int _persistedFailureCount;
        private int _persistedLoginCount;
        private string _persistedSessionCheck;
        private int _persistedIgnoredPrompts;
        private string _persistedForcedRelogin;

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
            // 先在锁外把新的一整套读出来（读盘慢），再在锁里一次性换上。
            // 后台线程每一轮开头会把它们抓成局部变量，于是每一轮评估要么全程用旧的、
            // 要么全程用新的，不会出现「旧凭据 + 新 Portal」这种半截状态。
            AppConfig config = AppConfig.Load(AppPaths.ConfigFile);
            var portal = new PortalClient(config);
            Credential credential;
            try { credential = CredentialStore.Load(AppPaths.CredentialFile); }
            catch (Exception ex)
            {
                credential = null;
                _log.Error("读取凭据失败（凭据与当前 Windows 用户绑定，换用户后需要重新保存）：" + ex.Message);
            }
            AppState loaded = AppState.Load(AppPaths.StateFile);

            lock (_gate)
            {
                _config = config;
                _portal = portal;
                _credential = credential;
                // 脱敏只认「当前这套凭据」：换账号后旧账号不该再被当成敏感词，新账号必须立刻受保护。
                Redact.SetSecrets(credential != null ? credential.UserName : string.Empty,
                    credential != null ? credential.Password : string.Empty);
                // 状态对象永远不换新的：后台线程正握着自己的引用往状态里写，
                // 换掉对象会让这一轮结果写进被丢弃的对象（状态丢失，甚至用旧内容覆盖状态文件）。
                _state.CopyFrom(loaded);
                _snapshot.HasCredential = credential != null && credential.IsUsable;
                _snapshot.UserName = credential != null ? credential.UserName : string.Empty;
                ResetPersistGate();
                _startedAt = DateTime.Now;
            }
        }

        /// <summary>让下一次持久化真正落盘（配置 / 凭据 / 暂停状态变化后调用）。</summary>
        private void ResetPersistGate()
        {
            _lastPersistUtc = DateTime.MinValue;
            _persistedStatusKey = null;
        }

        /// <summary>
        /// 把一次「真正提交出去的登录请求」计入本小时窗口。
        /// 关键：按请求计数，而不是按「一次登录流程」计数——否则 RetryCount 调大后
        /// 3 次请求只算 1 次，12 次/小时的上限会被悄悄放大成 36 次。
        /// </summary>
        private int CountLoginAttempt(DateTime now)
        {
            lock (_gate)
            {
                DateTime? windowStart = _state.LoginWindowStartTime;
                if (!windowStart.HasValue || (now - windowStart.Value).TotalHours >= 1)
                {
                    _state.LoginWindowStart = AppPaths.FormatTime(now);
                    _state.LoginWindowCount = 0;
                }
                _state.LoginWindowCount++;
                _state.LastLoginAttempt = AppPaths.FormatTime(now);
                return _state.LoginWindowCount;
            }
        }

        /// <summary>本小时窗口内已经提交了多少次登录（窗口过期返回 0）。</summary>
        private int HourWindowCount(DateTime now)
        {
            lock (_gate)
            {
                DateTime? windowStart = _state.LoginWindowStartTime;
                if (!windowStart.HasValue || (now - windowStart.Value).TotalHours >= 1) { return 0; }
                return _state.LoginWindowCount;
            }
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
                copy.LastSessionCheck = from.LastSessionCheck;
                copy.LastSessionResult = from.LastSessionResult;
                copy.Paused = from.Paused;
                copy.PauseUntil = from.PauseUntil;
                copy.IgnoredPrompts = from.IgnoredPrompts;
                copy.LastIgnoredPrompt = from.LastIgnoredPrompt;
                copy.LastForcedRelogin = from.LastForcedRelogin;
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
            AppConfig config;
            lock (_gate) { config = _config; }
            if (config.Corrupted)
            {
                SetStatus("config-invalid", "配置文件损坏，已停止自动登录");
                return;
            }
            ProbeOutcome probe = NetworkProbe.Probe(config, 1, 0);
            UpdateNetwork(probe);
            if (probe.ConfigError)
            {
                SetStatus("probe-config", "探测目标配置无效，已停止自动登录");
                return;
            }
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
            PortalClient portal;
            lock (_gate)
            {
                relogin = _pendingRelogin;
                _pendingRelogin = false;
                config = _config;
                credential = _credential;
                portal = _portal;
                _state.RunCount++;
                _state.LastTrigger = AppPaths.FormatTime(now);
            }

            // ---------- 配置体检：损坏时必须停下来 ----------
            if (config.Corrupted)
            {
                lock (_gate)
                {
                    _state.Online = false;
                    _state.LastResult = "config-invalid";
                    _state.LastMessage = "配置文件损坏，已停止自动登录";
                    _state.LastError = "配置文件无法解析：" + config.CorruptedReason;
                }
                SetStatus("config-invalid", "配置文件损坏，已停止自动登录");
                _log.WarnOnce("config-invalid", "配置文件无法解析（" + config.CorruptedReason + "），已停止自动登录："
                    + "配置读失败时会退回默认 Portal，继续登录有把账号密码发到错误地址的风险。请检查 " + AppPaths.ConfigFile);
                Persist(-1, -1);
                return 60;
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
            if (probe.ConfigError)
            {
                // 探测目标全非法：既不敢当在线（自动登录会永远不触发），
                // 也不该拿着坏配置去反复登录，只能停下来把问题摆到用户面前。
                lock (_gate)
                {
                    _state.Online = false;
                    _state.LastResult = "probe-config";
                    _state.LastMessage = "探测目标配置无效，已停止自动登录";
                    _state.LastError = "ProbeTargets 里没有任何一条合法目标";
                }
                SetStatus("probe-config", "探测目标配置无效，已停止自动登录");
                _log.WarnOnce("probe-config", "探测目标（ProbeTargets）里没有任何一条合法目标，无法判断网络是否正常，"
                    + "已停止自动登录。请在 config.json 或「高级设置」里修正探测目标（例如 http:connect.rom.miui.com/generate_204|204）。");
                Persist(-1, 100);
                return 60;
            }
            // 联网状态发生翻转时立即刷新网卡信息缓存，平时走短时缓存，不每轮枚举网卡
            if (probe.Online != _state.Online) { NetworkProbe.InvalidateNetworkInfo(); }
            UpdateNetwork(probe);
            _state.LastProbe = AppPaths.FormatTime(now);

            if (probe.Online && !relogin)
            {
                // 「TCP 能连」不等于「能上网」：有的网关会替任意地址代答 TCP 握手，
                // 账号被踢下线后本地探测照样 0 ms 连上，于是程序永远以为在线。
                // 只要配置了内容校验目标却没通过，就必须向 Portal 求证一次。
                bool suspect = probe.HasVerifiedTargets && !probe.Verified;
                if (suspect)
                {
                    // 第二次机会：TCP 已经通了，说明很可能只是这一次内容校验超时/抖动。
                    // 立刻补测同一条目标，成功就直接按「在线」处理（0 个 Portal 请求）。
                    int retryLatency;
                    if (NetworkProbe.ContentCheck(config, out retryLatency))
                    {
                        probe.Verified = true;
                        if (retryLatency >= 0) { probe.LatencyMs = retryLatency; }
                        suspect = false;
                        UpdateNetwork(probe);
                        _log.Info("内容校验第一次没过、补测通过（" + (retryLatency < 0 ? "未知" : retryLatency + " ms")
                            + "），判定为一次抖动，不打扰 Portal。");
                    }
                }

                if (suspect)
                {
                    // 连续两轮（约 40 秒）都拿不到内容校验才算「疑似掉线」：单次抖动不再改状态。
                    _suspectStreak++;
                    if (!_suspectSince.HasValue) { _suspectSince = now; }
                }
                else
                {
                    ResetSuspect();
                }

                // 会话核对的锚点：上次核对时间；从没核对过就用本次启动时间，
                // 这样刚启动时既不会立刻发请求，也能在「内容校验失败」时马上求证。
                DateTime anchor = _state.LastSessionCheckTime ?? _startedAt;
                double sinceSession = (now - anchor).TotalSeconds;
                bool sessionDue = config.SessionCheckSeconds > 0 && sinceSession >= config.SessionCheckSeconds;
                bool verifyDue = suspect && _suspectStreak >= SuspectStreakForVerify
                    && (!_lastSuspectVerifyUtc.HasValue
                        || (DateTime.UtcNow - _lastSuspectVerifyUtc.Value).TotalSeconds >= SuspectVerifyMinSeconds);

                if (verifyDue || sessionDue)
                {
                    if (suspect)
                    {
                        _lastSuspectVerifyUtc = DateTime.UtcNow;
                        SetStatus("verifying", "内容校验连续 " + _suspectStreak + " 次没过，正在向 Portal 核对");
                        _log.WarnOnce("verify-content", "TCP 握手成功但内容校验未通过（疑似网关代答或账号已被踢下线），向 Portal 核对一次。");
                    }
                    else
                    {
                        SetStatus("session-check", "正在核对 Portal 会话（在线巡检）");
                    }

                    StatusResult check = portal.GetStatus();
                    RecordSessionCheck(check);

                    if (!check.Reachable)
                    {
                        _log.WarnOnce("session-unreachable", "Portal 暂时不可达，本次跳过会话核对：" + check.Error);
                        SetStatus("online", "在线（Portal 暂时不可达，稍后再核对）");
                        Persist(probe.LatencyMs, probe.LossPercent);
                        return config.OnlineProbeSeconds;
                    }
                    if (!check.Online)
                    {
                        _log.Warn("Portal 会话核对显示账号已离线，立即进入登录流程。");
                        SetStatus("offline-detected", "Portal 显示已离线，准备登录");
                        return LoginFlow(probe, check, false, config, credential, portal);
                    }
                    if (ShouldForceRelogin(config, suspect))
                    {
                        // 本机不通、Portal 却说账号在线 —— 典型的残留会话挡路，
                        // 自动做一次「注销 + 重新登录」（等同手动点「立即重连」）。
                        double stuckSeconds = _suspectSince.HasValue ? (now - _suspectSince.Value).TotalSeconds : 0;
                        ResetSuspect();
                        lock (_gate) { _state.LastForcedRelogin = AppPaths.FormatTime(now); }
                        _log.Warn("本机探测已连续 " + (int)stuckSeconds + " 秒不通，但 Portal 显示账号在线："
                            + "判定为残留会话，自动注销后重新登录。");
                        SetStatus("stuck-relogin", "疑似残留会话，正在注销并重新登录");
                        return LoginFlow(probe, check, true, config, credential, portal);
                    }
                    OnOnline(probe, suspect ? "TCP 可连（内容校验未通过，但 Portal 确认账号在线）" : "网络正常");
                    Persist(probe.LatencyMs, probe.LossPercent);
                    return config.OnlineProbeSeconds;
                }

                if (suspect)
                {
                    // 还没到核对时间：如实说明「只有 TCP 握手通过」，别让界面显示成一切正常
                    SetStatus("tcp-only", "内容校验连续 " + _suspectStreak + " 次没过（疑似网关代答），稍后向 Portal 核对");
                    // 疑似掉线时按「异常」的节奏复测（默认 5 秒），别等满 20 秒才确认第二次，
                    // 否则被踢下线后要拖 40 秒以上才会去核对 Portal。
                    Persist(probe.LatencyMs, probe.LossPercent);
                    return Math.Max(5, config.OfflineProbeSeconds);
                }
                else
                {
                    OnOnline(probe, "网络正常");
                }
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
            StatusResult status = portal.GetStatus();
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

            return LoginFlow(probe, status, relogin, config, credential, portal);
        }

        private int LoginFlow(ProbeOutcome probe, StatusResult status, bool relogin,
            AppConfig config, Credential credential, PortalClient portal)
        {
            DateTime now = DateTime.Now;

            if (relogin)
            {
                _log.Info("立即重连：先注销当前会话。");
                bool loggedOut = portal.Logout();
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
                StatusResult confirm = portal.GetStatus();
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

            bool success = false;
            bool unconfirmed = false;
            string lastMessage = string.Empty;
            string limitReason = string.Empty;
            string ignoredPrompt = string.Empty;
            DateTime lastSubmit = now;
            for (int attempt = 1; attempt <= config.RetryCount; attempt++)
            {
                // 每一次提交都要重新过闸门。RetryCount 只决定「一次触发最多提交几次」，
                // 绝不能变成「几秒内连打 N 次」——那正是被 Portal 风控、甚至把自己会话顶掉的来源。
                if (attempt > 1)
                {
                    if (config.LoginMinIntervalSeconds > 0)
                    {
                        double since = (DateTime.Now - lastSubmit).TotalSeconds;
                        if (since < config.LoginMinIntervalSeconds)
                        {
                            _log.Info("已提交 " + (attempt - 1) + " 次登录，距最小间隔（"
                                + config.LoginMinIntervalSeconds + " 秒）还差 "
                                + (int)Math.Ceiling(config.LoginMinIntervalSeconds - since)
                                + " 秒，本次不再重试，交给下一个周期。");
                            break;
                        }
                    }
                    if (config.LoginHourlyLimit > 0 && HourWindowCount(DateTime.Now) >= config.LoginHourlyLimit)
                    {
                        limitReason = "已达每小时登录上限";
                        _log.Warn("本小时登录次数已达上限（" + config.LoginHourlyLimit + " 次），本次不再重试。");
                        break;
                    }
                }

                // 心跳：登录流程可能长时间占住评估线程（重试多、超时长），
                // 这里每次提交前强制刷一次 state.json，免得守护进程把「正在登录」误判成「卡死」而杀掉重启。
                lock (_gate) { _state.LastTrigger = AppPaths.FormatTime(DateTime.Now); }
                Persist(probe.LatencyMs, probe.LossPercent, true);
                CountLoginAttempt(now);

                _log.Info("第 " + attempt + "/" + config.RetryCount + " 次尝试登录（账号 "
                    + Redact.MaskUser(credential.UserName) + "）。");
                PortalLoginResult result = portal.Login(credential.UserName, credential.Password);
                lastSubmit = DateTime.Now;
                lastMessage = result.Message;
                string how = string.Empty;

                if (result.Success)
                {
                    Thread.Sleep(2000);
                    StatusResult after = portal.GetStatus();
                    // 只有 Portal 明确回答「在线」才算成功。
                    // 老代码写成 after.Online || !after.Reachable：状态接口不可达也当成功，
                    // 于是「Portal 挂了 + 实际上没联上网」会被记成 login-ok，然后长时间不再重试。
                    if (after.Online) { success = true; break; }
                    if (!after.Reachable)
                    {
                        unconfirmed = true;
                        _log.Warn("登录接口返回成功，但状态接口不可达（" + after.Error
                            + "）：无法确认是否真的联网，先按「待确认」处理，不记为登录成功。");
                    }
                    else
                    {
                        _log.Warn("登录接口返回成功，但复检仍未在线，继续做几次轻量复检。");
                    }
                    if (WaitForRecovery(config, portal, out how))
                    {
                        success = true;
                        _log.Info("复检确认网络已恢复（" + how + "）。");
                        break;
                    }
                    // 状态接口本身不通：再打登录接口也没法验证结果，直接进入「待确认」。
                    if (unconfirmed) { break; }
                }
                else if (result.RateLimited)
                {
                    limitReason = "Portal 明确限流（请求过于频繁）";
                    _log.Warn("Portal 明确限流：" + result.Message + "，不再重试。");
                    break;
                }
                else if (result.BusinessPrompt)
                {
                    // 「账号已在别处在线」「密码错误」这类 Portal 业务提示按用户要求完全忽略：
                    // 不当成终止性失败、不计入连续失败、不写「最近错误」，只限频记一行日志后继续重试。
                    ignoredPrompt = result.Message;
                    _log.WarnOnce("portal-prompt:" + lastMessage,
                        "Portal 提示（已忽略，继续按最小间隔重试）：" + lastMessage);
                    if (result.AlreadyOnline || lastMessage.IndexOf("密码", StringComparison.Ordinal) >= 0)
                    {
                        _log.WarnOnce("en-md5-hint",
                            "如果学校 Portal 要求 en_md5=1（密码按 MD5 提交），本工具只按明文提交，"
                            + "会一直收到这类提示；这种情况请改用学校官方客户端。");
                    }
                    if (WaitForRecovery(config, portal, out how))
                    {
                        success = true;
                        _log.Info("Portal 提示已忽略，复检确认网络已恢复（" + how + "）。");
                        break;
                    }
                    // 复检没恢复就别再打第二次登录接口了：这类提示重试没有任何好处
                    // （「账号已在别处在线」再打一次就是把刚建立的会话顶掉），交给最小间隔后的下一个周期。
                    break;
                }
                else
                {
                    // 连不上登录接口、或收到完全无法识别的响应：这才是真正的失败，照实记录。
                    _log.Warn("登录请求未成功：" + lastMessage);
                }

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
                ResetSuspect();
                _log.Info("自动登录成功，网络已恢复。");
                SetStatus("online", "在线（刚刚自动登录）");
                Persist(-1, 0);
                return config.OnlineProbeSeconds;
            }

            if (unconfirmed)
            {
                lock (_gate)
                {
                    _state.Online = false;
                    _state.LastResult = "login-unconfirmed";
                    _state.LastMessage = "登录已提交，但 Portal 状态接口不可达，还没确认";
                    _state.LastError = "登录请求已提交，但状态接口不可达，无法确认是否已联网";
                }
                SetStatus("login-unconfirmed", "登录已提交，等待确认（Portal 状态接口暂时不可达）");
                _log.Warn("本次不记为登录成功（未确认），按 " + Math.Max(5, config.OfflineProbeSeconds) + " 秒的节奏继续复检。");
                Persist(probe.LatencyMs, probe.LossPercent);
                return Math.Max(5, config.OfflineProbeSeconds);
            }

            if (!string.IsNullOrEmpty(limitReason))
            {
                lock (_gate) { _state.ConsecutiveFailures++; }
                // Portal 明确限流：不做冷却，只记原因；后续按最小间隔与每小时上限的节奏继续尝试
                _log.Warn(limitReason + "；本次不重试，将按最小间隔 " + config.LoginMinIntervalSeconds
                    + " 秒、每小时上限 " + config.LoginHourlyLimit + " 次的节奏继续尝试。");
                lock (_gate)
                {
                    _state.Online = false;
                    _state.LastError = limitReason + "：" + lastMessage;
                    _state.LastMessage = limitReason;
                    _state.LastResult = "login-throttled";
                }
                SetStatus("login-throttled", "Portal 限流，稍后按节奏重试");
            }
            else if (!string.IsNullOrEmpty(ignoredPrompt))
            {
                lock (_gate)
                {
                    _state.Online = false;
                    _state.LastResult = "login-retry";
                    _state.LastMessage = "Portal 提示已忽略：" + Shorten(ignoredPrompt);
                    _state.LastError = string.Empty;
                    _state.IgnoredPrompts++;
                    _state.LastIgnoredPrompt = Shorten(ignoredPrompt);
                }
                _log.Warn("Portal 提示已忽略（" + Shorten(ignoredPrompt) + "），继续按最小间隔 "
                    + config.LoginMinIntervalSeconds + " 秒、每小时上限 " + config.LoginHourlyLimit + " 次尝试。");
                SetStatus("login-retry", "登录提示已忽略，继续重试（" + Shorten(ignoredPrompt) + "）");
            }
            else
            {
                lock (_gate) { _state.ConsecutiveFailures++; }
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

        /// <summary>内容校验恢复正常：清空「疑似掉线」状态机。</summary>
        private void ResetSuspect()
        {
            _suspectStreak = 0;
            _suspectSince = null;
            _stuckReloginRequested = false;
        }

        /// <summary>
        /// 「本机探测不通 + Portal 说账号在线」持续超过 StuckReloginSeconds（默认 60 秒）时，
        /// 判定为残留会话挡路：自动注销一次再登录（等同手动点「立即重连」）。
        /// 每轮只做一次，避免陷入热循环。
        /// </summary>
        private bool ShouldForceRelogin(AppConfig config, bool suspect)
        {
            if (!suspect || _stuckReloginRequested) { return false; }
            if (config.StuckReloginSeconds <= 0) { return false; }
            if (!_suspectSince.HasValue) { return false; }
            if ((DateTime.Now - _suspectSince.Value).TotalSeconds < config.StuckReloginSeconds) { return false; }
            _stuckReloginRequested = true;
            return true;
        }

        /// <summary>
        /// 登录返回「账号已在别处在线 / 密码错误」这类提示后，会话往往还要几秒才真正生效。
        /// 按 3 / 5 / 12 秒做几次轻量复检（只读 chkstatus + 本地内容校验），通了就立刻算成功。
        /// </summary>
        private bool WaitForRecovery(AppConfig config, PortalClient portal, out string how)
        {
            how = string.Empty;
            int elapsed = 0;
            int[] waits = new[] { RecoveryFirstDelaySec, RecoverySecondDelaySec, RecoveryThirdDelaySec };
            foreach (int wait in waits)
            {
                Thread.Sleep(Math.Max(1, wait) * 1000);
                elapsed += wait;
                StatusResult status = portal.GetStatus();
                if (status.Reachable && status.Online)
                {
                    how = "Portal 显示账号已在线（+" + elapsed + " 秒）";
                    return true;
                }
                int latency;
                if (NetworkProbe.ContentCheck(config, out latency))
                {
                    how = "本地内容校验通过（+" + elapsed + " 秒）";
                    return true;
                }
            }
            return false;
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

        /// <summary>记录一次「在线会话核对」的结果（只读 chkstatus，绝不触发登录）。</summary>
        private void RecordSessionCheck(StatusResult check)
        {
            string result = !check.Reachable ? "unreachable" : (check.Online ? "online" : "offline");
            lock (_gate)
            {
                _state.LastSessionCheck = AppPaths.FormatTime(DateTime.Now);
                _state.LastSessionResult = result;
                _snapshot.LastSessionCheck = _state.LastSessionCheck;
                _snapshot.LastSessionResult = result;
            }
            if (check.Online) { _log.Info("会话核对：Portal 显示账号在线。"); }
            else if (check.Reachable) { _log.Warn("会话核对：Portal 显示账号不在线。"); }
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

        /// <summary>
        /// 写状态文件（带节流）。force = true 时无视节流立刻落盘，用于「登录流程心跳」这种
        /// 守护进程必须马上看见的时刻。
        /// </summary>
        private void Persist(int latencyMs, int lossPercent, bool force = false)
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
                    || _persistedLoginCount != _state.LoginWindowCount
                    || _persistedIgnoredPrompts != _state.IgnoredPrompts
                    || !string.Equals(_persistedForcedRelogin, _state.LastForcedRelogin, StringComparison.Ordinal)
                    || !string.Equals(_persistedSessionCheck, _state.LastSessionCheck, StringComparison.Ordinal);
                if (force || changed || (DateTime.UtcNow - _lastPersistUtc).TotalSeconds >= PersistMinIntervalSeconds)
                {
                    try { _state.Save(AppPaths.StateFile); } catch { }
                    _lastPersistUtc = DateTime.UtcNow;
                    _persistedStatusKey = _state.LastResult;
                    _persistedOnline = _state.Online;
                    _persistedPaused = _state.Paused;
                    _persistedFailureCount = _state.ConsecutiveFailures;
                    _persistedLoginCount = _state.LoginWindowCount;
                    _persistedIgnoredPrompts = _state.IgnoredPrompts;
                    _persistedForcedRelogin = _state.LastForcedRelogin;
                    _persistedSessionCheck = _state.LastSessionCheck;
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
                _snapshot.LastSessionCheck = _state.LastSessionCheck;
                _snapshot.LastSessionResult = _state.LastSessionResult;
                _snapshot.Paused = _state.Paused;
                _snapshot.PauseUntil = _state.PauseUntilTime;
                _snapshot.IgnoredPrompts = _state.IgnoredPrompts;
                _snapshot.LastIgnoredPrompt = _state.LastIgnoredPrompt;
                _snapshot.LastForcedRelogin = _state.LastForcedRelogin;
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
                _snapshot.IgnoredPrompts = _state.IgnoredPrompts;
                _snapshot.LastIgnoredPrompt = _state.LastIgnoredPrompt;
                _snapshot.LastForcedRelogin = _state.LastForcedRelogin;
                _snapshot.LastLoginSuccess = _state.LastLoginSuccessTime;
                _snapshot.LastSessionCheck = _state.LastSessionCheck;
                _snapshot.LastSessionResult = _state.LastSessionResult;
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
