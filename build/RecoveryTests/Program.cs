using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Net;
using System.Net.Sockets;
using System.Text;
using System.Threading;
using System.Threading.Tasks;
using CampusNet.Core;

internal static class Program
{
    private static int failures;
    private static readonly string Root = Path.GetFullPath(Environment.GetEnvironmentVariable("CAMPUS_TEST_ROOT") ??
        Path.Combine(Path.GetTempPath(), "CampusNet-Recovery-" + Guid.NewGuid().ToString("N")));

    private static void Assert(bool condition, string message)
    {
        if (!condition) { throw new Exception(message); }
    }

    private static void Until(Func<bool> predicate, int seconds, string message)
    {
        var timer = Stopwatch.StartNew();
        while (timer.Elapsed.TotalSeconds < seconds)
        {
            if (predicate()) { return; }
            Thread.Sleep(25);
        }
        throw new Exception(message);
    }

    private static void Test(string name, Action action)
    {
        try { action(); Console.WriteLine("PASS " + name); }
        catch (Exception ex) { failures++; Console.WriteLine("FAIL " + name + ": " + ex); }
    }

    private static int Main(string[] args)
    {
        ThreadPool.SetMinThreads(32, 32);
        Directory.CreateDirectory(Root);
        Console.WriteLine("Test artifacts: " + Root);
        Test("whole probe round has a deadline", ProbeDeadline);
        Test("Portal status has a whole-request deadline", StatusDeadline);
        Test("concurrent state writes stay atomic", AtomicState);
        Test("more than eight targets can reach a later success", ManyTargets);
        Test("first verified target wins; unfinished targets are not failures", EarlyTarget);
        Test("Portal online alone never verifies content", FalseOnline);
        Test("legacy TCP requires both transport and session", Legacy);
        Test("missing credentials never submits or throws", MissingCredential);
        Test("minimum interval blocks logout as well as login", () => Blocked(false));
        Test("hourly limit blocks logout as well as login", () => Blocked(true));
        Test("pause cancels pre-login confirmation", Pause);
        Test("reload keeps counters and cancels old recovery", Reload);
        Test("upstream status does not suspend local recovery for 300 seconds", Upstream);
        foreach (int seconds in new[] { 0, 5, 15, 30, 60 })
        {
            int delay = seconds;
            Test("recovery at +" + delay + " seconds", () => Recovery(delay, false));
        }
        Test("slow Portal cannot delay local verification", () => Recovery(5, true));
        Test("a stuck episode logs out at most once", ForcedOnce);
        Console.WriteLine("Recovery tests: " + (failures == 0 ? "ALL PASSED" : failures + " FAILED"));
        return failures == 0 ? 0 : 1;
    }

    private static void ProbeDeadline()
    {
        using (var server = new Portal())
        {
            server.SlowBeforeLogin = true;
            var config = server.Config();
            config.ProbeTargets = new List<string> { server.Target("/slow/one"), server.Target("/slow/two") };
            var timer = Stopwatch.StartNew();
            ProbeOutcome result = NetworkProbe.Probe(config, 1, 0);
            Assert(!result.Verified && timer.Elapsed.TotalSeconds < 3.8, "round exceeded its default 3s deadline");
            Assert(result.Incomplete > 0, "deadline did not mark unfinished requests");
        }
    }

    private static void StatusDeadline()
    {
        using (var server = new Portal())
        {
            server.LoginCount = 1;
            server.StatusAlwaysOnline = true;
            server.StatusAfterLoginDelayMs = 12000;
            var config = server.Config();
            config.StatusTimeoutSec = 1;
            var timer = Stopwatch.StartNew();
            StatusResult result = new PortalClient(config).GetStatus();
            Assert(!result.Reachable && timer.Elapsed.TotalSeconds < 2, "slow Portal exceeded deadline or reported online");
        }
    }

    private static void AtomicState()
    {
        string path = Path.Combine(Root, "concurrent-state.json");
        new AppState().Save(path);
        Task[] writers = Enumerable.Range(0, 4).Select(n => Task.Run(() =>
        {
            for (int i = 0; i < 40; i++)
            {
                new AppState { LoginWindowCount = n * 40 + i }.Save(path);
                Assert(Json.ReadObject(path) != null, "atomic state disappeared or became invalid");
            }
        })).ToArray();
        Task.WaitAll(writers);
        Assert(Json.ReadObject(path) != null, "final state is invalid");
    }

    private static void ManyTargets()
    {
        using (var server = new Portal())
        {
            server.AlwaysContent = true;
            var config = server.Config();
            config.ProbeTargets = Enumerable.Repeat("tcp:127.0.0.1:1", 9).ToList();
            config.ProbeTargets.Add(server.Target("/content"));
            Assert(NetworkProbe.Probe(config, 1, 0).Verified, "later content target was never scheduled");
        }
    }

    private static void EarlyTarget()
    {
        using (var server = new Portal())
        {
            server.AlwaysContent = true;
            server.SlowBeforeLogin = true;
            var config = server.Config();
            config.ProbeTargets = new List<string> { server.Target("/slow"), server.Target("/content") };
            var timer = Stopwatch.StartNew();
            ProbeOutcome result = NetworkProbe.Probe(config, 1, 0);
            Assert(result.Verified && timer.ElapsedMilliseconds < 1000, "fast valid target waited for slow target");
            Assert(result.Incomplete >= 1 && result.LossPercent == 0, "unfinished target counted as packet loss");
            server.AlwaysContent = false;
            config.ProbeTargets = new List<string> { server.Target("/content") };
            ProbeOutcome next = NetworkProbe.Probe(config, 1, 0);
            Assert(!next.Verified && result.Verified, "a late result changed another round");
        }
    }

    private static void FalseOnline()
    {
        using (var f = new Fixture("false-online"))
        {
            f.Server.StatusAlwaysOnline = true;
            f.Config.OfflineProbeSeconds = 1;
            f.Config.StuckReloginSeconds = 0;
            f.Start();
            Until(() => f.Server.StatusCount > 0, 10, "no status query");
            Thread.Sleep(150);
            Assert(!f.Engine.Snapshot().Online, "Portal-only success reported online");
            Assert(f.Server.LoginCount == 0, "unverified upstream prompted immediate login");
        }
    }

    private static void Legacy()
    {
        using (var f = new Fixture("legacy"))
        {
            f.Server.StatusAlwaysOnline = true;
            f.Config.ProbeTargets = new List<string> { "tcp:127.0.0.1:" + f.Server.Port };
            f.Start();
            Until(() => f.Engine.Snapshot().Online, 5, "TCP + Portal did not confirm");
            Assert(f.Server.StatusCount > 0, "TCP alone was accepted");
            Assert(f.Engine.Snapshot().StatusText.Contains("未验证内容"), "legacy confidence not shown");
        }
    }

    private static void MissingCredential()
    {
        using (var f = new Fixture("no-credential"))
        {
            f.Config.OfflineProbeSeconds = 1;
            f.Start(false);
            Until(() => f.Engine.Snapshot().StatusKey == "no-credential", 10, "missing credential guard not reached");
            Assert(f.Server.LoginCount == 0 && !f.Log().Contains("内部异常"), "invalid credentials caused a request or exception");
        }
    }

    private static void Blocked(bool hourly)
    {
        using (var f = new Fixture(hourly ? "hourly" : "interval"))
        {
            f.Server.StatusAlwaysOnline = true;
            f.Server.AlwaysContent = true;
            var state = new AppState {
                LastLoginAttempt = hourly ? "" : DateTime.Now.ToString("yyyy-MM-dd HH:mm:ss.fff", CultureInfo.InvariantCulture),
                LoginWindowStart = AppPaths.FormatTime(DateTime.Now),
                LoginWindowCount = hourly ? 12 : 1
            };
            state.Save(Path.Combine(f.Dir, "state.json"));
            f.Start(true, true);
            Until(() => f.Engine.Snapshot().StatusKey == (hourly ? "login-throttled" : "login-wait"),
                5, "gate was not applied");
            Assert(f.Server.LogoutCount == 0 && f.Server.LoginCount == 0, "blocked relogin still logged out");
            Assert(f.Engine.Snapshot().Online, "blocked relogin discarded valid connectivity evidence");
        }
    }

    private static void Pause()
    {
        using (var f = new Fixture("pause"))
        {
            f.Config.LoginConfirmDelaySec = 10;
            f.Config.OfflineProbeSeconds = 1;
            f.Start();
            Until(() => f.Server.StatusCount >= 1, 6, "confirmation did not begin");
            var timer = Stopwatch.StartNew();
            f.Engine.Pause(null);
            Until(() => !f.Engine.Snapshot().Busy, 2, "paused flow stayed busy");
            Thread.Sleep(300);
            Assert(timer.Elapsed.TotalSeconds < 2 && f.Server.LoginCount == 0, "cancelled flow submitted login");
            Assert(f.Engine.IsPaused, "pause lost");
        }
    }

    private static void Reload()
    {
        using (var f = new Fixture("reload"))
        {
            f.Config.OfflineProbeSeconds = 1;
            f.Start();
            Until(() => f.Server.LoginCount == 1, 8, "login not submitted");
            Assert(AppState.Load(Path.Combine(f.Dir, "state.json")).LoginWindowCount == 1, "count was not persisted before POST");
            AppConfig pendingEdit = f.Engine.Config;
            pendingEdit.LoginMinIntervalSeconds = 0;
            pendingEdit.ProbeTargets.Clear();
            pendingEdit.StaticFields.Clear();
            Assert(f.Engine.Config.LoginMinIntervalSeconds == 60 && f.Engine.Config.ProbeTargets.Count > 0 &&
                f.Engine.Config.StaticFields.Count > 0, "editing UI configuration mutated an active flow");
            var stale = new AppState { RunCount = 0, LoginWindowCount = 0 };
            stale.Save(Path.Combine(f.Dir, "state.json"));
            f.Engine.Reload();
            Until(() => !f.Engine.Snapshot().Busy, 2, "reload did not cancel old recovery");
            Thread.Sleep(1200);
            Assert(f.Engine.Snapshot().LoginWindowCount == 1, "reload overwrote live attempt count");
            Assert(f.Server.LoginCount == 1, "reload bypassed minimum interval");
        }
    }

    private static void Upstream()
    {
        using (var f = new Fixture("upstream"))
        {
            f.Server.StatusAlwaysOnline = true;
            f.Server.ContentFromStartSeconds = 3;
            f.Config.ProbeTargets = new List<string> { f.Server.Target("/content") };
            f.Config.ConfirmAttempts = 1;
            f.Config.StuckReloginSeconds = 0;
            f.Start();
            Until(() => f.Engine.Snapshot().Online, 9, "local probes slept for upstream interval");
            Assert(f.Server.ElapsedSeconds - 3 < 6, "local recovery lag exceeded 6 seconds");
            Assert(f.Server.StatusCount == 1 && f.Server.LoginCount == 0, "upstream portal budget not preserved");
        }
    }

    private static void Recovery(int readySeconds, bool slowPortal)
    {
        using (var f = new Fixture("ready-" + readySeconds + (slowPortal ? "-slow-portal" : "")))
        {
            f.Server.ReadyAfterLoginSeconds = readySeconds;
            f.Server.StatusAfterLoginDelayMs = slowPortal ? 12000 : 0;
            f.Config.ProbeTargets.Insert(0, f.Server.Target("/slow"));
            f.Start();
            Until(() => f.Server.LoginCount == 1, 15, "no login; " + f.Log());
            double submit = f.Server.FirstLoginSeconds;
            Until(() => f.Engine.Snapshot().Online, readySeconds + 10, "content did not recover; " + f.Log());
            double lag = f.Server.ElapsedSeconds - submit - readySeconds;
            double bound = readySeconds < 30 ? 4 : 6;
            Console.WriteLine("METRIC ready=" + readySeconds + " slowPortal=" + slowPortal +
                " confirmationLagSeconds=" + lag.ToString("F3", CultureInfo.InvariantCulture));
            Assert(lag >= -0.1 && lag <= bound, "confirmation lag " + lag + " exceeds " + bound);
            Assert(f.Server.LoginCount == 1 && f.Server.LogoutCount == 0, "recovery added a login/logout");
            Assert(f.Server.StatusAfterLoginCount <= 6, "more than six recovery status queries");
            Assert(!f.Log().Contains("内部异常"), "recovery threw");
        }
    }

    private static void ForcedOnce()
    {
        using (var f = new Fixture("forced-once"))
        {
            f.Server.StatusAlwaysOnline = true;
            f.Config.ProbeTargets = new List<string> { f.Server.Target("/content") };
            f.Config.OfflineProbeSeconds = 1;
            f.Config.ConfirmAttempts = 1;
            f.Config.StuckReloginSeconds = 2;
            f.Config.LoginMinIntervalSeconds = 2;
            f.Start();
            Until(() => f.Server.LoginCount == 1, 10, "stuck session did not relogin");
            Until(() => !f.Engine.Snapshot().Busy, 34, "recovery window did not finish");
            Thread.Sleep(2200);
            Assert(f.Server.LogoutCount == 1 && f.Server.LoginCount == 1, "same fault repeatedly forced relogin");
            Assert(!f.Engine.Snapshot().Online, "unverified session reset the episode");
        }
    }

    private sealed class Fixture : IDisposable
    {
        public readonly Portal Server = new Portal();
        public readonly string Dir;
        public readonly AppConfig Config;
        public LoginEngine Engine;
        public Fixture(string name)
        {
            Dir = Path.Combine(Root, name + "-" + Guid.NewGuid().ToString("N").Substring(0, 8));
            Directory.CreateDirectory(Dir);
            Config = Server.Config();
        }
        public void Start(bool credential = true, bool manual = false)
        {
            AppPaths.DataDirOverride = Dir;
            Config.Save(Path.Combine(Dir, "config.json"));
            if (credential) { CredentialStore.Save(Path.Combine(Dir, "credentials.dat"), "testuser", "testpass"); }
            Engine = new LoginEngine(new Logger(Path.Combine(Dir, "login.log"), Path.Combine(Dir, "login.log.old")));
            if (manual) { Engine.Relogin(); }
            Engine.Start();
        }
        public string Log()
        {
            string path = Path.Combine(Dir, "login.log");
            try { return File.ReadAllText(path); } catch { return ""; }
        }
        public void Dispose()
        {
            if (Engine != null) { Engine.Dispose(); }
            Server.Dispose();
        }
    }

    // Concurrent fake portal: a slow status response must not serialize unrelated
    // content requests. All timing is measured against the real POST receipt.
    private sealed class Portal : IDisposable
    {
        private readonly TcpListener listener;
        private readonly CancellationTokenSource stop = new CancellationTokenSource();
        private readonly Stopwatch watch = Stopwatch.StartNew();
        private readonly object gate = new object();
        private readonly List<TcpClient> clients = new List<TcpClient>();
        private readonly Task accepting;
        public readonly int Port;
        public volatile bool AlwaysContent, StatusAlwaysOnline, SlowBeforeLogin;
        public volatile int ReadyAfterLoginSeconds = -1, ContentFromStartSeconds = -1, StatusAfterLoginDelayMs;
        public int LoginCount, LogoutCount, StatusCount, StatusAfterLoginCount;
        private double firstLogin = -1;
        public double FirstLoginSeconds { get { lock (gate) { return firstLogin; } } }
        public double ElapsedSeconds { get { return watch.Elapsed.TotalSeconds; } }

        public Portal()
        {
            listener = new TcpListener(IPAddress.Loopback, 0);
            listener.Start();
            Port = ((IPEndPoint)listener.LocalEndpoint).Port;
            accepting = Task.Run(() =>
            {
                while (!stop.IsCancellationRequested)
                {
                    try
                    {
                        TcpClient client = listener.AcceptTcpClient();
                        lock (gate) { clients.Add(client); }
                        Task.Run(() => Handle(client));
                    }
                    catch { if (stop.IsCancellationRequested) { break; } throw; }
                }
            });
        }

        public string Target(string path) { return "http:127.0.0.1:" + Port + path + "|CampusNet ready"; }
        public AppConfig Config()
        {
            var config = new AppConfig();
            config.PortalHost = "127.0.0.1:" + Port;
            config.ProbeTargets = new List<string> { Target("/content"), "tcp:127.0.0.1:" + Port };
            config.StuckReloginSeconds = 0;
            return config;
        }

        private void Handle(TcpClient client)
        {
            try
            {
                client.ReceiveTimeout = 2000;
                client.SendTimeout = 2000;
                using (NetworkStream stream = client.GetStream())
                using (var reader = new StreamReader(stream, Encoding.ASCII, false, 1024, true))
                {
                    string request = reader.ReadLine();
                    if (string.IsNullOrEmpty(request)) { return; }
                    int length = 0;
                    string line;
                    while (!string.IsNullOrEmpty(line = reader.ReadLine()))
                    {
                        if (line.StartsWith("Content-Length:", StringComparison.OrdinalIgnoreCase))
                        { int.TryParse(line.Substring(15).Trim(), out length); }
                    }
                    if (length > 0)
                    {
                        char[] body = new char[length];
                        int read = 0;
                        while (read < length)
                        {
                            int count = reader.Read(body, read, length - read);
                            if (count <= 0) { break; }
                            read += count;
                        }
                    }
                    string path = request.Split(' ')[1];
                    string text;
                    if (path.StartsWith("/drcom/chkstatus"))
                    {
                        Interlocked.Increment(ref StatusCount);
                        if (LoginCount > 0)
                        {
                            Interlocked.Increment(ref StatusAfterLoginCount);
                            stop.Token.WaitHandle.WaitOne(StatusAfterLoginDelayMs);
                        }
                        text = "dr1({\"result\":" + (StatusAlwaysOnline ? "1" : "0") + ",\"uid\":\"test\"})";
                    }
                    else if (path.StartsWith("/drcom/logout"))
                    {
                        Interlocked.Increment(ref LogoutCount);
                        text = "dr1({\"result\":1})";
                    }
                    else if (path.StartsWith("/drcom/login"))
                    {
                        lock (gate) { if (firstLogin < 0) { firstLogin = watch.Elapsed.TotalSeconds; } }
                        Interlocked.Increment(ref LoginCount);
                        text = "<!--Dr.COMWebLoginID_2.htm--><script>Msg=01;msga='userid error2';</script>";
                    }
                    else
                    {
                        if (path.StartsWith("/slow") && (LoginCount > 0 || SlowBeforeLogin))
                        { stop.Token.WaitHandle.WaitOne(8000); }
                        bool ready = AlwaysContent || (ContentFromStartSeconds >= 0 && ElapsedSeconds >= ContentFromStartSeconds) ||
                            (ReadyAfterLoginSeconds >= 0 && FirstLoginSeconds >= 0 &&
                            ElapsedSeconds - FirstLoginSeconds >= ReadyAfterLoginSeconds);
                        text = ready ? "CampusNet ready" : "authentication required";
                    }
                    byte[] bodyBytes = Encoding.UTF8.GetBytes(text);
                    byte[] head = Encoding.ASCII.GetBytes("HTTP/1.1 200 OK\r\nContent-Type: text/plain; charset=utf-8\r\nContent-Length: " +
                        bodyBytes.Length + "\r\nConnection: close\r\n\r\n");
                    stream.Write(head, 0, head.Length);
                    stream.Write(bodyBytes, 0, bodyBytes.Length);
                }
            }
            catch { }
            finally { client.Close(); lock (gate) { clients.Remove(client); } }
        }

        public void Dispose()
        {
            stop.Cancel();
            listener.Stop();
            lock (gate) { foreach (TcpClient client in clients.ToArray()) { client.Close(); } }
            try { accepting.Wait(1000); } catch { }
            // Handlers may still be unwinding their cancellation registrations.
        }
    }
}
