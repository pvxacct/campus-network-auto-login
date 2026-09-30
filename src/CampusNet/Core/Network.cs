using System;
using System.Collections.Generic;
using System.Globalization;
using System.Diagnostics;
using System.Threading;
using System.Threading.Tasks;
using System.IO;
using System.Net;
using System.Net.NetworkInformation;
using System.Net.Sockets;
using System.Text;
using System.Text.RegularExpressions;

namespace CampusNet.Core
{
    /// <summary>一个探测目标：tcp:host:port、icmp:host 或 http:主机/路径[|期望文本]。</summary>
    public sealed class ProbeTarget
    {
        public string Kind = "tcp";
        public string Host = string.Empty;
        public int Port;
        /// <summary>http / https 目标的完整地址。</summary>
        public string Url = string.Empty;
        /// <summary>内容校验关键字：响应体必须包含它才算通过（可为空 = 只要 2xx）。</summary>
        public string Expect = string.Empty;
        /// <summary>期望的 HTTP 状态码（0 = 任意 2xx）；用于 generate_204 这类只认状态码的目标。</summary>
        public int ExpectStatus;

        /// <summary>是否是「内容校验」目标（能识破网关只代答 TCP 握手的情况）。</summary>
        public bool ContentVerified { get { return Kind == "http"; } }

        public string Display
        {
            get
            {
                if (Kind == "icmp") { return Host; }
                if (Kind == "http") { return Host; }
                return Host + ":" + Port.ToString(CultureInfo.InvariantCulture);
            }
        }

        public static ProbeTarget Parse(string text)
        {
            if (string.IsNullOrWhiteSpace(text)) { return null; }
            string value = text.Trim();
            var target = new ProbeTarget();
            if (value.StartsWith("http:", StringComparison.OrdinalIgnoreCase) ||
                value.StartsWith("https:", StringComparison.OrdinalIgnoreCase))
            {
                int colon = value.IndexOf(':');
                string scheme = value.Substring(0, colon).ToLowerInvariant();
                string rest = value.Substring(colon + 1).Trim();
                // 竖线后的写法：|期望文本、|204（只认状态码）、|期望文本|204（两者都要满足）。
                // 以前只取第一段，写成 url|文本|204 时会把「文本|204」整串当成关键字，
                // 于是「只认 204」的配置实际上根本没生效——现在逐段解析。
                string[] parts = rest.Split('|');
                rest = parts[0].Trim();
                if (parts.Length > 1) { ApplyExpectation(target, parts[1]); }
                if (parts.Length > 2) { ApplyExpectation(target, parts[2]); }
                if (rest.StartsWith("//", StringComparison.Ordinal)) { rest = rest.Substring(2); }
                if (rest.Length == 0) { return null; }
                target.Kind = "http";
                target.Url = scheme + "://" + rest;
                int slash = rest.IndexOf('/');
                target.Host = slash > 0 ? rest.Substring(0, slash) : rest;
                return target;
            }
            if (value.StartsWith("icmp:", StringComparison.OrdinalIgnoreCase))
            {
                target.Kind = "icmp";
                target.Host = value.Substring(5).Trim();
                return string.IsNullOrEmpty(target.Host) ? null : target;
            }
            if (value.StartsWith("tcp:", StringComparison.OrdinalIgnoreCase)) { value = value.Substring(4).Trim(); }
            int separator = value.LastIndexOf(':');
            if (separator <= 0 || separator == value.Length - 1) { return null; }
            target.Kind = "tcp";
            target.Host = value.Substring(0, separator).Trim();
            int port;
            if (!int.TryParse(value.Substring(separator + 1), NumberStyles.Integer, CultureInfo.InvariantCulture, out port)) { return null; }
            target.Port = port;
            return string.IsNullOrEmpty(target.Host) ? null : target;
        }

        /// <summary>竖线后的一段：正好三位数字按「期望状态码」理解，其余按「期望内容」理解。</summary>
        private static void ApplyExpectation(ProbeTarget target, string token)
        {
            string value = (token ?? string.Empty).Trim();
            if (value.Length == 0) { return; }
            int statusCode;
            if (value.Length == 3 && int.TryParse(value, NumberStyles.Integer, CultureInfo.InvariantCulture, out statusCode))
            {
                target.ExpectStatus = statusCode;
                return;
            }
            target.Expect = value;
        }
    }

    public sealed class ProbeOutcome
    {
        public bool Online;
        /// <summary>配置里一条合法探测目标都没有：既不能算在线（会让自动登录永远不触发），也不能算离线（会拿着坏配置去登录）。</summary>
        public bool ConfigError;
        /// <summary>至少一个「内容校验」目标真的取回了预期内容（不只是握手成功）。</summary>
        public bool Verified;
        /// <summary>配置里是否存在内容校验目标（没有的话只能靠周期性会话校验兜底）。</summary>
        public bool HasVerifiedTargets;
        public int Successes;
        public int Attempts;
        public int Incomplete;
        public long ElapsedMilliseconds;
        public int LatencyMs = -1;
        public int LossPercent = 100;
        public readonly List<string> Failures = new List<string>();
        /// <summary>逐目标明细，供界面展示（例如「www.msftconnecttest.com 31 ms」）。</summary>
        public readonly List<string> Details = new List<string>();

        public string Summary
        {
            get
            {
                if (ConfigError) { return "探测目标配置无效（没有任何一条合法目标）"; }
                if (Attempts == 0) { return Incomplete > 0 ? "探测未完成" : "没有可用的探测目标"; }
                if (Online)
                {
                    string head = Verified ? "内容校验通过" : (HasVerifiedTargets ? "只有 TCP 握手、内容校验未通过" : "连通");
                    string body = Details.Count > 0
                        ? string.Join(" · ", Details.ToArray())
                        : Successes + "/" + Attempts;
                    return head + "（" + body + "）";
                }
                return "不通（" + Successes + "/" + Attempts + "）" + (Failures.Count > 0 ? "：" + Failures[0] : string.Empty);
            }
        }
    }

    public sealed class NetworkInfo
    {
        public string AdapterName = string.Empty;
        public string AdapterType = string.Empty;
        public string IPv4 = string.Empty;
        public string Gateway = string.Empty;
        public string Dns = string.Empty;
        public bool HasAdapter;
    }

    /// <summary>本地发起的 HTTP 内容 / TCP / ICMP 探测，不发任何 Portal 请求。</summary>
    public static class NetworkProbe
    {

        // A timed-out DNS lookup may outlive Abort on .NET Framework. Reserve a slot
        // before queuing work, so repeated rounds can never create unlimited workers.
        private static readonly SemaphoreSlim TargetSlots = new SemaphoreSlim(8, 8);

        private sealed class TargetResult
        {
            public bool Completed;
            public bool Success;
            public int Latency = -1;
        }

        public static ProbeOutcome Probe(AppConfig config, int rounds, int gapMs)
        {
            return Probe(config, rounds, gapMs, CancellationToken.None);
        }

        public static ProbeOutcome Probe(AppConfig config, int rounds, int gapMs,
            CancellationToken cancellation, bool contentOnly = false)
        {
            var watch = Stopwatch.StartNew();
            var outcome = new ProbeOutcome();
            var targets = new List<ProbeTarget>();
            foreach (string text in config.ProbeTargets)
            {
                ProbeTarget target = ProbeTarget.Parse(text);
                if (target == null) { continue; }
                if (target.ContentVerified) { outcome.HasVerifiedTargets = true; }
                if (!contentOnly || target.ContentVerified) { targets.Add(target); }
            }
            if (targets.Count == 0)
            {
                outcome.ConfigError = !contentOnly;
                return outcome;
            }

            var details = new Dictionary<string, string>();
            for (int round = 0; round < Math.Max(1, rounds); round++)
            {
                cancellation.ThrowIfCancellationRequested();
                if (round > 0 && gapMs > 0 && cancellation.WaitHandle.WaitOne(gapMs))
                {
                    cancellation.ThrowIfCancellationRequested();
                }
                TargetResult[] results = RunParallel(config, targets, cancellation);
                for (int i = 0; i < targets.Count; i++)
                {
                    ProbeTarget target = targets[i];
                    TargetResult result = results[i];
                    string detail;
                    if (!result.Completed)
                    {
                        outcome.Incomplete++;
                        detail = target.Display + " 未完成";
                    }
                    else
                    {
                        outcome.Attempts++;
                        if (result.Success)
                        {
                            outcome.Successes++;
                            if (target.ContentVerified) { outcome.Verified = true; }
                            if (outcome.LatencyMs < 0) { outcome.LatencyMs = result.Latency; }
                            detail = target.Display + " " + result.Latency + " ms";
                        }
                        else
                        {
                            if (!outcome.Failures.Contains(target.Display)) { outcome.Failures.Add(target.Display); }
                            detail = target.Display + " 失败";
                        }
                    }
                    string previous;
                    if (!details.TryGetValue(target.Display, out previous) || result.Success ||
                        previous.EndsWith("未完成", StringComparison.Ordinal))
                    {
                        details[target.Display] = detail;
                    }
                }
                if (outcome.Verified || (!outcome.HasVerifiedTargets && outcome.Successes > 0)) { break; }
            }
            outcome.Online = outcome.Successes > 0;
            outcome.LossPercent = outcome.Attempts == 0 ? -1 :
                (int)Math.Round(100.0 * (outcome.Attempts - outcome.Successes) / outcome.Attempts);
            foreach (ProbeTarget target in targets) { outcome.Details.Add(details[target.Display]); }
            outcome.ElapsedMilliseconds = watch.ElapsedMilliseconds;
            cancellation.ThrowIfCancellationRequested();
            return outcome;
        }

        private static TargetResult[] RunParallel(AppConfig config, List<ProbeTarget> targets,
            CancellationToken cancellation)
        {
            int budget = 500;
            bool hasContent = false;
            foreach (ProbeTarget target in targets)
            {
                budget = Math.Max(budget, target.ContentVerified ? config.HttpProbeTimeoutMs : config.ProbeTimeoutMs);
                hasContent |= target.ContentVerified;
            }
            var results = new TargetResult[targets.Count];
            var tasks = new List<Task<TargetResult>>();
            var indices = new List<int>();
            using (var round = CancellationTokenSource.CreateLinkedTokenSource(cancellation))
            {
                round.CancelAfter(budget);
                CancellationToken token = round.Token;
                for (int i = 0; i < targets.Count; i++) { results[i] = new TargetResult(); }
                int nextTarget = 0;
                try
                {
                    while (!token.IsCancellationRequested)
                    {
                        // Schedule the remaining targets as slots are released. More than
                        // eight configured targets must not starve the later entries.
                        while (nextTarget < targets.Count && !token.IsCancellationRequested && TargetSlots.Wait(0))
                        {
                            ProbeTarget target = targets[nextTarget];
                            try
                            {
                                tasks.Add(Task.Factory.StartNew(delegate
                                {
                                    try
                                    {
                                        token.ThrowIfCancellationRequested();
                                        int latency;
                                        bool success = RunTarget(config, target, token, out latency);
                                        return new TargetResult { Completed = !token.IsCancellationRequested,
                                            Success = success, Latency = latency };
                                    }
                                    catch (OperationCanceledException) { return new TargetResult(); }
                                    catch { return new TargetResult { Completed = !token.IsCancellationRequested }; }
                                    finally { TargetSlots.Release(); }
                                }, CancellationToken.None, TaskCreationOptions.LongRunning, TaskScheduler.Default));
                                indices.Add(nextTarget++);
                            }
                            catch { TargetSlots.Release(); throw; }
                        }
                        if (tasks.Count == 0)
                        {
                            if (nextTarget >= targets.Count) { break; }
                            token.WaitHandle.WaitOne(25);
                            continue;
                        }
                        int finished = Task.WaitAny(tasks.ToArray(), 25);
                        if (finished < 0) { continue; }
                        int index = indices[finished];
                        TargetResult result = tasks[finished].GetAwaiter().GetResult();
                        results[index] = result;
                        tasks.RemoveAt(finished);
                        indices.RemoveAt(finished);
                        if (result.Success && (targets[index].ContentVerified || !hasContent)) { break; }
                    }
                    // Capture only completed results. Late workers have no reference to
                    // this outcome or the engine and cannot overwrite the next round.
                    for (int i = 0; i < tasks.Count; i++)
                    {
                        if (tasks[i].Status == TaskStatus.RanToCompletion) { results[indices[i]] = tasks[i].Result; }
                    }
                }
                finally { round.Cancel(); }
            }
            cancellation.ThrowIfCancellationRequested();
            return results;
        }

        private static bool RunTarget(AppConfig config, ProbeTarget target, CancellationToken token, out int latency)
        {
            if (target.Kind == "http")
            {
                return HttpTarget(target.Url, target.Expect, target.ExpectStatus,
                    Math.Max(500, config.HttpProbeTimeoutMs), token, out latency);
            }
            if (target.Kind == "icmp") { return PingTarget(target.Host, config.ProbeTimeoutMs, token, out latency); }
            return TcpTarget(target.Host, target.Port, config.ProbeTimeoutMs, token, out latency);
        }

        public static bool ContentCheck(AppConfig config, out int latencyMs)
        {
            return ContentCheck(config, CancellationToken.None, out latencyMs);
        }

        public static bool ContentCheck(AppConfig config, CancellationToken token, out int latencyMs)
        {
            ProbeOutcome outcome = Probe(config, 2, 300, token, true);
            latencyMs = outcome.LatencyMs;
            return outcome.Verified;
        }

        public static bool HttpTarget(string url, string expect, int expectStatus, int timeoutMs, out int latencyMs)
        {
            return HttpTarget(url, expect, expectStatus, timeoutMs, CancellationToken.None, out latencyMs);
        }

        private static bool HttpTarget(string url, string expect, int expectStatus, int timeoutMs,
            CancellationToken token, out int latencyMs)
        {
            latencyMs = -1;
            var watch = Stopwatch.StartNew();
            try
            {
                token.ThrowIfCancellationRequested();
                var request = (HttpWebRequest)WebRequest.Create(url);
                request.Method = "GET";
                request.Proxy = null;
                request.AllowAutoRedirect = false;
                request.Timeout = timeoutMs;
                request.ReadWriteTimeout = timeoutMs;
                request.UserAgent = AppConfig.DefaultUserAgent;
                request.KeepAlive = false;
                request.CachePolicy = new System.Net.Cache.RequestCachePolicy(System.Net.Cache.RequestCacheLevel.NoCacheNoStore);
                using (token.Register(delegate { try { request.Abort(); } catch { } }))
                using (var response = (HttpWebResponse)request.GetResponse())
                {
                    int code = (int)response.StatusCode;
                    if (expectStatus > 0 ? code != expectStatus : code < 200 || code > 299) { return false; }
                    if (!string.IsNullOrEmpty(expect))
                    {
                        string body = ReadProbeBody(response, 4096);
                        if (body.IndexOf(expect, StringComparison.OrdinalIgnoreCase) < 0) { return false; }
                    }
                }
                token.ThrowIfCancellationRequested();
                latencyMs = (int)watch.ElapsedMilliseconds;
                return true;
            }
            catch { token.ThrowIfCancellationRequested(); return false; }
        }

        private static string ReadProbeBody(HttpWebResponse response, int maxChars)
        {
            using (Stream stream = response.GetResponseStream())
            using (var reader = new StreamReader(stream, Encoding.UTF8, true))
            {
                var buffer = new char[maxChars];
                int read = reader.Read(buffer, 0, buffer.Length);
                return read > 0 ? new string(buffer, 0, read) : string.Empty;
            }
        }

        public static bool TcpTarget(string host, int port, int timeoutMs, out int latencyMs)
        {
            return TcpTarget(host, port, timeoutMs, CancellationToken.None, out latencyMs);
        }

        private static bool TcpTarget(string host, int port, int timeoutMs, CancellationToken token, out int latencyMs)
        {
            latencyMs = -1;
            var watch = Stopwatch.StartNew();
            using (var client = new TcpClient())
            {
                try
                {
                    token.ThrowIfCancellationRequested();
                    using (token.Register(delegate { try { client.Close(); } catch { } }))
                    {
                        IAsyncResult pending = client.BeginConnect(host, port, null, null);
                        using (WaitHandle ready = pending.AsyncWaitHandle)
                        {
                            if (WaitHandle.WaitAny(new[] { ready, token.WaitHandle }, timeoutMs) != 0)
                            {
                                token.ThrowIfCancellationRequested();
                                return false;
                            }
                        }
                        client.EndConnect(pending);
                    }
                    latencyMs = (int)watch.ElapsedMilliseconds;
                    return true;
                }
                catch { token.ThrowIfCancellationRequested(); return false; }
            }
        }

        public static bool PingTarget(string host, int timeoutMs, out int latencyMs)
        {
            return PingTarget(host, timeoutMs, CancellationToken.None, out latencyMs);
        }

        private static bool PingTarget(string host, int timeoutMs, CancellationToken token, out int latencyMs)
        {
            latencyMs = -1;
            try
            {
                token.ThrowIfCancellationRequested();
                using (var ping = new Ping())
                using (token.Register(delegate { try { ping.SendAsyncCancel(); } catch { } }))
                {
                    Task<PingReply> pending = ping.SendPingAsync(host, timeoutMs);
                    if (!pending.Wait(timeoutMs, token)) { return false; }
                    PingReply reply = pending.Result;
                    if (reply.Status != IPStatus.Success) { return false; }
                    latencyMs = (int)reply.RoundtripTime;
                    return true;
                }
            }
            catch { token.ThrowIfCancellationRequested(); return false; }
        }

        private static readonly object InfoGate = new object();
        private static NetworkInfo _infoCache;
        private static DateTime _infoCacheUtc = DateTime.MinValue;
        private const int InfoCacheSeconds = 30;

        /// <summary>网卡信息缓存有效期内的读取（缓存 30 秒；状态翻转或手动刷新时立即失效）。</summary>
        public static NetworkInfo GetNetworkInfo()
        {
            lock (InfoGate)
            {
                if (_infoCache != null && (DateTime.UtcNow - _infoCacheUtc).TotalSeconds < InfoCacheSeconds)
                {
                    return Clone(_infoCache);
                }
                _infoCache = QueryNetworkInfo();
                _infoCacheUtc = DateTime.UtcNow;
                return Clone(_infoCache);
            }
        }

        /// <summary>让下一次读取重新枚举网卡（联网状态翻转、界面点刷新、复制诊断时调用）。</summary>
        public static void InvalidateNetworkInfo()
        {
            lock (InfoGate) { _infoCacheUtc = DateTime.MinValue; }
        }

        private static NetworkInfo Clone(NetworkInfo source)
        {
            return new NetworkInfo
            {
                HasAdapter = source.HasAdapter,
                AdapterName = source.AdapterName,
                AdapterType = source.AdapterType,
                IPv4 = source.IPv4,
                Gateway = source.Gateway,
                Dns = source.Dns
            };
        }

        private static NetworkInfo QueryNetworkInfo()
        {
            var info = new NetworkInfo();
            try
            {
                NetworkInterface best = null;
                foreach (NetworkInterface nic in NetworkInterface.GetAllNetworkInterfaces())
                {
                    if (nic.OperationalStatus != OperationalStatus.Up) { continue; }
                    if (nic.NetworkInterfaceType == NetworkInterfaceType.Loopback) { continue; }
                    IPInterfaceProperties properties = nic.GetIPProperties();
                    bool hasGateway = properties.GatewayAddresses.Count > 0;
                    bool hasUnicast = false;
                    foreach (UnicastIPAddressInformation address in properties.UnicastAddresses)
                    {
                        if (address.Address.AddressFamily != AddressFamily.InterNetwork) { continue; }
                        string text = address.Address.ToString();
                        if (text.StartsWith("169.254.", StringComparison.Ordinal)) { continue; }
                        hasUnicast = true;
                        break;
                    }
                    if (!hasUnicast) { continue; }
                    if (best == null || (hasGateway && best.GetIPProperties().GatewayAddresses.Count == 0)) { best = nic; }
                }

                if (best == null) { return info; }
                info.HasAdapter = true;
                info.AdapterName = best.Name;
                info.AdapterType = DescribeType(best.NetworkInterfaceType);
                IPInterfaceProperties props = best.GetIPProperties();
                foreach (UnicastIPAddressInformation address in props.UnicastAddresses)
                {
                    if (address.Address.AddressFamily != AddressFamily.InterNetwork) { continue; }
                    string text = address.Address.ToString();
                    if (text.StartsWith("169.254.", StringComparison.Ordinal)) { continue; }
                    info.IPv4 = text;
                    break;
                }
                foreach (GatewayIPAddressInformation gateway in props.GatewayAddresses)
                {
                    if (gateway.Address.AddressFamily != AddressFamily.InterNetwork) { continue; }
                    info.Gateway = gateway.Address.ToString();
                    break;
                }
                var dns = new List<string>();
                foreach (IPAddress address in props.DnsAddresses)
                {
                    if (address.AddressFamily == AddressFamily.InterNetwork) { dns.Add(address.ToString()); }
                }
                info.Dns = string.Join(" / ", dns.ToArray());
            }
            catch { }
            return info;
        }

        private static string DescribeType(NetworkInterfaceType type)
        {
            switch (type)
            {
                case NetworkInterfaceType.Wireless80211: return "无线";
                case NetworkInterfaceType.Ethernet: return "有线";
                case NetworkInterfaceType.GigabitEthernet: return "有线";
                case NetworkInterfaceType.FastEthernetT: return "有线";
                case NetworkInterfaceType.FastEthernetFx: return "有线";
                case NetworkInterfaceType.Ppp: return "拨号";
                case NetworkInterfaceType.Tunnel: return "隧道";
                default: return type.ToString();
            }
        }
    }

    public sealed class StatusResult
    {
        public bool Reachable;
        public bool Online;
        public string Text = string.Empty;
        public string Error = string.Empty;
        public string UserId = string.Empty;
    }

    public sealed class PortalLoginResult
    {
        public bool Success;
        public bool RateLimited;
        public bool AlreadyOnline;
        /// <summary>true = 收到了 Portal 的业务提示（Msg/msga），而不是传输失败或无法识别的响应。</summary>
        public bool BusinessPrompt;
        public long ResponseMilliseconds;
        public string Message = string.Empty;
    }

    /// <summary>Dr.COM ePortal 接口客户端。所有请求都显式绕过系统代理，避免被本机代理软件劫持。</summary>
    public sealed class PortalClient
    {
        private readonly AppConfig _config;
        private static readonly SemaphoreSlim StatusSlots = new SemaphoreSlim(2, 2);

        public PortalClient(AppConfig config) { _config = config; }

        public StatusResult GetStatus() { return GetStatus(CancellationToken.None); }

        public StatusResult GetStatus(CancellationToken token)
        {
            token.ThrowIfCancellationRequested();
            // Cancellation normally aborts immediately; bounded slots also cover a DNS
            // lookup that outlives its cancelled engine generation on .NET Framework.
            if (!StatusSlots.Wait(0, token)) { return new StatusResult { Error = "旧的状态请求仍在结束，本轮跳过" }; }
            try
            {
                using (var deadline = CancellationTokenSource.CreateLinkedTokenSource(token))
                {
                    deadline.CancelAfter(Math.Max(1, _config.StatusTimeoutSec) * 1000);
                    try { return GetStatusCore(deadline.Token); }
                    catch (OperationCanceledException)
                    {
                        token.ThrowIfCancellationRequested();
                        return new StatusResult { Error = "状态请求超过整轮截止时间" };
                    }
                }
            }
            finally { StatusSlots.Release(); }
        }

        private StatusResult GetStatusCore(CancellationToken token)
        {
            var result = new StatusResult();
            try
            {
                string callback = "dr" + new Random().Next(100, 9999).ToString(CultureInfo.InvariantCulture);
                string url = _config.StatusUrl + "?callback=" + callback + "&v=" + callback + "&lang=zh&jsVersion=4.X";
                string text = Get(url, _config.StatusTimeoutSec, token);
                result.Text = text;
                Dictionary<string, object> map = ParseJsonp(text);
                if (map != null && map.ContainsKey("result"))
                {
                    result.Reachable = true;
                    result.Online = Json.GetInt(map, "result", 0) == 1;
                    result.UserId = Json.GetString(map, "uid", string.Empty);
                }
                else
                {
                    var match = Regex.Match(text ?? string.Empty, "\"result\"\\s*:\\s*(-?\\d+)");
                    if (match.Success)
                    {
                        result.Reachable = true;
                        result.Online = int.Parse(match.Groups[1].Value, CultureInfo.InvariantCulture) == 1;
                    }
                    else
                    {
                        result.Error = "状态接口返回无法解析：" + Shorten(text);
                    }
                }
            }
            catch (Exception ex)
            {
                token.ThrowIfCancellationRequested();
                result.Error = Describe(ex);
            }
            return result;
        }

        public PortalLoginResult Login(string userName, string password)
        { return Login(userName, password, CancellationToken.None); }

        public PortalLoginResult Login(string userName, string password, CancellationToken token)
        {
            var result = new PortalLoginResult();
            var fields = new List<KeyValuePair<string, string>>();
            fields.Add(new KeyValuePair<string, string>("DDDDD", userName));
            fields.Add(new KeyValuePair<string, string>("upass", password));
            foreach (var pair in _config.StaticFields)
            {
                fields.Add(new KeyValuePair<string, string>(pair.Key, pair.Value ?? string.Empty));
            }

            string text;
            var responseWatch = Stopwatch.StartNew();
            try
            {
                text = Post(_config.LoginUrl, fields, _config.LoginTimeoutSec, token);
                result.ResponseMilliseconds = responseWatch.ElapsedMilliseconds;
            }
            catch (Exception ex)
            {
                token.ThrowIfCancellationRequested();
                result.ResponseMilliseconds = responseWatch.ElapsedMilliseconds;
                result.Message = Describe(ex);
                return result;
            }

            if (text == null) { text = string.Empty; }
            if (text.IndexOf("Dr.COMWebLoginID_3.htm", StringComparison.OrdinalIgnoreCase) >= 0)
            {
                result.Success = true;
                result.Message = "登录成功";
                return result;
            }
            if (text.IndexOf("Dr.COMWebLoginID_2.htm", StringComparison.OrdinalIgnoreCase) >= 0)
            {
                string msg = Match(text, "Msg=(\\d+)");
                string msga = Match(text, "msga='([^']*)'");
                // Translation is diagnostic only; never block recovery on another HTTP request.
                result.AlreadyOnline = msga.IndexOf("userid error2", StringComparison.OrdinalIgnoreCase) >= 0;
                result.RateLimited = msga.IndexOf("waitsec", StringComparison.OrdinalIgnoreCase) >= 0;
                result.BusinessPrompt = true;
                result.Message = "Msg=" + msg + ", " + msga;
                return result;
            }
            if (text.IndexOf("Error code:", StringComparison.OrdinalIgnoreCase) >= 0 && text.IndexOf("205", StringComparison.Ordinal) >= 0)
            {
                result.RateLimited = true;
                result.Message = "请求过于频繁：" + Shorten(text);
                return result;
            }
            if (text.IndexOf("waitsec", StringComparison.OrdinalIgnoreCase) >= 0)
            {
                result.RateLimited = true;
                result.Message = "请求过于频繁：" + Shorten(text);
                return result;
            }
            result.Message = "未知响应：" + Shorten(text);
            return result;
        }

        public bool Logout() { return Logout(CancellationToken.None); }

        public bool Logout(CancellationToken token)
        {
            try
            {
                string callback = "dr" + new Random().Next(100, 9999).ToString(CultureInfo.InvariantCulture);
                string url = _config.LogoutUrl + "?callback=" + callback + "&v=" + callback + "&lang=zh&jsVersion=4.X";
                string text = Get(url, _config.StatusTimeoutSec, token);
                Dictionary<string, object> map = ParseJsonp(text);
                return map != null && Json.GetInt(map, "result", 0) == 1;
            }
            catch { token.ThrowIfCancellationRequested(); return false; }
        }

        public string Translate(string code)
        {
            if (string.IsNullOrWhiteSpace(code)) { return string.Empty; }
            try
            {
                string url = _config.ErrorUrl + "?error_code=" + Uri.EscapeDataString(code) + "&callback=dr1&jsVersion=4.X&v=1&lang=zh";
                string text = Get(url, _config.StatusTimeoutSec);
                Dictionary<string, object> map = ParseJsonp(text);
                if (map != null)
                {
                    string prompt = Json.GetString(map, "error_prompt_zh", string.Empty);
                    if (!string.IsNullOrEmpty(prompt)) { return prompt; }
                }
            }
            catch { }
            return code;
        }

        private static Dictionary<string, object> ParseJsonp(string text)
        {
            if (string.IsNullOrWhiteSpace(text)) { return null; }
            int start = text.IndexOf('(');
            int end = text.LastIndexOf(')');
            string json = start >= 0 && end > start ? text.Substring(start + 1, end - start - 1) : text;
            try { return Json.ReadObjectFromText(json); } catch { return null; }
        }

        private static string Match(string text, string pattern)
        {
            Match match = Regex.Match(text ?? string.Empty, pattern);
            return match.Success ? match.Groups[1].Value : string.Empty;
        }

        private static string Shorten(string text)
        {
            if (string.IsNullOrEmpty(text)) { return string.Empty; }
            string flat = Regex.Replace(text, "\\s+", " ").Trim();
            return flat.Length > 200 ? flat.Substring(0, 200) : flat;
        }

        private static string Describe(Exception ex)
        {
            var web = ex as WebException;
            if (web != null)
            {
                if (web.Status == WebExceptionStatus.Timeout) { return "请求超时"; }
                if (web.Status == WebExceptionStatus.NameResolutionFailure) { return "域名解析失败"; }
                if (web.Status == WebExceptionStatus.ConnectFailure) { return "无法连接到 Portal"; }
                return web.Message;
            }
            return ex.Message;
        }

        private string Get(string url, int timeoutSec)
        { return Get(url, timeoutSec, CancellationToken.None); }

        private string Get(string url, int timeoutSec, CancellationToken token)
        {
            token.ThrowIfCancellationRequested();
            HttpWebRequest request = CreateRequest(url, timeoutSec, "GET", true);
            using (token.Register(delegate { try { request.Abort(); } catch { } }))
            using (var response = (HttpWebResponse)request.GetResponse())
            {
                EnsureSameHost(request, response);
                return ReadText(response, request);
            }
        }

        private string Post(string url, List<KeyValuePair<string, string>> fields, int timeoutSec, CancellationToken token)
        {
            // 登录请求带着账号密码，绝不能自动跟随跳转：
            // 一个 307/308 就能把「账号 + 密码」原样转发到别的地址。
            token.ThrowIfCancellationRequested();
            HttpWebRequest request = CreateRequest(url, timeoutSec, "POST", false);
            using (token.Register(delegate { try { request.Abort(); } catch { } }))
            {
                request.ContentType = "application/x-www-form-urlencoded";
                request.Referer = _config.PortalBase + "/";
                var body = new StringBuilder();
                foreach (var pair in fields)
                {
                    if (body.Length > 0) { body.Append('&'); }
                    body.Append(Uri.EscapeDataString(pair.Key)).Append('=').Append(Uri.EscapeDataString(pair.Value));
                }
                byte[] payload = Encoding.UTF8.GetBytes(body.ToString());
                request.ContentLength = payload.Length;
                using (Stream stream = request.GetRequestStream())
                {
                    stream.Write(payload, 0, payload.Length);
                }
                using (var response = (HttpWebResponse)request.GetResponse())
                {
                    EnsureSameHost(request, response);
                    return ReadText(response, request);
                }
            }
        }

        /// <summary>
        /// 响应必须来自我们请求的那台主机。跨主机跳转（含 DNS 改指过来的页面）一律丢弃，
        /// 免得把别人的页面当成 Portal 的回答——尤其是「登录成功」这种结论。
        /// </summary>
        private static void EnsureSameHost(HttpWebRequest request, HttpWebResponse response)
        {
            string expected = request.RequestUri == null ? string.Empty : request.RequestUri.Host;
            string actual = response.ResponseUri == null ? expected : response.ResponseUri.Host;
            if (!string.Equals(expected, actual, StringComparison.OrdinalIgnoreCase))
            {
                throw new IOException("响应来自非预期主机（" + actual + "，期望 " + expected + "），已丢弃。");
            }
        }

        private HttpWebRequest CreateRequest(string url, int timeoutSec, string method, bool allowRedirect)
        {
            var request = (HttpWebRequest)WebRequest.Create(url);
            request.Method = method;
            request.Timeout = timeoutSec * 1000;
            request.ReadWriteTimeout = timeoutSec * 1000;
            request.AllowAutoRedirect = allowRedirect;
            request.UserAgent = _config.UserAgent;
            request.KeepAlive = false;
            request.Accept = "*/*";
#pragma warning disable 618
            request.Proxy = GlobalProxySelection.GetEmptyWebProxy();
#pragma warning restore 618
            return request;
        }

        private static string ReadText(HttpWebResponse response, HttpWebRequest request)
        {
            byte[] buffer;
            using (Stream stream = response.GetResponseStream())
            {
                if (stream == null) { return string.Empty; }
                using (var memory = new MemoryStream())
                {
                    var chunk = new byte[8192];
                    int read;
                    while ((read = stream.Read(chunk, 0, chunk.Length)) > 0)
                    {
                        memory.Write(chunk, 0, read);
                        if (memory.Length > 2 * 1024 * 1024) { break; }
                    }
                    buffer = memory.ToArray();
                }
            }
            string charset = null;
            try { charset = response.CharacterSet; } catch { }
            if (string.IsNullOrEmpty(charset))
            {
                string header = response.ContentType;
                if (!string.IsNullOrEmpty(header))
                {
                    Match match = Regex.Match(header, "charset=([\\w-]+)", RegexOptions.IgnoreCase);
                    if (match.Success) { charset = match.Groups[1].Value; }
                }
            }
            if (!string.IsNullOrEmpty(charset))
            {
                try { return Encoding.GetEncoding(charset).GetString(buffer); } catch { }
            }
            try { return new UTF8Encoding(false, true).GetString(buffer); } catch { }
            return Encoding.GetEncoding(28591).GetString(buffer);
        }
    }
}
