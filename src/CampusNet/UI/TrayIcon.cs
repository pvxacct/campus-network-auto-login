using System;
using System.Collections.Generic;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Runtime.InteropServices;
using System.Text.RegularExpressions;
using System.Windows.Forms;
using CampusNet.Core;

namespace CampusNet.UI
{
    /// <summary>托盘图标：颜色跟随运行状态，右键菜单提供暂停 / 恢复 / 重连 / 退出。</summary>
    public sealed class TrayIcon : IDisposable
    {
        private const int IconSize = 32;

        /// <summary>Windows 托盘提示文本的硬上限：NotifyIcon.Text 超过 63 个字符会抛异常并可能杀掉进程。</summary>
        public const int MaxTooltipChars = 63;

        private readonly NotifyIcon _icon;
        private readonly Dictionary<string, Icon> _iconCache = new Dictionary<string, Icon>();
        private readonly bool _balloonEnabled;
        private string _currentKey = string.Empty;
        private int _safetyVariant;

        /// <summary>最近一次实际写进托盘的提示文本（自检与诊断用）。</summary>
        public string LastTooltip { get; private set; }

        public event Action OpenRequested;
        public event Action ReloginRequested;
        public event Action PauseRequested;
        public event Action ResumeRequested;
        public event Action ExitRequested;

        [DllImport("user32.dll", SetLastError = true)]
        private static extern bool DestroyIcon(IntPtr handle);

        public TrayIcon(bool balloonEnabled)
        {
            _balloonEnabled = balloonEnabled;
            _icon = new NotifyIcon();
            _icon.Visible = true;
            _icon.Text = FitTooltip(string.Empty);
            _icon.Icon = GetIcon("gray");
            _icon.DoubleClick += delegate { Raise(OpenRequested); };
            _icon.MouseClick += delegate(object sender, MouseEventArgs e)
            {
                if (e.Button == MouseButtons.Left) { Raise(OpenRequested); }
            };
            _icon.ContextMenuStrip = BuildMenu();
        }

        public void Update(string statusKey, string statusText, bool paused)
        {
            // 托盘只是显示层：这里的任何异常都不允许影响自动登录主流程，
            // 更不能因为提示文字过长把整个后台进程打崩（pre.5 的真实故障）。
            try
            {
                string colorKey = ColorFor(statusKey, paused);
                if (_currentKey != colorKey)
                {
                    _currentKey = colorKey;
                    _icon.Icon = GetIcon(colorKey);
                }
                LastTooltip = FitTooltip(statusText, _safetyVariant);
                _safetyVariant = (_safetyVariant + 1) % 2;
                _icon.Text = LastTooltip;
            }
            catch { }
        }

        /// <summary>把状态文案压成 NotifyIcon 能接受的单行短文本（≤63 字符）。</summary>
        public static string FitTooltip(string statusText)
        {
            return FitTooltip(statusText, 0);
        }

        private static string FitTooltip(string statusText, int variant)
        {
            string head = AppPaths.DisplayName + " " + AppPaths.Version;
            string body = (statusText ?? string.Empty).Replace('\r', ' ').Replace('\n', ' ').Trim();
            string text = string.IsNullOrEmpty(body) ? head : head + " · " + body;
            text = Regex.Replace(text, "\\s+", " ").Trim();
            if (text.Length > MaxTooltipChars)
            {
                // 省略号在极少数系统上也可能不被接受，第二轮退化成半角句点再试一次。
                text = text.Substring(0, MaxTooltipChars - 1).TrimEnd() + (variant == 0 ? "…" : ".");
            }
            return text;
        }

        public void ShowBalloon(string title, string text)
        {
            if (!_balloonEnabled) { return; }
            try
            {
                string safeTitle = title ?? string.Empty;
                if (safeTitle.Length > MaxTooltipChars) { safeTitle = safeTitle.Substring(0, MaxTooltipChars - 1) + "…"; }
                _icon.BalloonTipTitle = safeTitle;
                _icon.BalloonTipText = text;
                _icon.BalloonTipIcon = ToolTipIcon.Info;
                _icon.ShowBalloonTip(4000);
            }
            catch { }
        }

        public void Dispose()
        {
            try { _icon.Visible = false; _icon.Dispose(); } catch { }
            foreach (var pair in _iconCache) { try { pair.Value.Dispose(); } catch { } }
            _iconCache.Clear();
        }

        private ContextMenuStrip BuildMenu()
        {
            var menu = new ContextMenuStrip();
            menu.Items.Add(MenuItem("打开面板", delegate { Raise(OpenRequested); }));
            menu.Items.Add(MenuItem("立即重连", delegate { Raise(ReloginRequested); }));
            menu.Items.Add(new ToolStripSeparator());
            menu.Items.Add(MenuItem("暂停 30 分钟", delegate { Raise(PauseRequested); }));
            menu.Items.Add(MenuItem("恢复自动登录", delegate { Raise(ResumeRequested); }));
            menu.Items.Add(new ToolStripSeparator());
            menu.Items.Add(MenuItem("退出", delegate { Raise(ExitRequested); }));
            return menu;
        }

        private static ToolStripMenuItem MenuItem(string text, EventHandler handler)
        {
            var item = new ToolStripMenuItem(text);
            item.Click += handler;
            return item;
        }

        private static void Raise(Action action)
        {
            if (action != null) { action(); }
        }

        private static string ColorFor(string statusKey, bool paused)
        {
            if (paused) { return "gray"; }
            switch (statusKey)
            {
                case "online":
                case "login-ok": return "green";
                case "no-credential":
                case "bad-credential":
                case "login-failed":
                case "config-invalid":
                case "probe-config":
                case "unreachable": return "red";
                default: return "amber";
            }
        }

        private Icon GetIcon(string key)
        {
            Icon cached;
            if (_iconCache.TryGetValue(key, out cached)) { return cached; }
            Icon created = BuildIcon(key);
            _iconCache[key] = created;
            return created;
        }

        private static Icon BuildIcon(string key)
        {
            Color color;
            switch (key)
            {
                case "green": color = Color.FromArgb(22, 163, 74); break;
                case "amber": color = Color.FromArgb(217, 119, 6); break;
                case "orange": color = Color.FromArgb(234, 88, 12); break;
                case "red": color = Color.FromArgb(220, 38, 38); break;
                default: color = Color.FromArgb(107, 114, 128); break;
            }

            var bitmap = new Bitmap(IconSize, IconSize);
            using (var graphics = Graphics.FromImage(bitmap))
            {
                graphics.SmoothingMode = SmoothingMode.AntiAlias;
                graphics.Clear(Color.Transparent);
                using (var brush = new SolidBrush(color))
                {
                    graphics.FillEllipse(brush, 3, 3, IconSize - 7, IconSize - 7);
                }
                using (var pen = new Pen(Color.White, 3f))
                {
                    graphics.DrawEllipse(pen, 3, 3, IconSize - 7, IconSize - 7);
                }
                using (var font = new Font("Segoe UI", 11f, FontStyle.Bold, GraphicsUnit.Pixel))
                using (var brush = new SolidBrush(Color.White))
                {
                    var format = new StringFormat
                    {
                        Alignment = StringAlignment.Center,
                        LineAlignment = StringAlignment.Center
                    };
                    graphics.DrawString("W", font, brush, new RectangleF(3, 3, IconSize - 7, IconSize - 7), format);
                }
            }

            IntPtr handle = bitmap.GetHicon();
            try
            {
                using (Icon temp = Icon.FromHandle(handle))
                {
                    return (Icon)temp.Clone();
                }
            }
            finally
            {
                DestroyIcon(handle);
                bitmap.Dispose();
            }
        }
    }
}
