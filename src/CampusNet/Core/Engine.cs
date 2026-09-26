using System;
using System.Collections.Generic;
using System.Globalization;
using System.Net.NetworkInformation;
using System.Text.RegularExpressions;
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
        /// <summary>今日登录计数（本地日期）：确认成功次数 / 真正提交出去的请求次数。</summary>
        public string DayKey = string.Empty;
        public int DayLoginSuccess;
        public int DayLoginAttempts;
        /// <summary>「提交登录 → 确认恢复」耗时：最近一次（秒，-1 = 本次运行还没有样本）与本次运行的中位。</summary>
        public int LastRecoverySeconds = -1;
        public int RecoveryMedianSeconds = -1;
        public int RecoverySampleCount;
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
                    // 其余（含 verifying / tcp-only / session-check / login-unconfirmed / login-throttled）统一为黄色
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
        /// <summary>系统网络变化事件的防抖窗口：网卡插拔时事件会连成一串，只按最后一次处理。</summary>
        private const int NetworkEventDebounceMs = 1000;
        /// <summary>
        /// 连续多少轮拿不到内容校验才认定「疑似掉线」并发起 Portal 核对。
        /// 2.1.3-pre.1 收紧为 1 轮：单次抖动仍由「立刻补测一次」挡掉，但真掉线不再白等一整轮。
        /// </summary>
        private const int SuspectStreakForVerify = 1;
        /// <summary>
        /// 疑似掉线期间向 Portal 求证的最小间隔：只影响「只读 chkstatus」的发起频率，
        /// 与登录（提交）无关。10 秒是 2.1.3-pre.1 的新值（原 20 秒）。
        /// </summary>
        private const int SuspectVerifyMinSeconds = 10;
        /// <summary>
        /// 登录被回「已在别处在线」（userid error2）后的短窗：每 1 秒一次本机内容校验，共 3 秒。
        /// 会话真的已经建立时，3 秒内就能确认；确认不了就说明是残留会话，走「注销 + 重新登录」。
        /// </summary>
        internal const int RecoveryShortWatchSeconds = 3;
        /// <summary>
        /// 提交登录后的密集复检窗口：1 秒一档共 30 档。
        /// 真机实测「提交 → 确认」中位 22 秒、57% 落在 20 秒以后；密集档位让真实信号一出现
        /// 最多 1~2 秒就被确认（原 6 档粗阶梯最大粒度 6 秒）。
        /// </summary>
        internal const int RecoveryWatchSeconds = 30;
        /// <summary>密集窗口里每隔几档加一次只读 chkstatus（其余档只做本机内容校验，不发 Portal 请求）。</summary>
        private const int RecoveryStatusEveryRungs = 3;
        /// <summary>Portal 回 waitsec 但解析不出秒数时的兜底暂停（秒）。</summary>
        private const int DefaultThrottleSeconds = 60;
        /// <summary>「提交登录 → 确认恢复」的耗时样本上限（只保留最近 N 次）。</summary>
        private const int RecoverySampleLimit = 20;

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
        /// <summary>本轮「疑似掉线」从什么时候开始的，用于判断是否属于「残留会话挡路」。</summary>
        private DateTime? _suspectSince;
        /// <summary>上一次因为「疑似掉线」主动向 Portal 求证的时间。</summary>
        private DateTime? _lastSuspectVerifyUtc;
        /// <summary>本轮疑似掉线是否已经自动注销重登过一次（避免热循环）。</summary>
        private bool _stuckReloginRequested;

        /// <summary>
        /// Portal 明确限流（waitsec）要求的暂停结束时间：暂停期内不再提交登录，
        /// 这是删掉「最小间隔 / 每小时上限」之后唯一的外部节流来源。
        /// </summary>
        private DateTime _loginThrottleUntil = DateTime.MinValue;

        /// <summary>
        /// 「提交登录 → 确认恢复」的耗时样本（秒），只保留本次运行最近 RecoverySampleLimit 次。
        /// 纯内存数据：不写 state.json、不新增文件（与只读约束一致），退出即清空。
        /// </summary>
        private readonly List<int> _recoverySamples = new List<int>();

        private DateTime _lastPersistUtc = DateTime.MinValue;
        private string _persistedStatusKey;
        private bool _persistedOnline;
        private bool _persistedPaused;
        private int _persistedFailureCount;
        private string _persistedSessionCheck;
        private int _persistedIgnoredPrompts;
        private string _persistedForcedRelogin;
        private int _persistedDayAttempts;
        private int _persistedDaySuccess;

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
                // 单调合并：先记住内存里这几个「只能前进」的计数，再换磁盘快照 ——
                // 界面上保存一次设置就会触发一次 Reload，而磁盘上的 state.json 往往比内存旧
                // （写入有 60 秒节流），直接覆盖会让「今日登录」「累计检查」凭空回退
                // （历史上出现过「已忽略提示 33 → 18」）。
                long runCount = _state.RunCount;
                int ignoredPrompts = _state.IgnoredPrompts;
                string dayKey = _state.DayKey;
                int daySuccess = _state.DayLoginSuccess;
                int dayAttempts = _state.DayLoginAttempts;
                _state.CopyFrom(loaded);
                if (runCount > _state.RunCount) { _state.RunCount = runCount; }
                if (ignoredPrompts > _state.IgnoredPrompts) { _state.IgnoredPrompts = ignoredPrompts; }
                // 今日计数：同一天取较大值；日期不同时保留更新的那一天（避免被旧快照带回昨天）。
                if (string.Equals(dayKey, _state.DayKey, StringComparison.Ordinal))
                {
                    if (daySuccess > _state.DayLoginSuccess) { _state.DayLoginSuccess = daySuccess; }
                    if (dayAttempts > _state.DayLoginAttempts) { _state.DayLoginAttempts = dayAttempts; }
                }
                else if (string.CompareOrdinal(dayKey, _state.DayKey) > 0)
                {
                    _state.DayKey = dayKey;
                    _state.DayLoginSuccess = daySuccess;
                    _state.DayLoginAttempts = dayAttempts;
                }
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
        /// 把一次「真正提交出去的登录请求」计入今日提交次数（含注销后的第二次提交、手动「立即重连」）。
        /// 关键：按请求计数，而不是按「一次登录流程」计数。
        /// </summary>
        private void CountLoginSubmit(DateTime now)
        {
            lock (_gate)
            {
                _state.RollDay(now);
                _state.DayLoginAttempts++;
                _state.LastLoginAttempt = AppPaths.FormatTime(now);
            }
        }

        /// <summary>Portal 确认在线、或本机内容校验确认恢复时，把这一次登录计入今日成功次数。</summary>
        private void CountLoginSuccess(DateTime now)
        {
            lock (_gate)
            {
                _state.RollDay(now);
                _state.DayLoginSuccess++;
            }
        }

        /// <summary>记录一次「提交登录 → 确认恢复」的耗时（秒）。只更新内存快照，不落盘。</summary>
        private int RecordRecovery(DateTime submittedAt)
        {
            int seconds = (int)Math.Round((DateTime.Now - submittedAt).TotalSeconds);
            if (seconds < 0) { seconds = 0; }
            lock (_gate)
            {
                _recoverySamples.Add(seconds);
                while (_recoverySamples.Count > RecoverySampleLimit) { _recoverySamples.RemoveAt(0); }
                _snapshot.LastRecoverySeconds = seconds;
                _snapshot.RecoverySampleCount = _recoverySamples.Count;
                _snapshot.RecoveryMedianSeconds = Median(_recoverySamples);
            }
            return seconds;
        }

        private static int Median(List<int> values)
        {
            if (values == null || values.Count == 0) { return -1; }
            var sorted = new List<int>(values);
            sorted.Sort();
            int middle = sorted.Count / 2;
            if (sorted.Count % 2 == 1) { return sorted[middle]; }
            return (int)Math.Round((sorted[middle - 1] + sorted[middle]) / 2.0);
        }

        /// <summary>解析 Portal 限流响应里的 waitsec=N；解析不到就用兜底 60 秒。</summary>
        private static int ParseWaitSeconds(string message)
        {
            Match match = Regex.Match(message ?? string.Empty, "waitsec\\D*(\\d+)", RegexOptions.IgnoreCase);
            if (match.Success)
            {
                int seconds;
                if (int.TryParse(match.Groups[1].Value, NumberStyles.Integer, CultureInfo.InvariantCulture, out seconds)
                    && seconds > 0)
                {
                    return seconds;
                }
            }
            return DefaultThrottleSeconds;
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
            _stop = true;
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
                copy.DayKey = from.DayKey;
                copy.DayLoginSuccess = from.DayLoginSuccess;
                copy.DayLoginAttempts = from.DayLoginAttempts;
                copy.LastRecoverySeconds = from.LastRecoverySeconds;
                copy.RecoveryMedianSeconds = from.RecoveryMedianSeconds;
                copy.RecoverySampleCount = from.RecoverySampleCount;
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

        /// <summary>
        /// 一轮评估的包装：登记本轮编号与「正在跑」标志，让外部调用方（例如 --relogin）
        /// 能等到自己触发的那一轮真正跑完，而不是按固定秒数猜。
        /// </summary>
        private int Evaluate()
        {
            lock (_gate)
            {
                _snapshot.EvaluationId = ++_evaluationId;
                _snapshot.Busy = true;
            }
            try { return EvaluateCore(); }
            finally { lock (_gate) { _snapshot.Busy = false; } }
        }

        private int EvaluateCore()
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
                    // 连续 1 轮拿不到内容校验就算「疑似掉线」（单次抖动已经由上面的补测挡掉）。
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
                    RecordSessionCheck(check, suspect ? "suspect" : "periodic");

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

            // Portal 明确限流（waitsec）要求的暂停期：删掉「最小间隔 / 每小时上限」之后，
            // 这是唯一还会拦住登录的外部节流 —— Portal 自己说要等，就听它的。
            if (!relogin && now < _loginThrottleUntil)
            {
                int remain = (int)Math.Ceiling((_loginThrottleUntil - now).TotalSeconds);
                if (remain < 1) { remain = 1; }
                SetStatus("login-throttled", "Portal 要求暂停登录，约 " + remain + " 秒后再试");
                _log.WarnOnce("login-throttle-wait", "Portal 之前要求暂停登录（waitsec），暂停期内不再提交登录请求。");
                Persist(probe.LatencyMs, probe.LossPercent);
                return Math.Max(3, Math.Min(remain, 15));
            }

            // 登录前二次确认（唯一保留下来的闸门）
            if (config.LoginConfirmDelaySec > 0 && !relogin)
            {
                // 先做一次纯本地内容校验（0 个 Portal 请求）：本地已经能取回内容，说明根本不用登录。
                // 只在「本地探测判定不通」时用这条翻案——Portal 会话核对说离线时不能这么做，
                // 「本机内容能取回」不代表账号没被踢，那正是需要登录的场景。
                if (!probe.Online)
                {
                    int localLatency;
                    if (NetworkProbe.ContentCheck(config, out localLatency))
                    {
                        // 内容校验已经通过，再跑一轮完整探测，好让界面/日志拿到真实的延迟、丢包与逐目标明细。
                        ProbeOutcome recovered = NetworkProbe.Probe(config, config.ConfirmAttempts, config.ConfirmGapMs);
                        if (recovered.Online)
                        {
                            UpdateNetwork(recovered);
                            _log.Info("登录前本地内容校验已能上网（"
                                + (localLatency < 0 ? "延迟未知" : localLatency + " ms")
                                + "），网络已恢复，本轮不发任何 Portal 请求。");
                            OnOnline(recovered, "登录前本地校验已能上网，无需登录");
                            Persist(recovered.LatencyMs, recovered.LossPercent);
                            return config.OnlineProbeSeconds;
                        }
                    }
                }
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
            bool submitted = false;
            bool hardFailure = false;
            bool reloginDone = false;
            string lastMessage = string.Empty;
            string limitReason = string.Empty;
            string ignoredPrompt = string.Empty;
            int throttleSeconds = -1;
            DateTime? firstSubmit = null;
            int attempt = 1;
            while (attempt <= config.RetryCount)
            {
                // 心跳：登录流程可能长时间占住评估线程（重试多、超时长），
                // 这里每次提交前强制刷一次 state.json，免得守护进程把「正在登录」误判成「卡死」而杀掉重启。
                lock (_gate) { _state.LastTrigger = AppPaths.FormatTime(DateTime.Now); }
                Persist(probe.LatencyMs, probe.LossPercent, true);

                DateTime submittedAt = DateTime.Now;
                if (!firstSubmit.HasValue) { firstSubmit = submittedAt; }
                submitted = true;
                CountLoginSubmit(submittedAt);

                _log.Info("第 " + attempt + "/" + config.RetryCount + " 次尝试登录（账号 "
                    + Redact.MaskUser(credential.UserName) + "）。");
                PortalLoginResult result = portal.Login(credential.UserName, credential.Password);
                lastMessage = result.Message;
                string how = string.Empty;

                if (result.Success)
                {
                    // 登录接口说成功：直接进入密集复检窗口（1 秒一档，以本机内容校验为准）。
                    _log.Info("登录接口返回成功，开始密集复检本地网络（最多 " + RecoveryWatchSeconds + " 秒）。");
                    if (WaitForRecovery(config, portal, out how, out bool unreachable))
                    {
                        success = true;
                        _log.Info("复检确认网络已恢复（" + how + "）。");
                        break;
                    }
                    if (unreachable)
                    {
                        _log.Warn("登录接口返回成功，但 Portal 状态接口不可达：无法确认是否真的联网，本次按「待确认」收尾。");
                        break;
                    }
                    attempt++;
                    continue;
                }

                if (result.RateLimited)
                {
                    throttleSeconds = ParseWaitSeconds(result.Message);
                    limitReason = "Portal 明确限流（请求过于频繁）";
                    _log.Warn("Portal 明确限流：" + result.Message + "，按 Portal 要求暂停 " + throttleSeconds + " 秒。");
                    break;
                }

                if (result.BusinessPrompt)
                {
                    ignoredPrompt = result.Message;
                    // 「账号已在别处在线」「密码错误」这类 Portal 业务提示按用户要求完全忽略：
                    // 不当成终止性失败、不计入连续失败、不写「最近错误」。
                    bool ghost = result.AlreadyOnline && !relogin && !reloginDone && config.StuckReloginSeconds > 0;
                    if (ghost)
                    {
                        // 先给一个 3 秒短窗：会话真的已经建立时这里就命中，不用折腾注销。
                        if (WaitShortRecovery(config, out how))
                        {
                            success = true;
                            _log.Info("Portal 提示已忽略，复检确认网络已恢复（" + how + "）。");
                            break;
                        }
                        // 真机证据（9067 行日志）：Portal 对每次登录都回 error2（已在别处在线），
                        // 本机却上不了网 —— 那 ~20 秒全花在等一次永远不会生效的登录上；
                        // 而「先注销再登录」的 6 次样本全部在提交后 5 秒内恢复。
                        _log.Warn("检测到残留会话（Portal 回「已在别处在线」且 " + RecoveryShortWatchSeconds
                            + " 秒内本机仍上不了网）：先注销，再重新登录。");
                        lock (_gate) { _state.LastForcedRelogin = AppPaths.FormatTime(DateTime.Now); }
                        SetStatus("stuck-relogin", "检测到残留会话，正在注销后重新登录…");
                        bool loggedOut = portal.Logout();
                        if (loggedOut)
                        {
                            _log.Info("注销成功，等待 " + ReloginWaitSec + " 秒（Portal 要求至少 3 秒）。");
                            Thread.Sleep(ReloginWaitSec * 1000);
                        }
                        else
                        {
                            _log.Warn("注销未成功，仍然尝试重新登录。");
                        }
                        reloginDone = true;
                        // 第二次（也是本次恢复动作里最后一次）提交
                        lock (_gate) { _state.LastTrigger = AppPaths.FormatTime(DateTime.Now); }
                        Persist(probe.LatencyMs, probe.LossPercent, true);
                        DateTime resubmitAt = DateTime.Now;
                        submitted = true;
                        CountLoginSubmit(resubmitAt);
                        _log.Info("重新登录（账号 " + Redact.MaskUser(credential.UserName) + "）。");
                        PortalLoginResult second = portal.Login(credential.UserName, credential.Password);
                        lastMessage = second.Message;
                        if (second.RateLimited)
                        {
                            throttleSeconds = ParseWaitSeconds(second.Message);
                            limitReason = "Portal 明确限流（请求过于频繁）";
                            _log.Warn("重新登录被限流：" + second.Message + "，按 Portal 要求暂停 " + throttleSeconds + " 秒。");
                            break;
                        }
                        if (!second.Success && !second.BusinessPrompt)
                        {
                            hardFailure = true;
                            _log.Warn("重新登录未成功：" + lastMessage);
                        }
                        if (WaitForRecovery(config, portal, out how, out bool afterReloginUnreachable))
                        {
                            success = true;
                            _log.Info("复检确认网络已恢复（" + how + "）。");
                            break;
                        }
                        if (afterReloginUnreachable)
                        {
                            _log.Warn("重新登录后 Portal 状态接口不可达，本次按「待确认」收尾。");
                        }
                        // 「已在别处在线」反复出现时不再第三次提交，本轮到此为止。
                        _log.Warn("重新登录后本机仍未恢复上网（" + Shorten(lastMessage) + "），本轮不再继续提交。");
                        break;
                    }

                    _log.WarnOnce("portal-prompt:" + lastMessage, "Portal 提示（已忽略）：" + lastMessage);
                    if (result.AlreadyOnline || lastMessage.IndexOf("密码", StringComparison.Ordinal) >= 0)
                    {
                        _log.WarnOnce("en-md5-hint",
                            "如果学校 Portal 要求 en_md5=1（密码按 MD5 提交），本工具只按明文提交，"
                            + "会一直收到这类提示；这种情况请改用学校官方客户端。");
                    }
                    if (WaitShortRecovery(config, out how))
                    {
                        success = true;
                        _log.Info("Portal 提示已忽略，复检确认网络已恢复（" + how + "）。");
                        break;
                    }
                    // 这类提示重试没有任何好处（「已在别处在线」再打一次就是把刚建立的会话顶掉）。
                    break;
                }

                // 连不上登录接口、或收到完全无法识别的响应：这才是真正的失败，照实记录。
                hardFailure = true;
                _log.Warn("登录请求未成功：" + lastMessage);
                if (WaitForRecovery(config, portal, out how, out bool failedUnreachable))
                {
                    success = true;
                    _log.Info("复检确认网络已恢复（" + how + "）。");
                    break;
                }
                if (failedUnreachable) { break; }
                attempt++;
            }

            if (success)
            {
                DateTime submittedAt = firstSubmit.HasValue ? firstSubmit.Value : DateTime.Now;
                lock (_gate)
                {
                    _state.Online = true;
                    _state.LastResult = "login-ok";
                    _state.LastError = string.Empty;
                    _state.LastMessage = "自动登录成功";
                    _state.ConsecutiveFailures = 0;
                    _state.LastLoginSuccess = AppPaths.FormatTime(DateTime.Now);
                }
                CountLoginSuccess(DateTime.Now);
                int recoverySeconds = RecordRecovery(submittedAt);
                ResetSuspect();
                _log.Info("自动登录成功，网络已恢复（提交 → 确认耗时 " + recoverySeconds + " 秒）。");
                SetStatus("online", "在线（刚刚自动登录）");
                Persist(-1, 0);
                return config.OnlineProbeSeconds;
            }

            if (!string.IsNullOrEmpty(limitReason))
            {
                lock (_gate) { _state.ConsecutiveFailures++; }
                lock (_gate)
                {
                    _state.Online = false;
                    _state.LastError = limitReason + "：" + lastMessage;
                    _state.LastMessage = limitReason;
                    _state.LastResult = "login-throttled";
                }
                if (throttleSeconds > 0)
                {
                    _loginThrottleUntil = DateTime.Now.AddSeconds(throttleSeconds);
                    _log.Warn(limitReason + "；按 Portal 要求暂停 " + throttleSeconds + " 秒后再尝试。");
                }
                else
                {
                    _log.Warn(limitReason + "；本次不再提交登录。");
                }
                SetStatus("login-throttled", "Portal 限流，暂停 " + Math.Max(1, throttleSeconds) + " 秒后重试");
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
                _log.Warn("Portal 提示已忽略（" + Shorten(ignoredPrompt) + "），本机仍未恢复上网，交给下一个探测周期。");
                SetStatus("login-retry", "登录提示已忽略，继续重试（" + Shorten(ignoredPrompt) + "）");
            }
            else if (hardFailure)
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
            else if (submitted)
            {
                // 登录确实提交出去了，但本机内容校验始终没恢复：只读复检窗口不能证明真的联网。
                // 绝不能记成 login-ok —— 老代码的 after.Online || !after.Reachable 就是这么误报的。
                lock (_gate)
                {
                    _state.Online = false;
                    _state.LastResult = "login-unconfirmed";
                    _state.LastMessage = "登录已提交，但本机内容校验仍未通过，无法确认真正联网";
                    _state.LastError = "登录已提交，但本机内容校验未通过（Portal 说在线不等于能上网）";
                }
                SetStatus("login-unconfirmed", "登录已提交，等待确认（本机还上不了网）");
                _log.Warn("本次不记为登录成功（登录已提交但本机内容校验未通过），按 "
                    + Math.Max(5, config.OfflineProbeSeconds) + " 秒的节奏继续复检。");
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
        /// 登录返回「已在别处在线 / 密码错误」这类业务提示后的短窗：每 1 秒一次本机内容校验，共 3 秒。
        /// 只做本机请求（不发 Portal），会话真的已经建立时这里就命中。
        /// </summary>
        private bool WaitShortRecovery(AppConfig config, out string how)
        {
            how = string.Empty;
            for (int rung = 1; rung <= RecoveryShortWatchSeconds; rung++)
            {
                Thread.Sleep(1000);
                int latency;
                if (NetworkProbe.QuickContentCheck(config, out latency))
                {
                    how = "本地内容校验通过（+" + rung + " 秒）";
                    return true;
                }
            }
            return false;
        }

        /// <summary>
        /// 提交登录后的密集复检窗口：1 秒一档共 30 档。
        /// 每档做一次本机内容校验（QuickContentCheck，短预算），每 RecoveryStatusEveryRungs 档加一次
        /// 只读 chkstatus；「本机内容通过」和「Portal 说在线」都只是**候选**，必须再用一次完整探测复核
        /// （有内容校验目标时要求内容校验通过；配置里全是 TCP 目标时退化为要求连通）。
        /// 这样「Portal 说在线、其实上不了网」不会再被算成恢复成功。
        /// Portal 状态接口整个不可达时提前收工（每档只会白白耗满一次超时）。
        /// </summary>
        private bool WaitForRecovery(AppConfig config, PortalClient portal, out string how, out bool portalUnreachable)
        {
            how = string.Empty;
            portalUnreachable = false;
            for (int rung = 1; rung <= RecoveryWatchSeconds; rung++)
            {
                Thread.Sleep(1000);
                string candidate = string.Empty;
                if (rung % RecoveryStatusEveryRungs == 0)
                {
                    StatusResult status = portal.GetStatus();
                    if (!status.Reachable)
                    {
                        portalUnreachable = true;
                        _log.WarnOnce("recovery-unreachable", "复检时 Portal 状态接口不可达，本次提前结束复检（按「待确认」处理）。");
                        break;
                    }
                    if (status.Online) { candidate = "Portal 显示账号已在线（+" + rung + " 秒）"; }
                }
                int latency;
                if (NetworkProbe.QuickContentCheck(config, out latency))
                {
                    candidate = "本地内容校验通过（+" + rung + " 秒）";
                }
                if (candidate.Length == 0) { continue; }
                int confirmLatency;
                if (ConfirmRecovered(config, out confirmLatency))
                {
                    how = candidate;
                    if (confirmLatency >= 0) { how = how + "，完整探测 " + confirmLatency + " ms"; }
                    return true;
                }
                _log.Info("复检候选未通过：" + candidate + "，但完整探测仍取不回内容，继续复检。");
            }
            return false;
        }

        /// <summary>
        /// 用一次完整探测复核「真的能上网」：有内容校验目标时要求内容校验通过（Verified），
        /// 配置里全是 TCP 目标时退化为要求连通（那时没有更可靠的判据）。
        /// </summary>
        private static bool ConfirmRecovered(AppConfig config, out int latencyMs)
        {
            ProbeOutcome confirm = NetworkProbe.Probe(config, config.ConfirmAttempts, config.ConfirmGapMs);
            latencyMs = confirm.LatencyMs;
            if (confirm.ConfigError || !confirm.Online) { return false; }
            return confirm.HasVerifiedTargets ? confirm.Verified : true;
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

        /// <summary>
        /// 记录一次「在线会话核对」的结果（只读 chkstatus，绝不触发登录）。
        /// kind = periodic（定时巡检）/ suspect（本机探测不对劲时的疑似掉线核对）。
        /// </summary>
        private void RecordSessionCheck(StatusResult check, string kind)
        {
            string result = !check.Reachable ? "unreachable" : (check.Online ? "online" : "offline");
            lock (_gate)
            {
                _state.LastSessionCheck = AppPaths.FormatTime(DateTime.Now);
                _state.LastSessionResult = result;
                _state.LastSessionCheckKind = kind;
                _snapshot.LastSessionCheck = _state.LastSessionCheck;
                _snapshot.LastSessionResult = result;
                _snapshot.LastSessionCheckKind = kind;
            }
            // 日志里区分两种来源：「定时巡检」说明一切正常，「疑似掉线核对」说明本机探测已经不对劲了。
            string prefix = kind == "suspect" ? "疑似掉线核对：" : "会话核对：";
            if (check.Online) { _log.Info(prefix + "Portal 显示账号在线。"); }
            else if (check.Reachable) { _log.Warn(prefix + "Portal 显示账号不在线。"); }
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
                    || _persistedDayAttempts != _state.DayLoginAttempts
                    || _persistedDaySuccess != _state.DayLoginSuccess
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
                    _persistedDayAttempts = _state.DayLoginAttempts;
                    _persistedDaySuccess = _state.DayLoginSuccess;
                    _persistedIgnoredPrompts = _state.IgnoredPrompts;
                    _persistedForcedRelogin = _state.LastForcedRelogin;
                    _persistedSessionCheck = _state.LastSessionCheck;
                }
                _snapshot.LastResult = _state.LastResult;
                _snapshot.Online = _state.Online;
                _snapshot.LastMessage = _state.LastMessage;
                _snapshot.LastError = _state.LastError;
                _snapshot.ConsecutiveFailures = _state.ConsecutiveFailures;
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
                _snapshot.DayKey = _state.DayKey;
                _snapshot.DayLoginSuccess = _state.TodaySuccess(DateTime.Now);
                _snapshot.DayLoginAttempts = _state.TodayAttempts(DateTime.Now);
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
                _snapshot.RunCount = _state.RunCount;
                _snapshot.DayKey = _state.DayKey;
                _snapshot.DayLoginSuccess = _state.TodaySuccess(DateTime.Now);
                _snapshot.DayLoginAttempts = _state.TodayAttempts(DateTime.Now);
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
