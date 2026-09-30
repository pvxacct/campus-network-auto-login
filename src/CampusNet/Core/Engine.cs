using System;
using System.Collections.Generic;
using System.Globalization;
using System.Diagnostics;
using System.Threading.Tasks;
using System.Net.NetworkInformation;
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
        public string LastSessionCheckKind = string.Empty;
        public bool Paused;
        public DateTime? PauseUntil;
        public int IgnoredPrompts;
        public string LastIgnoredPrompt = string.Empty;
        public string LastForcedRelogin = string.Empty;
        public bool HasCredential;
        public string UserName = string.Empty;
        public int LatencyMs = -1;
        public int LossPercent = 100;
        /// <summary>已完成的评估轮次编号（每次评估自增一次）。</summary>
        public long EvaluationId;
        /// <summary>是否正有一轮评估在跑（网络请求 / 登录流程进行中）。</summary>
        public bool Busy;
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
    /// 内容校验决定联网状态；会话查询独立确认认证状态，所有登录入口共用限频。
    /// </summary>
    public sealed class LoginEngine : IDisposable
    {
        private const int HistoryLength = 60;
        private const int ReloginWaitSec = 3;
        private const int PersistMinIntervalSeconds = 60;
        /// <summary>系统网络变化事件的防抖窗口：网卡插拔时事件会连成一串，只按最后一次处理。</summary>
        private const int NetworkEventDebounceMs = 1000;
        /// <summary>连续两轮内容校验失败后核对 Portal；异常期间使用 OfflineProbeSeconds。</summary>
        private const int SuspectStreakForVerify = 2;
        /// <summary>
        /// 疑似掉线期间向 Portal 求证的最小间隔：只影响「只读 chkstatus」的发起频率，
        /// 与登录风控无关。20 秒是折中 —— 被踢下线后约 20~40 秒就能发现，又不至于每轮都去打扰 Portal。
        /// </summary>
        private const int SuspectVerifyMinSeconds = 20;
        private const int RecoveryWindowMs = 30000;
        private const int RecoveryProbeIntervalMs = 2000;
        private static readonly int[] RecoveryStatusAtMs = { 2000, 5000, 9000, 14000, 20000, 23000 };

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
        /// <summary>系统网络变化事件的防抖定时器与最近一次事件原因。</summary>
        private Timer _networkEventTimer;
        private bool _networkEventsHooked;
        private volatile string _pendingNetworkEvent;
        /// <summary>评估轮次编号：Evaluate 每跑一轮自增一次，供 --relogin 等外部调用方等待「这一轮跑完」。</summary>
        private long _evaluationId;
        /// <summary>本次启动（或最近一次配置重载）的时间，用作会话核对的初始锚点。</summary>
        private DateTime _startedAt = DateTime.Now;
        /// <summary>连续多少轮内容校验没过（单次抖动会被补测挡掉，不计入）。</summary>
        private int _suspectStreak;
        /// <summary>上一次因为「疑似掉线」主动向 Portal 求证的时间。</summary>
        private DateTime? _lastSuspectVerifyUtc;
        /// <summary>本轮疑似掉线是否已经自动注销重登过一次（避免热循环）。</summary>
        private bool _stuckReloginRequested;

        /// <summary>
        /// 登录观察窗口结束后的最小间隔等待期。期间只做本地探测，
        /// 每个异常探测周期检查本地恢复；历史日志只能证明记录时间，不能证明实际恢复时刻。
        /// </summary>
        private DateTime _loginWaitUntil = DateTime.MinValue;

        private bool _stateLoaded;
        private CancellationTokenSource _evaluationCancel;
        private CancellationToken _operationToken;
        private int _generation;
        private int _runningGeneration;
        private int _operationThreadId;
        private bool _legacySessionOnline;
        private DateTime _upstreamStatusUntilUtc = DateTime.MinValue;
        private Stopwatch _faultWatch;
        private Stopwatch _postWatch;
        private Stopwatch _submitIntervalWatch;

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

        public AppConfig Config { get { lock (_gate) { return _config.Copy(); } } }

        public void Reload()
        {
            // 先在锁外把新的一整套读出来（读盘慢），再在锁里一次性换上。
            // 工作线程持有本轮不可变引用；换配置时取消本轮，防止旧结果覆盖新状态。
            AppConfig config = AppConfig.Load(AppPaths.ConfigFile);
            var portal = new PortalClient(config);
            Credential credential;
            try { credential = CredentialStore.Load(AppPaths.CredentialFile); }
            catch (Exception ex)
            {
                credential = null;
                _log.Error("读取凭据失败（凭据与当前 Windows 用户绑定，换用户后需要重新保存）：" + ex.Message);
            }
            AppState loaded = _stateLoaded ? null : AppState.Load(AppPaths.StateFile);

            lock (_gate)
            {
                bool changedContext = _stateLoaded && (_config.PortalBase != config.PortalBase ||
                    (_credential == null ? "" : _credential.UserName) != (credential == null ? "" : credential.UserName));
                _config = config;
                _portal = portal;
                _credential = credential;
                // 脱敏只认「当前这套凭据」：换账号后旧账号不该再被当成敏感词，新账号必须立刻受保护。
                Redact.SetSecrets(credential != null ? credential.UserName : string.Empty,
                    credential != null ? credential.Password : string.Empty);
                // 只在启动时读取持久状态；热重载不能覆盖工作线程的新计数。
                if (!_stateLoaded) { _state.CopyFrom(loaded); _stateLoaded = true; }
                _generation++;
                if (_evaluationCancel != null) { _evaluationCancel.Cancel(); }
                _legacySessionOnline = false;
                _upstreamStatusUntilUtc = DateTime.MinValue;
                if (changedContext) { _faultWatch = null; _postWatch = null; ResetSuspect(); }
                _snapshot.HasCredential = credential != null && credential.IsUsable;
                _snapshot.UserName = credential != null ? credential.UserName : string.Empty;
                ResetPersistGate();
                _startedAt = DateTime.Now;
                // 换了配置或凭据就重新判断，别把旧的等待窗口带过来。
                _loginWaitUntil = DateTime.MinValue;
            }
        }

        /// <summary>让下一次持久化真正落盘（配置 / 凭据 / 暂停状态变化后调用）。</summary>
        private void ResetPersistGate()
        {
            _lastPersistUtc = DateTime.MinValue;
            _persistedStatusKey = null;
        }

        /// <summary>
        /// 每次 POST 前登记并持久化额度，避免重启丢失限频依据。
        /// 如果在保存后、发送前取消，允许保守多占一次额度；重试逐次计数。
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
                EnsureCurrentOperation();
                _state.LoginWindowCount++;
                _state.LastLoginAttempt = now.ToString("yyyy-MM-dd HH:mm:ss.fff", CultureInfo.InvariantCulture);
                _submitIntervalWatch = Stopwatch.StartNew();
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

        /// <summary>
        /// 等待期与「恢复监视」的轮询间隔：跟随 OfflineProbeSeconds（默认约 5 秒），最低 3 秒。
        /// 这个节奏只影响纯本地探测，不产生任何 Portal 请求。
        /// </summary>
        private static int WatchIntervalSeconds(AppConfig config)
        {
            return Math.Max(3, config.OfflineProbeSeconds);
        }

        public void Start()
        {
            if (_worker != null) { return; }
            SubscribeNetworkChange();
            _worker = new Thread(Worker);
            _worker.IsBackground = true;
            _worker.Name = "CampusNet-Engine";
            _worker.Start();
        }

        public void Dispose()
        {
            lock (_gate)
            {
                _stop = true;
                _generation++;
                if (_evaluationCancel != null) { _evaluationCancel.Cancel(); }
            }
            UnsubscribeNetworkChange();
            try { _wake.Set(); } catch { }
            Thread worker = _worker;
            if (worker != null)
            {
                try { worker.Join(3000); } catch { }
            }
        }

        /// <summary>
        /// 订阅系统网络变化事件（网线插拔 / WiFi 切换 / IP 变化）：事件到达后 1 秒内唤醒工作线程复检一次，
        /// 不用再干等下一个探测周期。事件不绕过任何风控闸门，只是让「发现断网」更快。
        /// </summary>
        private void SubscribeNetworkChange()
        {
            try
            {
                if (_networkEventsHooked) { return; }
                _networkEventTimer = new Timer(OnNetworkEventDebounce, null, Timeout.Infinite, Timeout.Infinite);
                NetworkChange.NetworkAvailabilityChanged += OnNetworkAvailabilityChanged;
                NetworkChange.NetworkAddressChanged += OnNetworkAddressChanged;
                _networkEventsHooked = true;
                _log.Info("已订阅网络变化事件（网线 / WiFi / IP 变化时 1 秒内立即复检）。");
            }
            catch (Exception ex)
            {
                _log.Warn("订阅网络变化事件失败（不影响自动登录，只是发现得更慢）：" + ex.Message);
            }
        }

        private void UnsubscribeNetworkChange()
        {
            if (!_networkEventsHooked) { return; }
            _networkEventsHooked = false;
            try { NetworkChange.NetworkAvailabilityChanged -= OnNetworkAvailabilityChanged; } catch { }
            try { NetworkChange.NetworkAddressChanged -= OnNetworkAddressChanged; } catch { }
            Timer timer = _networkEventTimer;
            _networkEventTimer = null;
            if (timer != null) { try { timer.Dispose(); } catch { } }
        }

        private void OnNetworkAvailabilityChanged(object sender, NetworkAvailabilityEventArgs e)
        {
            QueueNetworkEvent(e.IsAvailable ? "网络可用性变化：已连接" : "网络可用性变化：已断开");
        }

        private void OnNetworkAddressChanged(object sender, EventArgs e)
        {
            QueueNetworkEvent("IP 地址变化");
        }

        private void QueueNetworkEvent(string reason)
        {
            if (_stop || !_networkEventsHooked) { return; }
            _pendingNetworkEvent = reason;
            Timer timer = _networkEventTimer;
            if (timer == null) { return; }
            try { timer.Change(NetworkEventDebounceMs, Timeout.Infinite); } catch { }
        }

        private void OnNetworkEventDebounce(object state)
        {
            if (_stop) { return; }
            string reason = _pendingNetworkEvent;
            _pendingNetworkEvent = null;
            try
            {
                // 网卡信息（IP / 网关 / DNS）一定变了，缓存必须立刻作废，否则界面与诊断还会显示旧地址。
                NetworkProbe.InvalidateNetworkInfo();
                lock (_gate) { _upstreamStatusUntilUtc = DateTime.MinValue; }
                _log.Info("网络变化事件（" + (string.IsNullOrEmpty(reason) ? "未知" : reason) + "）：已刷新网卡信息并立即复检。");
            }
            catch (Exception ex)
            {
                _log.Warn("处理网络变化事件失败：" + ex.Message);
            }
            try { _wake.Set(); } catch { }
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
                _generation++;
                if (_evaluationCancel != null) { _evaluationCancel.Cancel(); }
                _pendingRelogin = false;
                _state.Paused = true;
                _state.LastResult = "paused";
                _snapshot.StatusKey = "paused";
                _snapshot.StatusText = "已暂停自动登录";
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
                copy.LastSessionCheckKind = from.LastSessionCheckKind;
                copy.EvaluationId = from.EvaluationId;
                copy.Busy = from.Busy;
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
            if (probe.Verified) { OnOnline(probe, "联网验证通过"); }
            else { SetStatus(probe.Online ? "tcp-only" : "unreachable", "尚未验证外网连通"); }
            Persist(probe.LatencyMs, probe.LossPercent);
        }

        private void Worker()
        {
            while (!_stop)
            {
                // 先清掉唤醒信号，再去评估：避免「评估结束到开始等待」之间到达的唤醒被丢掉，
                // 那样会白等一个完整周期（例如手动「立即重连」要等 20 秒才生效）。
                try { _wake.Reset(); } catch { }
                int waitSeconds;
                var cycleWatch = Stopwatch.StartNew();
                try
                {
                    waitSeconds = Evaluate();
                }
                catch (OperationCanceledException) { waitSeconds = 1; }
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
                try { _wake.Wait((int)Math.Max(50, waitSeconds * 1000L - cycleWatch.ElapsedMilliseconds)); } catch { }
            }
        }

        /// <summary>
        /// 一轮评估的包装：登记本轮编号与「正在跑」标志，让外部调用方（例如 --relogin）
        /// 能等到自己触发的那一轮真正跑完，而不是按固定秒数猜。
        /// </summary>

        private int Evaluate()
        {
            CancellationTokenSource source;
            lock (_gate)
            {
                source = new CancellationTokenSource();
                _evaluationCancel = source;
                _operationToken = source.Token;
                _runningGeneration = _generation;
                _operationThreadId = Thread.CurrentThread.ManagedThreadId;
                _snapshot.EvaluationId = ++_evaluationId;
                _snapshot.Busy = true;
            }
            try { return EvaluateCore(); }
            finally
            {
                source.Cancel();
                lock (_gate)
                {
                    if (_evaluationCancel == source) { _evaluationCancel = null; }
                    _snapshot.Busy = false;
                    _operationThreadId = 0;
                }
                source.Dispose();
            }
        }

        private void EnsureCurrentOperation()
        {
            if (_operationThreadId != Thread.CurrentThread.ManagedThreadId) { return; }
            _operationToken.ThrowIfCancellationRequested();
            if (_stop || _runningGeneration != _generation) { throw new OperationCanceledException(); }
        }

        private void Delay(int milliseconds)
        {
            if (_operationToken.WaitHandle.WaitOne(Math.Max(0, milliseconds))) { _operationToken.ThrowIfCancellationRequested(); }
            lock (_gate) { EnsureCurrentOperation(); }
        }

        private static bool ContentUsable(ProbeOutcome probe)
        {
            return probe.HasVerifiedTargets && probe.Verified;
        }

        private bool ConnectivityUsable(ProbeOutcome probe)
        {
            return probe.HasVerifiedTargets ? probe.Verified : probe.Online && _legacySessionOnline;
        }

        private void MarkFault()
        {
            lock (_gate)
            {
                EnsureCurrentOperation();
                if (_faultWatch != null) { return; }
                _faultWatch = Stopwatch.StartNew();
                _log.Info("恢复计时：首次发现联网异常，开始监视（不等同于实际断网时刻）。");
            }
        }

        private int EvaluateCore()
        {
            bool relogin;
            AppConfig config;
            Credential credential;
            PortalClient portal;
            lock (_gate)
            {
                EnsureCurrentOperation();
                relogin = _pendingRelogin;
                _pendingRelogin = false;
                config = _config;
                credential = _credential;
                portal = _portal;
                _state.RunCount++;
                _state.LastTrigger = AppPaths.FormatTime(DateTime.Now);
            }
            if (config.Corrupted)
            {
                SetStatus("config-invalid", "配置文件损坏，已停止自动登录");
                _log.WarnOnce("config-invalid", "配置文件无法解析：" + config.CorruptedReason);
                Persist(-1, -1);
                return 60;
            }
            if (_state.Paused)
            {
                DateTime? until = _state.PauseUntilTime;
                if (until.HasValue && DateTime.Now >= until.Value)
                {
                    lock (_gate) { EnsureCurrentOperation(); _state.Paused = false; _state.PauseUntil = string.Empty; }
                }
                else { SetStatus("paused", "已暂停自动登录"); Persist(-1, -1); return 20; }
            }

            ProbeOutcome probe = NetworkProbe.Probe(config, 1, 0, _operationToken);
            EnsureCurrentOperation();
            if (probe.ConfigError)
            {
                SetStatus("probe-config", "探测目标配置无效，已停止自动登录");
                _log.WarnOnce("probe-config", "ProbeTargets 里没有任何一条合法目标，已停止自动登录。");
                Persist(-1, -1);
                return 60;
            }
            if (ConnectivityUsable(probe) != _state.Online) { NetworkProbe.InvalidateNetworkInfo(); }
            UpdateNetwork(probe);
            lock (_gate) { EnsureCurrentOperation(); _state.LastProbe = AppPaths.FormatTime(DateTime.Now); }

            if (!relogin && DateTime.Now < _loginWaitUntil)
            {
                if (ConnectivityUsable(probe))
                {
                    _log.Info("最小间隔等待期内检测到网络恢复（本地探测通过，未发 Portal 请求）。");
                    OnOnline(probe, "联网验证通过");
                    Persist(probe.LatencyMs, probe.LossPercent);
                    return config.OnlineProbeSeconds;
                }
                SetStatus("login-wait", "刚提交过登录，正在监视网络恢复");
                _log.WarnOnce("login-watch", "处于最小间隔等待期：本轮只做本地探测，不发 Portal 请求。");
                Persist(probe.LatencyMs, probe.LossPercent);
                return WatchIntervalSeconds(config);
            }

            if (!relogin && probe.Online && probe.HasVerifiedTargets && !probe.Verified)
            {
                ProbeOutcome retry = NetworkProbe.Probe(config, 2, 300, _operationToken, true);
                EnsureCurrentOperation();
                if (retry.Verified)
                {
                    probe = retry;
                    UpdateNetwork(probe);
                    _log.Info("内容校验第一次没过、补测通过，判定为一次抖动。");
                }
            }

            if (!probe.Online && !relogin)
            {
                probe = NetworkProbe.Probe(config, config.ConfirmAttempts, config.ConfirmGapMs, _operationToken);
                EnsureCurrentOperation();
                UpdateNetwork(probe);
            }

            bool suspect = probe.HasVerifiedTargets && !probe.Verified;
            bool usable = ConnectivityUsable(probe);
            if (suspect || !probe.Online)
            {
                lock (_gate) { EnsureCurrentOperation(); MarkFault(); _suspectStreak++; }
            }
            else if (usable) { ResetSuspect(); }

            DateTime anchor = _state.LastSessionCheckTime ?? _startedAt;
            bool sessionDue = config.SessionCheckSeconds > 0 &&
                (DateTime.Now - anchor).TotalSeconds >= config.SessionCheckSeconds;
            bool verifyDue = suspect && _suspectStreak >= SuspectStreakForVerify &&
                (!_lastSuspectVerifyUtc.HasValue ||
                (DateTime.UtcNow - _lastSuspectVerifyUtc.Value).TotalSeconds >= SuspectVerifyMinSeconds);

            if (!relogin && usable && !sessionDue)
            {
                OnOnline(probe, probe.HasVerifiedTargets ? "联网验证通过" : "探测与会话在线（未验证内容）");
                Persist(probe.LatencyMs, probe.LossPercent);
                return config.OnlineProbeSeconds;
            }
            if (!relogin && probe.Online && suspect && !verifyDue && !sessionDue)
            {
                SetStatus("tcp-only", "仅 TCP 握手通过，等待核对会话");
                Persist(probe.LatencyMs, probe.LossPercent);
                return config.OfflineProbeSeconds;
            }
            if (!relogin && !probe.Online && DateTime.UtcNow < _upstreamStatusUntilUtc &&
                !ShouldForceRelogin(config, true))
            {
                SetStatus("upstream", "会话在线，外网未验证；持续检查本地恢复");
                Persist(probe.LatencyMs, probe.LossPercent);
                return config.OfflineProbeSeconds;
            }
            if (!probe.Online && !HasCredential(credential))
            {
                SetStatus("no-credential", "网络不通，但还没保存账号密码");
                Persist(probe.LatencyMs, probe.LossPercent);
                return 30;
            }
            if (suspect) { lock (_gate) { EnsureCurrentOperation(); _lastSuspectVerifyUtc = DateTime.UtcNow; } }
            StatusResult status = portal.GetStatus(_operationToken);
            EnsureCurrentOperation();
            RecordSessionCheck(status, suspect || !probe.Online ? "suspect" : "periodic");
            if (!status.Reachable)
            {
                if (ContentUsable(probe) && !relogin)
                {
                    OnOnline(probe, "联网验证通过（Portal 暂时不可达）");
                    Persist(probe.LatencyMs, probe.LossPercent);
                    return config.OnlineProbeSeconds;
                }
                SetStatus("unreachable", "Portal 暂时不可达，等待网络恢复");
                _log.WarnOnce("unreachable", "探测与 Portal 都不通，暂不尝试登录：" + status.Error);
                Persist(probe.LatencyMs, probe.LossPercent);
                return config.OfflineProbeSeconds;
            }
            if (relogin) { return LoginFlow(probe, status, true, config, credential, portal); }
            if (!status.Online)
            {
                MarkFault();
                SetStatus("offline-detected", "Portal 显示已离线，准备登录");
                _log.Warn("Portal 会话核对显示账号已离线，立即进入登录流程。");
                return LoginFlow(probe, status, false, config, credential, portal);
            }
            if (ConnectivityUsable(probe))
            {
                OnOnline(probe, probe.HasVerifiedTargets ? "联网验证通过" : "探测与会话在线（未验证内容）");
                Persist(probe.LatencyMs, probe.LossPercent);
                return config.OnlineProbeSeconds;
            }

            MarkFault();
            if (!probe.Online)
            {
                lock (_gate) { EnsureCurrentOperation(); _upstreamStatusUntilUtc = DateTime.UtcNow.AddSeconds(config.UpstreamProbeSeconds); }
            }
            if (ShouldForceRelogin(config, true))
            {
                _log.Warn("联网验证持续未通过，但 Portal 显示会话在线，准备检查是否允许一次残留会话重登。");
                return LoginFlow(probe, status, true, config, credential, portal, true);
            }
            SetStatus("upstream", "会话在线，外网未验证；持续检查本地恢复");
            Persist(probe.LatencyMs, probe.LossPercent);
            return config.OfflineProbeSeconds;
        }

        private static bool HasCredential(Credential credential)
        {
            return credential != null && credential.IsUsable;
        }

        // The same gates protect auto login, forced recovery and manual relogin.
        // In particular, never log out a working session before checking these.
        private bool LoginBlocked(AppConfig config, Credential credential, out int waitSeconds)
        {
            waitSeconds = WatchIntervalSeconds(config);
            lock (_gate)
            {
                EnsureCurrentOperation();
                if (_state.Paused) { SetStatus("paused", "已暂停自动登录"); return true; }
                if (!HasCredential(credential)) { SetStatus("no-credential", "尚未保存有效账号密码"); return true; }
                DateTime? last = _state.LastLoginAttemptTime;
                double elapsed = _submitIntervalWatch != null ? _submitIntervalWatch.Elapsed.TotalSeconds :
                    (last.HasValue ? Math.Max(0, (DateTime.Now - last.Value).TotalSeconds) : double.MaxValue);
                if (config.LoginMinIntervalSeconds > 0 && elapsed < config.LoginMinIntervalSeconds)
                {
                    _loginWaitUntil = DateTime.Now.AddSeconds(config.LoginMinIntervalSeconds - elapsed);
                    SetStatus("login-wait", "距上次提交尚不足最小间隔，正在监视网络恢复");
                    return true;
                }
                if (config.LoginHourlyLimit > 0 && HourWindowCount(DateTime.Now) >= config.LoginHourlyLimit)
                {
                    SetStatus("login-throttled", "本小时登录次数已达上限，继续监视网络恢复");
                    _log.WarnOnce("login-throttled", "最近 1 小时登录次数已达上限，本次不登录、不注销。");
                    return true;
                }
            }
            return false;
        }

        private int LoginFlow(ProbeOutcome probe, StatusResult status, bool relogin,
            AppConfig config, Credential credential, PortalClient portal, bool automatic = false)
        {
            int wait;
            if (LoginBlocked(config, credential, out wait)) { Persist(probe.LatencyMs, probe.LossPercent); return wait; }
            if (relogin)
            {
                lock (_gate)
                {
                    EnsureCurrentOperation();
                    if (automatic)
                    {
                        _stuckReloginRequested = true;
                        _state.LastForcedRelogin = AppPaths.FormatTime(DateTime.Now);
                    }
                }
                _log.Info("立即重连：先注销当前会话。");
                if (portal.Logout(_operationToken))
                {
                    _log.Info("注销成功，等待 3 秒（Portal 要求至少 3 秒）。");
                    Delay(ReloginWaitSec * 1000);
                }
                else { _log.Warn("注销未成功，继续尝试直接登录。"); }
            }
            else if (config.LoginConfirmDelaySec > 0)
            {
                if (!probe.Online)
                {
                    ProbeOutcome local = NetworkProbe.Probe(config, 2, 300, _operationToken, true);
                    EnsureCurrentOperation();
                    if (local.Verified)
                    {
                        UpdateNetwork(local);
                        _log.Info("登录前本地内容校验已能上网，本次无需登录。");
                        OnOnline(local, "登录前本地校验已能上网，无需登录");
                        Persist(local.LatencyMs, local.LossPercent);
                        return config.OnlineProbeSeconds;
                    }
                }
                Delay(config.LoginConfirmDelaySec * 1000);
                StatusResult confirm = portal.GetStatus(_operationToken);
                EnsureCurrentOperation();
                RecordSessionCheck(confirm, "confirm");
                if (!confirm.Reachable)
                {
                    SetStatus("unreachable", "连不上校园网，等待网络恢复");
                    Persist(probe.LatencyMs, probe.LossPercent);
                    return config.OfflineProbeSeconds;
                }
                if (confirm.Online)
                {
                    ProbeOutcome local = NetworkProbe.Probe(config, 1, 0, _operationToken);
                    EnsureCurrentOperation();
                    UpdateNetwork(local);
                    if (ConnectivityUsable(local)) { OnOnline(local, "复检时联网验证通过，无需登录"); }
                    else { SetStatus("upstream", "复检会话在线，外网仍未验证"); }
                    Persist(local.LatencyMs, local.LossPercent);
                    return ConnectivityUsable(local) ? config.OnlineProbeSeconds : config.OfflineProbeSeconds;
                }
            }

            for (int attempt = 1; attempt <= config.RetryCount; attempt++)
            {
                if (LoginBlocked(config, credential, out wait)) { Persist(probe.LatencyMs, probe.LossPercent); return wait; }
                lock (_gate)
                {
                    EnsureCurrentOperation();
                    SetStatus("login-attempt", "检测到掉线，正在登录…");
                    DateTime submitted = DateTime.Now;
                    CountLoginAttempt(submitted);
                    _state.LastTrigger = AppPaths.FormatTime(submitted);
                    // Count and timestamp are durable before any credentials leave.
                    Persist(probe.LatencyMs, probe.LossPercent, true);
                    _postWatch = Stopwatch.StartNew();
                    _legacySessionOnline = false;
                    _loginWaitUntil = submitted.AddSeconds(config.LoginMinIntervalSeconds);
                }
                _log.Info("第 " + attempt + "/" + config.RetryCount + " 次尝试登录（账号 " + Redact.MaskUser(credential.UserName) + "）。");
                Stopwatch faultWatch = _faultWatch;
                _log.Info("恢复计时：提交登录；距首次异常 " + (faultWatch == null ? "未知" :
                    faultWatch.Elapsed.TotalSeconds.ToString("F3", CultureInfo.InvariantCulture)) + " 秒。");
                PortalLoginResult result = portal.Login(credential.UserName, credential.Password, _operationToken);
                EnsureCurrentOperation();
                _log.Info("登录接口返回耗时 " + (result.ResponseMilliseconds / 1000.0).ToString("F3", CultureInfo.InvariantCulture) +
                    " 秒（POST；恢复计时使用实际经过时间）。");
                if (result.RateLimited)
                {
                    lock (_gate) { EnsureCurrentOperation(); _state.LastError = "Portal 明确限流：" + result.Message; }
                    SetStatus("login-throttled", "Portal 明确限流，稍后按节奏重试");
                    _log.Warn("Portal 明确限流：" + result.Message);
                    break;
                }
                if (result.BusinessPrompt)
                {
                    lock (_gate)
                    {
                        EnsureCurrentOperation();
                        _state.IgnoredPrompts++;
                        _state.LastIgnoredPrompt = Shorten(result.Message);
                        _state.LastError = string.Empty;
                    }
                    _log.WarnOnce("portal-prompt:" + result.Message, "Portal 提示已忽略，继续验证实际联网状态：" + result.Message);
                    SetStatus("login-retry", "Portal 提示已忽略，等待联网验证");
                    Persist(probe.LatencyMs, probe.LossPercent);
                }
                if (result.Success || result.BusinessPrompt)
                {
                    if (result.Success)
                    {
                        SetStatus("login-unconfirmed", "登录已提交，正在验证实际联网状态");
                        _log.Info("登录响应已收到，但联网尚未确认，本次暂不记为登录成功。");
                        Persist(probe.LatencyMs, probe.LossPercent);
                    }
                    ProbeOutcome recovered;
                    string how;
                    if (WaitForRecovery(config, portal, probe.HasVerifiedTargets, out recovered, out how))
                    {
                        EnsureCurrentOperation();
                        UpdateNetwork(recovered);
                        _log.Info("复检确认网络已恢复（" + how + "）。");
                        OnOnline(recovered, how);
                        Persist(recovered.LatencyMs, recovered.LossPercent);
                        return config.OnlineProbeSeconds;
                    }
                    EnsureCurrentOperation();
                    SetStatus(result.BusinessPrompt ? "login-retry" : "login-unconfirmed",
                        "登录已提交，尚未确认联网；继续本地监视");
                    _log.Warn("30 秒恢复观察结束，尚未确认联网；继续按异常频率监视，不追加登录请求。");
                    break;
                }
                lock (_gate) { EnsureCurrentOperation(); _state.LastError = result.Message; _state.ConsecutiveFailures++; }
                SetStatus("login-failed", "登录请求未成功：" + Shorten(result.Message));
                _log.Warn("登录请求未成功：" + result.Message);
            }
            Persist(probe.LatencyMs, probe.LossPercent);
            return WatchIntervalSeconds(config);
        }

        private bool WaitForRecovery(AppConfig config, PortalClient portal, bool hasContent,
            out ProbeOutcome recovered, out string how)
        {
            recovered = null;
            how = string.Empty;
            var watch = Stopwatch.StartNew();
            using (var window = CancellationTokenSource.CreateLinkedTokenSource(_operationToken))
            {
                window.CancelAfter(RecoveryWindowMs);
                CancellationToken token = window.Token;
                Task<ProbeOutcome> content = null;
                Task<StatusResult> session = null;
                ProbeOutcome lastProbe = null;
                bool sessionOnline = false;
                long nextProbe = 0;
                int nextStatus = 0;
                int probeNumber = 0;
                try
                {
                    while (watch.ElapsedMilliseconds < RecoveryWindowMs && !token.IsCancellationRequested)
                    {
                        EnsureCurrentOperation();
                        if (content != null && content.IsCompleted)
                        {
                            lastProbe = content.GetAwaiter().GetResult();
                            content = null;
                        }
                        if (session != null && session.IsCompleted)
                        {
                            StatusResult check = session.GetAwaiter().GetResult();
                            session = null;
                            sessionOnline = check.Reachable && check.Online;
                            RecordSessionCheck(check, "recovery");
                        }
                        if (lastProbe != null && (hasContent ? lastProbe.Verified : lastProbe.Online && sessionOnline))
                        {
                            recovered = lastProbe;
                            lock (_gate) { EnsureCurrentOperation(); _legacySessionOnline = sessionOnline; }
                            how = hasContent
                                ? (probeNumber == 1 ? "本地内容校验通过（首轮立刻命中）" : "本地内容校验通过")
                                : "探测与 Portal 会话在线（未验证内容）";
                            how += "；观察实际耗时 " + watch.Elapsed.TotalSeconds.ToString("F3", CultureInfo.InvariantCulture) + " 秒";
                            return true;
                        }
                        long elapsed = watch.ElapsedMilliseconds;
                        if (content == null && elapsed >= nextProbe)
                        {
                            nextProbe = elapsed + RecoveryProbeIntervalMs;
                            probeNumber++;
                            content = Task.Factory.StartNew(() => NetworkProbe.Probe(config, 1, 0, token, hasContent),
                                CancellationToken.None, TaskCreationOptions.LongRunning, TaskScheduler.Default);
                        }
                        if (nextStatus < RecoveryStatusAtMs.Length && elapsed >= RecoveryStatusAtMs[nextStatus])
                        {
                            do { nextStatus++; }
                            while (nextStatus < RecoveryStatusAtMs.Length && elapsed >= RecoveryStatusAtMs[nextStatus]);
                            // An occupied slot is skipped, never queued for a burst later.
                            if (session == null)
                            {
                                session = Task.Factory.StartNew(() => portal.GetStatus(token),
                                    CancellationToken.None, TaskCreationOptions.LongRunning, TaskScheduler.Default);
                            }
                        }
                        token.WaitHandle.WaitOne(25);
                    }
                }
                catch (OperationCanceledException) { _operationToken.ThrowIfCancellationRequested(); }
                finally
                {
                    window.Cancel();
                    ObserveTask(content);
                    ObserveTask(session);
                }
            }
            _operationToken.ThrowIfCancellationRequested();
            return false;
        }

        private static void ObserveTask(Task task)
        {
            if (task == null) { return; }
            task.ContinueWith(t => { var ignored = t.Exception; },
                CancellationToken.None, TaskContinuationOptions.OnlyOnFaulted | TaskContinuationOptions.ExecuteSynchronously,
                TaskScheduler.Default);
        }

        private void ResetSuspect()
        {
            lock (_gate)
            {
                EnsureCurrentOperation();
                _suspectStreak = 0;
                _stuckReloginRequested = false;
                _upstreamStatusUntilUtc = DateTime.MinValue;
                _loginWaitUntil = DateTime.MinValue;
            }
        }

        private bool ShouldForceRelogin(AppConfig config, bool suspect)
        {
            lock (_gate)
            {
                EnsureCurrentOperation();
                return suspect && !_stuckReloginRequested && config.StuckReloginSeconds > 0 &&
                    _faultWatch != null && _faultWatch.Elapsed.TotalSeconds >= config.StuckReloginSeconds;
            }
        }

        private void OnOnline(ProbeOutcome probe, string message)
        {
            lock (_gate)
            {
                EnsureCurrentOperation();
                if (!ConnectivityUsable(probe)) { throw new InvalidOperationException("不能把未验证的联网状态标记为在线。"); }
                bool hadFault = _faultWatch != null;
                bool afterLogin = _postWatch != null;
                _state.Online = true;
                _state.LastResult = afterLogin ? "login-ok" : "online";
                _state.LastError = string.Empty;
                _state.LastMessage = message;
                _state.ConsecutiveFailures = 0;
                if (afterLogin)
                {
                    _state.LastLoginSuccess = AppPaths.FormatTime(DateTime.Now);
                    _log.Info("自动登录成功，网络已恢复（" + (probe.HasVerifiedTargets ? "联网验证通过" : "未验证内容") +
                        "；提交 → 确认耗时 " + _postWatch.Elapsed.TotalSeconds.ToString("F3", CultureInfo.InvariantCulture) + " 秒）。");
                }
                if (hadFault || afterLogin)
                {
                    _log.Info("网络已恢复：" + message + "（" + probe.Summary + "）。");
                }
                _faultWatch = null;
                _postWatch = null;
                ResetSuspect();
                SetStatus("online", probe.HasVerifiedTargets ? "在线（联网验证通过）" : "探测与会话在线（未验证内容）");
            }
        }

        private void RecordSessionCheck(StatusResult check, string kind)
        {
            string result = !check.Reachable ? "unreachable" : (check.Online ? "online" : "offline");
            lock (_gate)
            {
                EnsureCurrentOperation();
                _legacySessionOnline = check.Reachable && check.Online;
                _state.LastSessionCheck = AppPaths.FormatTime(DateTime.Now);
                _state.LastSessionResult = result;
                _state.LastSessionCheckKind = kind;
                _snapshot.LastSessionCheck = _state.LastSessionCheck;
                _snapshot.LastSessionResult = result;
                _snapshot.LastSessionCheckKind = kind;
            }
            // 会话在线与实际联网验证分别记录，便于分析确认延迟。
            string prefix = kind == "suspect" ? "疑似掉线核对：" :
                kind == "confirm" ? "登录前确认：" : kind == "recovery" ? "恢复观察会话核对：" : "会话核对：";
            if (check.Online) { _log.Info(prefix + "Portal 显示账号在线。"); }
            else if (check.Reachable) { _log.Warn(prefix + "Portal 显示账号不在线。"); }
        }

        private void UpdateNetwork(ProbeOutcome probe)
        {
            NetworkInfo info = NetworkProbe.GetNetworkInfo();
            lock (_gate)
            {
                EnsureCurrentOperation();
                _state.Online = ConnectivityUsable(probe);
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
                EnsureCurrentOperation();
                changed = _snapshot.StatusKey != key;
                if (key != "online" || _state.LastResult != "login-ok") { _state.LastResult = key; }
                if (key != "online" && key != "session-check" && key != "paused" && key != "login-wait" && key != "login-throttled") { _state.Online = false; }
                _state.LastMessage = text;
                _snapshot.StatusKey = key;
                _snapshot.StatusText = text;
                _snapshot.LastResult = _state.LastResult;
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
                EnsureCurrentOperation();
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
                    try { _state.Save(AppPaths.StateFile); } catch { if (force) { throw; } }
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
                _snapshot.LastSessionCheckKind = _state.LastSessionCheckKind;
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
                _snapshot.LastSessionCheckKind = _state.LastSessionCheckKind;
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
