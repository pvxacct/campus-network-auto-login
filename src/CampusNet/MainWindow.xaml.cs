using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Globalization;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Documents;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using System.Windows.Shapes;
using System.Windows.Threading;
using CampusNet.Core;
using CampusNet.UI;

namespace CampusNet
{
    public partial class MainWindow : Window
    {
        private readonly LoginEngine _engine;
        private readonly Logger _log;
        private readonly TrayIcon _tray;
        private readonly DispatcherTimer _timer;
        private bool _allowClose;
        private bool _logDirty = true;
        private int _tick;
        private string _logSignature = string.Empty;

        public MainWindow(LoginEngine engine, Logger log, TrayIcon tray)
        {
            _engine = engine;
            _log = log;
            _tray = tray;
            InitializeComponent();
            TrySetIcon();

            _log.LineWritten += delegate { _logDirty = true; };

            _timer = new DispatcherTimer { Interval = TimeSpan.FromSeconds(1) };
            _timer.Tick += delegate
            {
                _tick++;
                UpdateUi();
                if (_logDirty || _tick % 3 == 0) { RefreshLog(); }
            };
            _timer.Start();

            Loaded += delegate
            {
                LoadSettingsIntoUi();
                UpdateUi();
                RefreshLog();
                RefreshLegacyHint();
            };
            Closing += OnClosing;
            StateChanged += delegate
            {
                if (WindowState == WindowState.Minimized) { Hide(); }
            };
        }

        public void AllowClose()
        {
            _allowClose = true;
            try { _timer.Stop(); } catch { }
        }

        public void ShowFromTray()
        {
            Show();
            if (WindowState == WindowState.Minimized) { WindowState = WindowState.Normal; }
            Activate();
        }

        private void TrySetIcon()
        {
            try
            {
                Icon = BitmapFrame.Create(new Uri("pack://application:,,,/Assets/app.ico", UriKind.Absolute));
            }
            catch { }
        }

        private void OnClosing(object sender, System.ComponentModel.CancelEventArgs e)
        {
            if (_allowClose) { return; }
            e.Cancel = true;
            Hide();
            if (_tray != null) { _tray.ShowBalloon(AppPaths.DisplayName, "窗口已收起，程序仍在后台运行。"); }
        }

        // ------------------------------------------------------------- 刷新界面

        private void UpdateUi()
        {
            EngineSnapshot snapshot = _engine.Snapshot();

            StatusText.Text = snapshot.StatusText;
            StatusDot.Background = BrushFor(snapshot.StatusColorKey);
            StatusDetail.Text = BuildDetail(snapshot);

            VersionText.Text = "v" + AppPaths.Version;
            InstallStateText.Text = SelfInstaller.IsInstalled
                ? "已安装到本机 · 开机自启 " + (SelfInstaller.IsAutoStartEnabled ? "已开启" : "已关闭")
                : "便携运行（未安装）";

            NetworkInfo network = snapshot.Network;
            IpText.Text = Fallback(network.IPv4);
            GatewayText.Text = Fallback(network.Gateway);
            DnsText.Text = Fallback(network.Dns);
            AdapterText.Text = string.IsNullOrEmpty(network.AdapterName)
                ? "—"
                : network.AdapterName + "（" + network.AdapterType + "）";
            LatencyText.Text = snapshot.LatencyMs < 0 ? "—" : snapshot.LatencyMs + " ms";
            LossText.Text = snapshot.LossPercent + "%";
            ProbeText.Text = string.IsNullOrEmpty(snapshot.ProbeSummary) ? "等待首次探测…" : "探测明细：" + snapshot.ProbeSummary;

            StatProbe.Text = Describe(snapshot.LastProbe);
            StatLogin.Text = Describe(snapshot.LastLoginSuccess);
            StatResult.Text = ResultText(snapshot.LastResult);
            StatCount.Text = snapshot.LoginWindowCount + " 次";
            StatFail.Text = snapshot.ConsecutiveFailures + " 次";
            StatNextProbe.Text = NextProbeText(snapshot);
            StatSession.Text = SessionText(snapshot);
            StatProbeMode.Text = ProbeModeText();
            StatError.Text = string.IsNullOrEmpty(snapshot.LastError) ? "无" : snapshot.LastError;
            StatIgnored.Text = snapshot.IgnoredPrompts + " 次";
            StatForced.Text = ForcedReloginText(snapshot);

            PauseButton.IsEnabled = !snapshot.Paused;
            ResumeButton.IsEnabled = snapshot.Paused;
            ReloginButton.IsEnabled = !snapshot.Paused;

            CredentialHint.Text = snapshot.HasCredential
                ? "已保存：" + Mask(snapshot.UserName)
                : "尚未保存，保存后才会自动登录";

            bool autoStart = SelfInstaller.IsAutoStartEnabled;
            if (AutoStartCheck.IsChecked != autoStart) { AutoStartCheck.IsChecked = autoStart; }
            InstallButton.Content = SelfInstaller.IsInstalled ? "卸载" : "安装";

            DrawSparkline(snapshot);
        }

        private static string BuildDetail(EngineSnapshot snapshot)
        {
            var parts = new List<string>();
            parts.Add("最近探测 " + Relative(snapshot.LastProbe));
            if (snapshot.LatencyMs >= 0) { parts.Add("延迟 " + snapshot.LatencyMs + " ms"); }
            parts.Add("丢包 " + snapshot.LossPercent + "%");
            parts.Add("累计检查 " + snapshot.RunCount + " 次");
            if (snapshot.Paused)
            {
                parts.Add(snapshot.PauseUntil.HasValue
                    ? "已暂停，直到 " + AppPaths.FormatTime(snapshot.PauseUntil.Value)
                    : "已暂停");
            }
            return string.Join(" · ", parts.ToArray());
        }

        private void DrawSparkline(EngineSnapshot snapshot)
        {
            LatencyCanvas.Children.Clear();
            List<int> history = snapshot.LatencyHistory;
            if (history.Count == 0) { return; }

            double width = LatencyCanvas.ActualWidth;
            double height = LatencyCanvas.ActualHeight;
            if (width <= 1) { width = 400; }
            if (height <= 1) { height = 60; }

            int max = 1;
            foreach (int value in history) { if (value > max) { max = value; } }
            max = (int)(max * 1.25) + 1;

            double slot = width / Math.Max(20, history.Count);
            double barWidth = Math.Max(2, slot - 2);
            for (int i = 0; i < history.Count; i++)
            {
                int value = history[i];
                double barHeight = value < 0 ? 3 : Math.Max(3, (height - 10) * value / max);
                var bar = new Rectangle
                {
                    Width = barWidth,
                    Height = barHeight,
                    RadiusX = 1.5,
                    RadiusY = 1.5,
                    Fill = value < 0 ? BrushFor("red") : BrushFor("green")
                };
                Canvas.SetLeft(bar, i * slot + 1);
                Canvas.SetTop(bar, height - barHeight - 3);
                LatencyCanvas.Children.Add(bar);
            }
        }

        private void RefreshLog()
        {
            bool warningsOnly = WarningOnlyCheck.IsChecked == true;
            List<string> lines = _log.Recent(200, warningsOnly);
            string signature = lines.Count + "|" + warningsOnly + "|" + (lines.Count > 0 ? lines[lines.Count - 1] : string.Empty);
            _logDirty = false;
            if (signature == _logSignature) { return; }
            _logSignature = signature;

            LogView.Document.Blocks.Clear();
            // 行高 18（原 16）：日志默认字号 11.5 时行距太挤，长日志看起来是一坨。
            var paragraph = new Paragraph
            {
                Margin = new Thickness(0),
                LineHeight = 18,
                LineStackingStrategy = LineStackingStrategy.BlockLineHeight
            };
            foreach (string line in lines)
            {
                SolidColorBrush brush;
                if (line.IndexOf("[ERROR]", StringComparison.Ordinal) >= 0) { brush = new SolidColorBrush(Color.FromRgb(0xDC, 0x26, 0x26)); }
                else if (line.IndexOf("[WARN]", StringComparison.Ordinal) >= 0) { brush = new SolidColorBrush(Color.FromRgb(0xEA, 0x58, 0x0C)); }
                else { brush = new SolidColorBrush(Color.FromRgb(0x37, 0x41, 0x51)); }
                paragraph.Inlines.Add(new Run(line) { Foreground = brush });
                paragraph.Inlines.Add(new LineBreak());
            }
            if (lines.Count == 0) { paragraph.Inlines.Add(new Run("暂无日志。")); }
            LogView.Document.Blocks.Add(paragraph);
            LogView.ScrollToEnd();
        }

        private void RefreshLegacyHint()
        {
            LegacyReport report = LegacyCleanup.Detect();
            LegacyHint.Text = report.Any
                ? "检测到旧版残留：" + report.Describe() + "。建议清理，避免两套程序互相顶号。"
                : "没有检测到旧版残留。";
            CleanupButton.IsEnabled = report.Any;
        }

        private void LoadSettingsIntoUi()
        {
            AppConfig config = _engine.Config;
            OnlineProbeBox.Text = config.OnlineProbeSeconds.ToString(CultureInfo.InvariantCulture);
            OfflineProbeBox.Text = config.OfflineProbeSeconds.ToString(CultureInfo.InvariantCulture);
            HourlyLimitBox.Text = config.LoginHourlyLimit.ToString(CultureInfo.InvariantCulture);
            PortalHostBox.Text = config.PortalBase;   // 连协议一起显示，写成 https://… 也认
            MinIntervalBox.Text = config.LoginMinIntervalSeconds.ToString(CultureInfo.InvariantCulture);
            UpstreamProbeBox.Text = config.UpstreamProbeSeconds.ToString(CultureInfo.InvariantCulture);
            ProbeTimeoutBox.Text = config.ProbeTimeoutMs.ToString(CultureInfo.InvariantCulture);
            HttpProbeTimeoutBox.Text = config.HttpProbeTimeoutMs.ToString(CultureInfo.InvariantCulture);
            SessionCheckBox.Text = config.SessionCheckSeconds.ToString(CultureInfo.InvariantCulture);
            StuckReloginBox.Text = config.StuckReloginSeconds.ToString(CultureInfo.InvariantCulture);
            EngineSnapshot snapshot = _engine.Snapshot();
            if (snapshot.HasCredential) { UserNameBox.Text = snapshot.UserName; }
        }

        // ------------------------------------------------------------- 按钮

        private void SaveCredential_Click(object sender, RoutedEventArgs e)
        {
            string user = (UserNameBox.Text ?? string.Empty).Trim();
            string password = PasswordInput.Password ?? string.Empty;
            if (string.IsNullOrEmpty(user) || string.IsNullOrEmpty(password))
            {
                MessageBox.Show("账号和密码都要填写。", AppPaths.DisplayName, MessageBoxButton.OK, MessageBoxImage.Warning);
                return;
            }
            try
            {
                AppPaths.EnsureDataDir();
                CredentialStore.Save(AppPaths.CredentialFile, user, password);
                PasswordInput.Clear();
                _log.Info("已保存账号 " + Mask(user) + "（DPAPI 加密，仅当前 Windows 用户可解密）。");
                _engine.Reload();
                UpdateUi();
                MessageBox.Show("账号密码已保存，程序会立刻开始守护网络。", AppPaths.DisplayName, MessageBoxButton.OK, MessageBoxImage.Information);
            }
            catch (Exception ex)
            {
                MessageBox.Show("保存失败：" + ex.Message, AppPaths.DisplayName, MessageBoxButton.OK, MessageBoxImage.Error);
            }
        }

        // ------------------------------------------------- 高级设置：改完自动保存（没有保存按钮）

        /// <summary>各输入框的合法范围：键名对应 TextBox 的 Tag。</summary>
        private static readonly Dictionary<string, int[]> AdvancedRanges = new Dictionary<string, int[]>
        {
            { "OnlineProbeSeconds", new[] { 5, 3600 } },
            { "OfflineProbeSeconds", new[] { 1, 600 } },
            { "LoginHourlyLimit", new[] { 0, 240 } },
            { "LoginMinIntervalSeconds", new[] { 0, 3600 } },
            { "UpstreamProbeSeconds", new[] { 30, 3600 } },
            { "ProbeTimeoutMs", new[] { 200, 10000 } },
            { "HttpProbeTimeoutMs", new[] { 500, 10000 } },
            { "SessionCheckSeconds", new[] { 0, 3600 } },
            { "StuckReloginSeconds", new[] { 0, 3600 } }
        };

        private void AdvancedBox_LostFocus(object sender, RoutedEventArgs e)
        {
            CommitAdvanced(sender as TextBox);
        }

        private void AdvancedBox_KeyDown(object sender, KeyEventArgs e)
        {
            if (e.Key != Key.Enter) { return; }
            e.Handled = true;
            CommitAdvanced(sender as TextBox);
        }

        private void PortalHost_KeyDown(object sender, KeyEventArgs e)
        {
            if (e.Key != Key.Enter) { return; }
            e.Handled = true;
            CommitPortalHost();
        }

        private void PortalHost_LostFocus(object sender, RoutedEventArgs e)
        {
            CommitPortalHost();
        }

        /// <summary>校验单个输入框并立即写盘、立即生效；非法值自动回退到当前值。</summary>
        private void CommitAdvanced(TextBox box)
        {
            if (box == null || box.Tag == null) { return; }
            string field = Convert.ToString(box.Tag, CultureInfo.InvariantCulture);
            int[] range;
            if (!AdvancedRanges.TryGetValue(field, out range)) { return; }

            AppConfig config = _engine.Config;
            int current = ReadField(config, field);
            int parsed;
            if (!int.TryParse((box.Text ?? string.Empty).Trim(), NumberStyles.Integer, CultureInfo.InvariantCulture, out parsed))
            {
                box.Text = current.ToString(CultureInfo.InvariantCulture);
                AdvancedHint.Text = "「" + FieldLabel(field) + "」需要 " + range[0] + "–" + range[1]
                    + " 之间的整数，已还原为 " + current + "。";
                return;
            }

            int value = Math.Max(range[0], Math.Min(range[1], parsed));
            box.Text = value.ToString(CultureInfo.InvariantCulture);
            if (value == current)
            {
                AdvancedHint.Text = "「" + FieldLabel(field) + "」未变化（允许 " + range[0] + "–" + range[1] + "）。";
                return;
            }

            WriteField(config, field, value);
            try
            {
                config.Save(AppPaths.ConfigFile);
                _engine.Reload();
                LoadSettingsIntoUi();
                AdvancedHint.Text = "已保存并立即生效：" + FieldLabel(field) + " = " + value
                    + "（允许 " + range[0] + "–" + range[1] + "）。";
                _log.Info("设置已更新：" + FieldLabel(field) + " = " + value + "。");
                RefreshLog();
            }
            catch (Exception ex)
            {
                AdvancedHint.Text = "保存失败：" + ex.Message;
            }
        }

        private void CommitPortalHost()
        {
            AppConfig config = _engine.Config;
            string host = (PortalHostBox.Text ?? string.Empty).Trim();
            string scheme = config.PortalScheme;
            // 允许直接把协议写进地址（https://10.66.209.2）——存盘时拆成 PortalScheme + PortalHost
            if (host.StartsWith("https://", StringComparison.OrdinalIgnoreCase)) { scheme = "https"; host = host.Substring(8); }
            else if (host.StartsWith("http://", StringComparison.OrdinalIgnoreCase)) { scheme = "http"; host = host.Substring(7); }
            if (string.IsNullOrEmpty(host))
            {
                PortalHostBox.Text = config.PortalBase;
                AdvancedHint.Text = "Portal 地址不能为空，已还原为 " + config.PortalBase + "。";
                return;
            }
            if (string.Equals(host, config.PortalHost, StringComparison.OrdinalIgnoreCase)
                && string.Equals(scheme, config.PortalScheme, StringComparison.OrdinalIgnoreCase))
            {
                PortalHostBox.Text = config.PortalBase;
                return;
            }
            config.PortalHost = host;
            config.PortalScheme = scheme;
            try
            {
                config.Save(AppPaths.ConfigFile);
                _engine.Reload();
                LoadSettingsIntoUi();
                AdvancedHint.Text = "已保存并立即生效：Portal 地址 = " + config.PortalBase + "。";
                _log.Info("设置已更新：Portal 地址 = " + config.PortalBase + "。");
                RefreshLog();
            }
            catch (Exception ex)
            {
                AdvancedHint.Text = "保存失败：" + ex.Message;
            }
        }

        private static int ReadField(AppConfig config, string field)
        {
            switch (field)
            {
                case "OnlineProbeSeconds": return config.OnlineProbeSeconds;
                case "OfflineProbeSeconds": return config.OfflineProbeSeconds;
                case "LoginHourlyLimit": return config.LoginHourlyLimit;
                case "LoginMinIntervalSeconds": return config.LoginMinIntervalSeconds;
                case "UpstreamProbeSeconds": return config.UpstreamProbeSeconds;
                case "ProbeTimeoutMs": return config.ProbeTimeoutMs;
                case "HttpProbeTimeoutMs": return config.HttpProbeTimeoutMs;
                case "SessionCheckSeconds": return config.SessionCheckSeconds;
                case "StuckReloginSeconds": return config.StuckReloginSeconds;
                default: return 0;
            }
        }

        private static void WriteField(AppConfig config, string field, int value)
        {
            switch (field)
            {
                case "OnlineProbeSeconds": config.OnlineProbeSeconds = value; break;
                case "OfflineProbeSeconds": config.OfflineProbeSeconds = value; break;
                case "LoginHourlyLimit": config.LoginHourlyLimit = value; break;
                case "LoginMinIntervalSeconds": config.LoginMinIntervalSeconds = value; break;
                case "UpstreamProbeSeconds": config.UpstreamProbeSeconds = value; break;
                case "ProbeTimeoutMs": config.ProbeTimeoutMs = value; break;
                case "HttpProbeTimeoutMs": config.HttpProbeTimeoutMs = value; break;
                case "SessionCheckSeconds": config.SessionCheckSeconds = value; break;
                case "StuckReloginSeconds": config.StuckReloginSeconds = value; break;
            }
        }

        private static string FieldLabel(string field)
        {
            switch (field)
            {
                case "OnlineProbeSeconds": return "正常时探测间隔";
                case "OfflineProbeSeconds": return "异常时探测间隔";
                case "LoginHourlyLimit": return "每小时登录上限";
                case "LoginMinIntervalSeconds": return "登录最小间隔";
                case "UpstreamProbeSeconds": return "兜底巡检间隔";
                case "ProbeTimeoutMs": return "探测超时";
                case "HttpProbeTimeoutMs": return "HTTP 探测超时";
                case "SessionCheckSeconds": return "会话校验间隔";
                case "StuckReloginSeconds": return "残留会话自动重登";
                default: return field;
            }
        }

        private void AutoStart_Click(object sender, RoutedEventArgs e)
        {
            try
            {
                SelfInstaller.SetAutoStart(AutoStartCheck.IsChecked == true, _log);
                UpdateUi();
                RefreshLog();
            }
            catch (Exception ex)
            {
                // 用户点出来的动作出错必须让他看见：全局兜底只写 crash.log，界面会显得「点了没反应」。
                _log.Error("设置开机自启失败：" + ex.Message);
                MessageBox.Show("设置开机自启失败：" + ex.Message, AppPaths.DisplayName, MessageBoxButton.OK, MessageBoxImage.Error);
            }
        }

        private void Install_Click(object sender, RoutedEventArgs e)
        {
            try
            {
                if (SelfInstaller.IsInstalled)
                {
                    MessageBoxResult answer = MessageBox.Show(
                        "卸载会关闭开机自启、删除快捷方式，并在程序退出后删除程序文件。\n数据（账号、日志）默认保留。\n\n确定要卸载吗？",
                        AppPaths.DisplayName, MessageBoxButton.YesNo, MessageBoxImage.Question);
                    if (answer != MessageBoxResult.Yes) { return; }

                    UninstallResult result = SelfInstaller.Uninstall(_log, false, true);
                    if (result.WasInstalled)
                    {
                        MessageBox.Show(
                            "已卸载：开机自启与快捷方式已移除，程序即将退出。\n\n"
                            + "程序文件会在退出后立即删除；如果那时文件仍被占用（例如又开了别的副本），"
                            + "系统会在下次重启后自动删除。\n\n数据目录仍保留在：\n" + AppPaths.DataDir,
                            AppPaths.DisplayName, MessageBoxButton.OK, MessageBoxImage.Information);
                        // 必须真的退出：正被占用的 exe 删不掉，留着只会让「已卸载」变成假话。
                        ExitApplication();
                        return;
                    }
                    MessageBox.Show(
                        "已清理：开机自启与快捷方式已移除；本机没有已安装的程序文件（便携模式）。\n\n数据目录仍保留在：\n" + AppPaths.DataDir,
                        AppPaths.DisplayName, MessageBoxButton.OK, MessageBoxImage.Information);
                }
                else
                {
                    SelfInstaller.Install(_log, false);
                    MessageBox.Show("已安装到：\n" + AppPaths.InstalledExe + "\n\n并已开启开机自启。", AppPaths.DisplayName, MessageBoxButton.OK, MessageBoxImage.Information);
                }
                UpdateUi();
                RefreshLog();
            }
            catch (Exception ex)
            {
                _log.Error("安装/卸载失败：" + ex.Message);
                MessageBox.Show("操作失败：" + ex.Message, AppPaths.DisplayName, MessageBoxButton.OK, MessageBoxImage.Error);
            }
        }

        private void OpenData_Click(object sender, RoutedEventArgs e)
        {
            try
            {
                AppPaths.EnsureDataDir();
                Process.Start("explorer.exe", "\"" + AppPaths.DataDir + "\"");
            }
            catch (Exception ex)
            {
                MessageBox.Show("打开目录失败：" + ex.Message, AppPaths.DisplayName, MessageBoxButton.OK, MessageBoxImage.Warning);
            }
        }

        private void Cleanup_Click(object sender, RoutedEventArgs e)
        {
            try
            {
                LegacyReport report = LegacyCleanup.Detect();
                if (!report.Any)
                {
                    MessageBox.Show("没有检测到旧版残留。", AppPaths.DisplayName, MessageBoxButton.OK, MessageBoxImage.Information);
                    return;
                }
                MessageBoxResult answer = MessageBox.Show(
                    "检测到旧版（1.x PowerShell 版）残留：\n" + report.Describe() + "\n\n"
                    + "清理会删除旧的计划任务与脚本目录（需要一次管理员确认，会弹出 UAC 窗口）。\n"
                    + "旧数据目录（含旧凭据与日志）会保留。\n\n确定要清理吗？",
                    AppPaths.DisplayName, MessageBoxButton.YesNo, MessageBoxImage.Question);
                if (answer != MessageBoxResult.Yes) { return; }

                bool ok = LegacyCleanup.RunElevated(false, _log);
                RefreshLegacyHint();
                RefreshLog();
                MessageBox.Show(ok ? "旧版残留已清理。" : "清理未完成，可稍后重试或用管理员身份运行本程序再试一次。",
                    AppPaths.DisplayName, MessageBoxButton.OK, ok ? MessageBoxImage.Information : MessageBoxImage.Warning);
            }
            catch (Exception ex)
            {
                _log.Error("清理旧版残留失败：" + ex.Message);
                MessageBox.Show("清理失败：" + ex.Message, AppPaths.DisplayName, MessageBoxButton.OK, MessageBoxImage.Error);
            }
        }

        /// <summary>卸载后的退出：不再问一次（卸载本身已经确认过），但要按「用户主动退出」处理。</summary>
        private static void ExitApplication()
        {
            App app = Application.Current as App;
            if (app != null) { app.ExitAfterUninstall(); }
            else { Application.Current.Shutdown(0); }
        }

        private void Relogin_Click(object sender, RoutedEventArgs e)
        {
            _engine.Relogin();
            _log.Info("已请求立即重连：先注销当前会话，再重新登录。");
            RefreshLog();
            // 立刻禁用按钮，避免连点；10 秒后由 UpdateUi 恢复
            ReloginButton.IsEnabled = false;
            ReloginButton.Content = "正在重连…";
            var timer = new DispatcherTimer { Interval = TimeSpan.FromSeconds(10) };
            timer.Tick += delegate
            {
                timer.Stop();
                ReloginButton.Content = "立即重连";
                UpdateUi();
            };
            timer.Start();
        }

        private void ClearLog_Click(object sender, RoutedEventArgs e)
        {
            MessageBoxResult answer = MessageBox.Show(
                "确定要清空运行日志吗？\n\n会删除 login.log 与 login.log.old，删除后无法恢复。",
                AppPaths.DisplayName, MessageBoxButton.YesNo, MessageBoxImage.Question);
            if (answer != MessageBoxResult.Yes) { return; }
            _log.Clear();
            _logSignature = string.Empty;
            RefreshLog();
        }

        private void Pause_Click(object sender, RoutedEventArgs e)
        {
            _engine.Pause(TimeSpan.FromMinutes(30));
            UpdateUi();
            RefreshLog();
        }

        private void Resume_Click(object sender, RoutedEventArgs e)
        {
            _engine.Resume();
            UpdateUi();
            RefreshLog();
        }

        private void Refresh_Click(object sender, RoutedEventArgs e)
        {
            NetworkProbe.InvalidateNetworkInfo();
            _engine.CheckNow();
            UpdateUi();
            RefreshLog();
            RefreshLegacyHint();
        }

        private void WarningOnly_Click(object sender, RoutedEventArgs e)
        {
            _logSignature = string.Empty;
            RefreshLog();
        }

        private void CopyDiagnose_Click(object sender, RoutedEventArgs e)
        {
            try
            {
                NetworkProbe.InvalidateNetworkInfo();
                _engine.CheckNow();
                string text = Diagnostics.Build(_engine, _log, true);
                Clipboard.SetText(text);
                MessageBox.Show("诊断信息已复制到剪贴板，可以直接粘贴发给别人。", AppPaths.DisplayName, MessageBoxButton.OK, MessageBoxImage.Information);
            }
            catch (Exception ex)
            {
                MessageBox.Show("复制失败：" + ex.Message, AppPaths.DisplayName, MessageBoxButton.OK, MessageBoxImage.Warning);
            }
        }

        private void Close_Click(object sender, RoutedEventArgs e)
        {
            Hide();
            if (_tray != null) { _tray.ShowBalloon(AppPaths.DisplayName, "窗口已收起，程序仍在后台运行。"); }
        }

        // ------------------------------------------------------------- 工具

        private static Brush BrushFor(string key)
        {
            switch (key)
            {
                case "green": return new SolidColorBrush(Color.FromRgb(0x16, 0xA3, 0x4A));
                case "amber": return new SolidColorBrush(Color.FromRgb(0xD9, 0x77, 0x06));
                case "orange": return new SolidColorBrush(Color.FromRgb(0xEA, 0x58, 0x0C));
                case "red": return new SolidColorBrush(Color.FromRgb(0xDC, 0x26, 0x26));
                default: return new SolidColorBrush(Color.FromRgb(0x6B, 0x72, 0x80));
            }
        }

        private static string Fallback(string text)
        {
            return string.IsNullOrEmpty(text) ? "—" : text;
        }

        private static string Describe(DateTime? time)
        {
            if (!time.HasValue) { return "—"; }
            return AppPaths.FormatTime(time.Value) + "（" + Relative(time) + "）";
        }

        private static string Relative(DateTime? time)
        {
            if (!time.HasValue) { return "—"; }
            TimeSpan span = DateTime.Now - time.Value;
            if (span.TotalSeconds < 0) { span = TimeSpan.Zero; }
            if (span.TotalSeconds < 60) { return (int)span.TotalSeconds + " 秒前"; }
            if (span.TotalMinutes < 60) { return (int)span.TotalMinutes + " 分钟前"; }
            return (int)span.TotalHours + " 小时前";
        }

        /// <summary>按当前状态与配置推算下一次本地探测的时间。</summary>
        private string NextProbeText(EngineSnapshot snapshot)
        {
            if (snapshot.Paused) { return "已暂停"; }
            if (snapshot.StatusKey == "login-attempt") { return "进行中"; }
            if (!snapshot.LastProbe.HasValue) { return "等待首次探测"; }
            AppConfig config = _engine.Config;
            int interval = snapshot.Online ? config.OnlineProbeSeconds : config.OfflineProbeSeconds;
            double remain = (snapshot.LastProbe.Value.AddSeconds(interval) - DateTime.Now).TotalSeconds;
            if (remain <= 0) { return "即将"; }
            if (remain >= 60) { return "约 " + (int)Math.Ceiling(remain / 60.0) + " 分钟后"; }
            return (int)Math.Ceiling(remain) + " 秒后";
        }

        private static string ResultText(string result)
        {
            switch (result)
            {
                case "online": return "网络正常";
                case "login-ok": return "自动登录成功";
                case "login-failed": return "登录失败";
                case "login-wait": return "等待下次登录";
                case "login-throttled": return "已触发频率上限";
                case "login-retry": return "已忽略 Portal 提示，继续重试";
                case "login-unconfirmed": return "登录已提交，等待确认";
                case "config-invalid": return "配置文件损坏，已停止登录";
                case "probe-config": return "探测目标配置无效，已停止登录";
                case "stuck-relogin": return "残留会话：正在强制重新登录";
                case "verifying": return "正在核对网络状态";
                case "tcp-only": return "只有 TCP 握手通过";
                case "session-check": return "正在核对 Portal 会话";
                case "offline-detected": return "检测到已离线";
                case "login-attempt": return "正在登录";
                case "paused": return "已暂停";
                case "unreachable": return "无法连接校园网";
                case "upstream": return "上游异常";
                case "no-credential": return "未保存账号";
                case "starting": return "启动中";
                default: return result;
            }
        }

        /// <summary>「会话校验」一行：最近一次只读核对的时间与结果。</summary>
        private static string SessionText(EngineSnapshot snapshot)
        {
            DateTime? time = AppPaths.ParseTime(snapshot.LastSessionCheck);
            if (!time.HasValue) { return "尚未核对"; }
            string kind = SessionKindText(snapshot.LastSessionCheckKind);
            return Relative(time) + " · " + SessionResultText(snapshot.LastSessionResult)
                + (string.IsNullOrEmpty(kind) ? string.Empty : " · " + kind);
        }

        /// <summary>会话核对的来源：定时巡检 / 疑似掉线核对。</summary>
        private static string SessionKindText(string kind)
        {
            switch (kind)
            {
                case "periodic": return "定时巡检";
                case "suspect": return "疑似掉线核对";
                default: return string.Empty;
            }
        }

        private static string SessionResultText(string key)
        {
            switch (key)
            {
                case "online": return "Portal 显示在线";
                case "offline": return "Portal 显示已离线";
                case "unreachable": return "Portal 不可达";
                default: return string.IsNullOrEmpty(key) ? "—" : key;
            }
        }

        /// <summary>「强制重登」一行：本机不通但 Portal 说在线时，主动注销重登的最后一次时间。</summary>
        private static string ForcedReloginText(EngineSnapshot snapshot)
        {
            DateTime? time = AppPaths.ParseTime(snapshot.LastForcedRelogin);
            return time.HasValue ? Relative(time) : "尚未发生";
        }

        /// <summary>「探测方式」一行：是否配了内容校验目标（能识破网关代答）。</summary>
        private string ProbeModeText()
        {
            bool content = false;
            foreach (string text in _engine.Config.ProbeTargets)
            {
                ProbeTarget target = ProbeTarget.Parse(text);
                if (target != null && target.ContentVerified) { content = true; break; }
            }
            return content ? "内容校验 + TCP 兜底" : "仅 TCP 握手（可能被代答）";
        }

        private static string Mask(string userName)
        {
            if (string.IsNullOrEmpty(userName)) { return "—"; }
            if (userName.Length <= 3) { return userName.Substring(0, 1) + "**"; }
            return userName.Substring(0, 3) + new string('*', Math.Max(1, userName.Length - 3));
        }
    }
}
