using System;
using System.Collections.Generic;
using System.Globalization;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using CampusNet.Core;

namespace CampusNet
{
    /// <summary>
    /// 高级设置独立窗口（2.1.0 起从主窗口的 Expander 搬出来）：
    /// 10 个输入项排成两列 × 5 行，整窗高度固定、**不需要滚动条**，
    /// 也就不会再出现「展开后最后一行被裁在可视区外」的老问题。
    /// 行为与旧版一致：失焦或回车即校验、按范围钳制、立即写盘并重载（没有保存按钮）。
    /// </summary>
    public partial class AdvancedWindow : Window
    {
        private readonly LoginEngine _engine;
        private readonly Logger _log;
        /// <summary>保存成功后回调主窗口刷新界面与日志。</summary>
        private readonly Action _onSaved;

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

        public AdvancedWindow(LoginEngine engine, Logger log, Action onSaved)
        {
            _engine = engine;
            _log = log;
            _onSaved = onSaved;
            InitializeComponent();
            Load();
        }

        /// <summary>把当前配置灌进 10 个输入框。</summary>
        public void Load()
        {
            AppConfig config = _engine.Config;
            OnlineProbeBox.Text = Number(config.OnlineProbeSeconds);
            OfflineProbeBox.Text = Number(config.OfflineProbeSeconds);
            HourlyLimitBox.Text = Number(config.LoginHourlyLimit);
            PortalHostBox.Text = config.PortalBase;   // 连协议一起显示，写成 https://… 也认
            MinIntervalBox.Text = Number(config.LoginMinIntervalSeconds);
            UpstreamProbeBox.Text = Number(config.UpstreamProbeSeconds);
            ProbeTimeoutBox.Text = Number(config.ProbeTimeoutMs);
            HttpProbeTimeoutBox.Text = Number(config.HttpProbeTimeoutMs);
            SessionCheckBox.Text = Number(config.SessionCheckSeconds);
            StuckReloginBox.Text = Number(config.StuckReloginSeconds);
        }

        private static string Number(int value)
        {
            return value.ToString(CultureInfo.InvariantCulture);
        }

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

        private void Close_Click(object sender, RoutedEventArgs e)
        {
            Close();
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
                box.Text = Number(current);
                AdvancedHint.Text = "「" + FieldLabel(field) + "」需要 " + range[0] + "–" + range[1]
                    + " 之间的整数，已还原为 " + current + "。";
                return;
            }

            int value = Math.Max(range[0], Math.Min(range[1], parsed));
            box.Text = Number(value);
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
                Load();
                AdvancedHint.Text = "已保存并立即生效：" + FieldLabel(field) + " = " + value
                    + "（允许 " + range[0] + "–" + range[1] + "）。";
                _log.Info("设置已更新：" + FieldLabel(field) + " = " + value + "。");
                if (_onSaved != null) { _onSaved(); }
            }
            catch (Exception ex)
            {
                AdvancedHint.Text = "保存失败：" + ex.Message;
                MessageBox.Show("保存失败：" + ex.Message, AppPaths.DisplayName, MessageBoxButton.OK, MessageBoxImage.Error);
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
                Load();
                AdvancedHint.Text = "已保存并立即生效：Portal 地址 = " + config.PortalBase + "。";
                _log.Info("设置已更新：Portal 地址 = " + config.PortalBase + "。");
                if (_onSaved != null) { _onSaved(); }
            }
            catch (Exception ex)
            {
                AdvancedHint.Text = "保存失败：" + ex.Message;
                MessageBox.Show("保存失败：" + ex.Message, AppPaths.DisplayName, MessageBoxButton.OK, MessageBoxImage.Error);
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
                case "SessionCheckSeconds": return "会话核对间隔";
                case "StuckReloginSeconds": return "残留会话自动重登";
                default: return field;
            }
        }
    }
}
