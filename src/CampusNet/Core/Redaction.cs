using System;
using System.Text.RegularExpressions;

namespace CampusNet.Core
{
    /// <summary>
    /// 落盘文本的脱敏：密码一律替换成 ***，账号统一打码成 251******（与「诊断信息」一致）。
    ///
    /// 为什么需要它：登录失败时会把 Portal 的响应原文写进 login.log / state.json / 剪贴板。
    /// 多数学校只会回一句错误提示，但万一某校 Portal 把提交的表单回显出来，密码就会跟着落盘。
    /// 这里做成唯一入口，日志与状态文件两个写入汇点都走它，避免哪天真漏了一处。
    /// </summary>
    public static class Redact
    {
        private static readonly object Gate = new object();
        private static string _user = string.Empty;
        private static string _maskedUser = string.Empty;
        private static string _password = string.Empty;
        private static string _passwordEscaped = string.Empty;

        /// <summary>登记当前账号密码（凭据加载 / 保存后调用）。</summary>
        public static void SetSecrets(string userName, string password)
        {
            lock (Gate)
            {
                _user = userName ?? string.Empty;
                _maskedUser = MaskUser(_user);
                _password = password ?? string.Empty;
                _passwordEscaped = _password.Length == 0 ? string.Empty : Uri.EscapeDataString(_password);
            }
        }

        /// <summary>账号打码：前 3 位保留，其余换成 *。与界面 / 诊断信息的掩码格式保持一致。</summary>
        public static string MaskUser(string userName)
        {
            if (string.IsNullOrEmpty(userName)) { return string.Empty; }
            if (userName.Length <= 3) { return userName.Substring(0, 1) + "**"; }
            return userName.Substring(0, 3) + new string('*', Math.Max(1, userName.Length - 3));
        }

        /// <summary>把一段可能来自 Portal / 命令行的文本脱敏（空值原样返回）。</summary>
        public static string Text(string text)
        {
            if (string.IsNullOrEmpty(text)) { return text; }

            string user, masked, password, escaped;
            lock (Gate)
            {
                user = _user;
                masked = _maskedUser;
                password = _password;
                escaped = _passwordEscaped;
            }

            string result = text;
            if (password.Length > 0)
            {
                result = result.Replace(password, "***");
                // URL 编码后的形态（表单 / 查询串里常见）
                if (escaped.Length > 0 && !string.Equals(escaped, password, StringComparison.Ordinal))
                {
                    result = result.Replace(escaped, "***");
                }
            }
            // upass=…（含 Portal 回显的表单、带编码的形态）：值一律打掉
            result = Regex.Replace(result, "(?i)(upass=)[^&\\s\"'<>]*", "$1***");
            if (user.Length > 0 && !string.Equals(user, masked, StringComparison.Ordinal))
            {
                result = result.Replace(user, masked);
            }
            return result;
        }
    }
}
