using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Globalization;
using System.IO;
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
        /// <summary>日志视图已经渲染到的行号；-1 = 还没渲染过（下次整块重绘）。</summary>
        private long _logCursor = -1;
        /// <summary>日志视图当前承载的那一段（整块重绘时才换）。</summary>
        private Paragraph _logParagraph;
        private const int MaxLogLines = 400;
        /// <summary>外部改动的配置文件时间戳：用于「别的程序改了 config.json 也自动生效」。</summary>
        private DateTime _configStamp = DateTime.MinValue;
        private DateTime _credentialStamp = DateTime.MinValue;

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
                WatchExternalChanges();
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
            // 「清除显示」只作用于当次窗口显示；重新打开时按约定回到「最近 400 行」。
            _logCursor = -1;
            RefreshLog();
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
            StatNextProbe.Text = NextProbeText(snapshot);
            StatSession.Text = SessionText(snapshot);
            StatError.Text = string.IsNullOrEmpty(snapshot.LastError) ? "无" : snapshot.LastError;
            StatDay.Text = snapshot.DayLoginSuccess + " 次 / 提交 " + snapshot.DayLoginAttempts + " 次";
            StatDay.ToolTip = string.IsNullOrEmpty(snapshot.DayKey)
                ? null
                : "统计日期 " + snapshot.DayKey + "（跨零点自动重新计数）";
            StatRecovery.Text = snapshot.LastRecoverySeconds < 0
                ? "—"
                : snapshot.LastRecoverySeconds + " 秒 / 中位 " + snapshot.RecoveryMedianSeconds + " 秒";
            StatRecovery.ToolTip = snapshot.LastRecoverySeconds < 0
                ? "本次运行内还没有「提交登录 → 确认恢复」的样本"
                : "最近一次恢复耗时；中位取自本次运行最近 " + snapshot.RecoverySampleCount + " 次样本";
            StatError.ToolTip = string.IsNullOrEmpty(snapshot.LastError) ? null : snapshot.LastError;
            ProbeText.ToolTip = string.IsNullOrEmpty(snapshot.ProbeSummary) ? null : snapshot.ProbeSummary;

            PauseButton.IsEnabled = !snapshot.Paused;
            ResumeButton.IsEnabled = snapshot.Paused;
            ReloginButton.IsEnabled = !snapshot.Paused;

            // 账号 / 密码卡片：一眼看懂「现在存的是什么、还缺什么」。
            if (snapshot.HasCredential)
            {
                CredentialHint.Text = "当前账号：" + Mask(snapshot.UserName)
                    + "（密码已加密保存）· 程序会自动登录。";
            }
            else if (!string.IsNullOrEmpty(snapshot.UserName))
            {
                CredentialHint.Text = "已保存账号 " + Mask(snapshot.UserName)
                    + "，但缺少密码：补填密码再保存一次，程序才会自动登录。";
            }
            else
            {
                CredentialHint.Text = "还没保存账号密码：填好账号与密码，点「保存账号密码」后才会自动登录。";
            }
            UpdatePlaceholders(snapshot);

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
            _logDirty = false;
            if (_logCursor < 0) { RenderLogTail(warningsOnly); return; }

            long last;
            bool dropped;
            List<string> fresh = _log.Since(_logCursor, MaxLogLines, warningsOnly, out last, out dropped);
            if (dropped) { RenderLogTail(warningsOnly); return; }
            if (fresh.Count == 0) { return; }
            foreach (string line in fresh) { AppendLogLine(line); }
            _logCursor = last;
            TrimLogView();
            // 只有勾着「跟随最新」才自动滚到底：用户往上翻历史时不再被强行拉回来。
            if (FollowTailCheck.IsChecked == true) { LogView.ScrollToEnd(); }
        }

        /// <summary>整块重绘：显示内存里最近的一段日志（默认 400 行）。</summary>
        private void RenderLogTail(bool warningsOnly)
        {
            LogView.Document.Blocks.Clear();
            // 行高 18（原 16）：日志默认字号 11.5 时行距太挤，长日志看起来是一坨。
            _logParagraph = new Paragraph
            {
                Margin = new Thickness(0),
                LineHeight = 18,
                LineStackingStrategy = LineStackingStrategy.BlockLineHeight
            };
            LogView.Document.Blocks.Add(_logParagraph);
            _logCursor = _log.Sequence;

            List<string> lines = _log.Recent(MaxLogLines, warningsOnly);
            if (lines.Count == 0)
            {
                _logParagraph.Inlines.Add(new Run("暂无日志。") { Foreground = BrushFor("gray") });
                return;
            }
            foreach (string line in lines) { AppendLogLine(line); }
            LogView.ScrollToEnd();
        }

        private void AppendLogLine(string line)
        {
            if (_logParagraph == null) { return; }
            SolidColorBrush brush;
            if (line.IndexOf("[ERROR]", StringComparison.Ordinal) >= 0) { brush = new SolidColorBrush(Color.FromRgb(0xDC, 0x26, 0x26)); }
            else if (line.IndexOf("[WARN]", StringComparison.Ordinal) >= 0) { brush = new SolidColorBrush(Color.FromRgb(0xEA, 0x58, 0x0C)); }
            else { brush = new SolidColorBrush(Color.FromRgb(0x37, 0x41, 0x51)); }
            _logParagraph.Inlines.Add(new Run(line) { Foreground = brush });
            _logParagraph.Inlines.Add(new LineBreak());
        }

        /// <summary>视图最多留 MaxLogLines 行：一次删两条（Run + 换行）保持成对。</summary>
        private void TrimLogView()
        {
            if (_logParagraph == null) { return; }
            while (_logParagraph.Inlines.Count > MaxLogLines * 2 && _logParagraph.Inlines.FirstInline != null)
            {
                _logParagraph.Inlines.Remove(_logParagraph.Inlines.FirstInline);
            }
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
            EngineSnapshot snapshot = _engine.Snapshot();
            if (snapshot.HasCredential) { UserNameBox.Text = snapshot.UserName; }
            // 高级设置的 10 个输入框已经搬到 AdvancedWindow，这里只登记配置文件时间戳，
            // 免得刚打开窗口就把「外部改动」判成一次重载。
            NoteConfigSaved();
        }

        /// <summary>
        /// 账号 / 密码框的灰色占位提示（WPF 没有内置 placeholder）：
        /// 空着的时候显示「该填什么」，已经保存过密码时提示「留空表示不改」。
        /// </summary>
        private void UpdatePlaceholders(EngineSnapshot snapshot)
        {
            UserNamePlaceholder.Visibility = string.IsNullOrEmpty(UserNameBox.Text)
                ? Visibility.Visible
                : Visibility.Collapsed;
            PasswordPlaceholder.Text = snapshot.HasCredential ? "留空表示不改密码" : "填 Portal 密码";
            bool empty = string.IsNullOrEmpty(PasswordInput.Password) && !PasswordInput.IsKeyboardFocusWithin;
            PasswordPlaceholder.Visibility = empty ? Visibility.Visible : Visibility.Collapsed;
        }

        private void PasswordInput_PasswordChanged(object sender, RoutedEventArgs e)
        {
            UpdatePlaceholders(_engine.Snapshot());
        }

        private void PasswordInput_FocusChanged(object sender, KeyboardFocusChangedEventArgs e)
        {
            UpdatePlaceholders(_engine.Snapshot());
        }

        // ------------------------------------------------------------- 按钮

        private void SaveCredential_Click(object sender, RoutedEventArgs e)
        {
            string user = (UserNameBox.Text ?? string.Empty).Trim();
            string password = PasswordInput.Password ?? string.Empty;
            if (string.IsNullOrEmpty(user))
            {
                MessageBox.Show("请先填写账号（学号 / 账号）。", AppPaths.DisplayName, MessageBoxButton.OK, MessageBoxImage.Warning);
                return;
            }
            try
            {
                AppPaths.EnsureDataDir();
                // 密码留空 = 只改账号，沿用已经保存的密码（改学号时不用把密码再输一遍）。
                if (string.IsNullOrEmpty(password))
                {
                    Credential existing = CredentialStore.Load(AppPaths.CredentialFile);
                    if (existing == null || string.IsNullOrEmpty(existing.Password))
                    {
                        MessageBox.Show("还没有保存过密码，请把密码填上再保存一次。", AppPaths.DisplayName,
                            MessageBoxButton.OK, MessageBoxImage.Warning);
                        return;
                    }
                    password = existing.Password;
                }
                CredentialStore.Save(AppPaths.CredentialFile, user, password);
                PasswordInput.Clear();
                _log.Info("已保存账号 " + Mask(user) + "（DPAPI 加密，仅当前 Windows 用户可解密）。");
                _engine.Reload();
                NoteConfigSaved();
                UpdateUi();
                MessageBox.Show("账号密码已保存，程序会立刻开始守护网络。", AppPaths.DisplayName, MessageBoxButton.OK, MessageBoxImage.Information);
            }
            catch (Exception ex)
            {
                MessageBox.Show("保存失败：" + ex.Message, AppPaths.DisplayName, MessageBoxButton.OK, MessageBoxImage.Error);
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

        /// <summary>
        /// 「清除显示」：只清空这个窗口里的日志视图，**不删除、不截断本机的 login.log**。
        /// 想真正删掉历史日志文件，请用命令行 `--clear-log`。
        /// </summary>
        private void ClearLog_Click(object sender, RoutedEventArgs e)
        {
            LogView.Document.Blocks.Clear();
            // 游标直接推进到当前末尾：之后只显示这之后新产生的事件。
            _logCursor = _log.Sequence;
            _logParagraph = new Paragraph
            {
                Margin = new Thickness(0),
                LineHeight = 18,
                LineStackingStrategy = LineStackingStrategy.BlockLineHeight
            };
            _logParagraph.Inlines.Add(new Run("显示已清除（本机日志文件未删除，新事件会继续显示在这里）")
            {
                Foreground = BrushFor("gray")
            });
            _logParagraph.Inlines.Add(new LineBreak());
            LogView.Document.Blocks.Add(_logParagraph);
        }

        private void FollowTail_Click(object sender, RoutedEventArgs e)
        {
            // 勾上「跟随最新」时立刻跳到底部，符合直觉；取消则保持当前位置。
            if (FollowTailCheck.IsChecked == true) { LogView.ScrollToEnd(); }
        }

        private void Advanced_Click(object sender, RoutedEventArgs e)
        {
            try
            {
                var window = new AdvancedWindow(_engine, _log, OnAdvancedSaved);
                window.Owner = this;
                window.ShowDialog();
            }
            catch (Exception ex)
            {
                MessageBox.Show("打开高级设置失败：" + ex.Message, AppPaths.DisplayName, MessageBoxButton.OK, MessageBoxImage.Error);
            }
        }

        private void OnAdvancedSaved()
        {
            NoteConfigSaved();
            UpdateUi();
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
            // 过滤条件变了：整块重绘一次，避免视图里新旧两种口径混在一起。
            _logCursor = -1;
            RefreshLog();
        }

        // ------------------------------------------------- 外部改动自动生效

        /// <summary>
        /// 每 5 秒比一次 config.json / credentials.dat 的修改时间：别的程序（记事本、脚本、
        /// 命令行 --set-credentials）改过配置后，运行中的程序会自己重载，不用重启。
        /// </summary>
        private void WatchExternalChanges()
        {
            if (_tick % 5 != 0) { return; }
            DateTime config = Stamp(AppPaths.ConfigFile);
            DateTime credential = Stamp(AppPaths.CredentialFile);
            bool first = _configStamp == DateTime.MinValue && _credentialStamp == DateTime.MinValue;
            if (config == _configStamp && credential == _credentialStamp) { return; }
            _configStamp = config;
            _credentialStamp = credential;
            if (first) { return; }   // 第一次只是登记时间戳
            _engine.Reload();
            _log.Info("检测到配置文件变化，已自动重新加载。");
            UpdateUi();
            RefreshLog();
        }

        /// <summary>我们自己刚写过配置/凭据：立刻登记时间戳，免得下一轮把自己判成「外部改动」。</summary>
        private void NoteConfigSaved()
        {
            _configStamp = Stamp(AppPaths.ConfigFile);
            _credentialStamp = Stamp(AppPaths.CredentialFile);
        }

        private static DateTime Stamp(string path)
        {
            try { return File.Exists(path) ? File.GetLastWriteTimeUtc(path) : DateTime.MinValue; }
            catch { return DateTime.MinValue; }
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

        private static string Mask(string userName)
        {
            if (string.IsNullOrEmpty(userName)) { return "—"; }
            if (userName.Length <= 3) { return userName.Substring(0, 1) + "**"; }
            return userName.Substring(0, 3) + new string('*', Math.Max(1, userName.Length - 3));
        }
    }
}
