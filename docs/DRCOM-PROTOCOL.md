# Dr.COM ePortal 协议说明

本文记录 Dr.COM（哆点）ePortal 的 Web 认证流程，方便适配其他学校或排查问题。

## 1. 如何抓取登录请求

1. 断开校园网认证，让浏览器自动跳到认证页。
2. 按 `F12` 打开开发者工具，切到 **Network** 面板。
3. 勾选 **Preserve log**，过滤 `Fetch/XHR`。
4. 手动登录一次。
5. 找到登录请求，记录：
   - Request URL
   - Request Method
   - Form Data / Payload
   - 成功后的跳转地址

Dr.COM 常见请求特征：

- URL 含 `/drcom/login`、`/eportal/`、`ACSetting`；
- 账号字段为 `DDDDD`；
- 密码字段为 `upass`；
- 固定字段包含 `0MKKey`、`R1`、`R2`、`R3`、`R6`、`para`。

## 2. 接口一览

以下路径以 Portal 地址 `http://10.66.209.2` 为例。

### 2.1 查询在线状态

```http
GET http://10.66.209.2/drcom/chkstatus?callback=dr123&v=123&lang=zh&jsVersion=4.X
```

返回 JSONP：

```json
dr123({
  "result": 1,
  "uid": "2025000000",
  "v4ip": "10.0.0.100",
  "olmac": "aabbccddeeff",
  "stime": "2026-09-09 21:00:24"
})
```

- `result = 1`：已在线；
- `result = 0`：未在线；
- `uid`：当前在线账号；
- `olmac`：在线会话的 MAC。

### 2.2 登录

```http
POST http://10.66.209.2/drcom/login
Content-Type: application/x-www-form-urlencoded
Referer: http://10.66.209.2/
```

表单字段：

| 字段 | 值 | 说明 |
| --- | --- | --- |
| `DDDDD` | 学号/账号 | 账号 |
| `upass` | 密码 | 密码，是否加密取决于 `en_md5` |
| `0MKKey` | `123456` | 固定值 |
| `R1` | `0` | 固定值 |
| `R2` | `0` 或 `1` | `en_md5=1` 时为 `1` |
| `R3` | `0` | 运营商选择 |
| `R6` | `0` | 固定值 |
| `para` | `00` | 固定值 |
| `v6ip` | 空 | IPv6 地址 |
| `terminal_type` | `1` | 1=PC，2=手机 |
| `lang` | `zh` | 语言 |

### 2.3 注销

```http
GET http://10.66.209.2/drcom/logout?callback=dr123&v=123&lang=zh&jsVersion=4.X
```

返回：

```json
dr123({"result":1,"msg":14,"uid":"2025000000"})
```

- `result = 1`：注销成功；
- `msg = 14`：注销成功提示码。

> 注销后 Portal 要求至少等待 3 秒才能重新登录，否则返回 `error5 waitsec <3`。

### 2.4 错误码翻译

```http
GET http://10.66.209.2:801/eportal/portal/err_code/loadErrorPrompt?error_code=userid%20error2&callback=dr1&lang=zh
```

返回：

```json
dr1({
  "result": 1,
  "error_code": "userid error2",
  "error_prompt_zh": "密码错误",
  "error_prompt_en": "Password Error"
})
```

## 3. 密码加密方式

登录页会加载一份页面配置（`/eportal/portal/page/loadConfig`），其中 `en_md5` 决定密码是否加密：

- `en_md5 = 0`：明文提交；
- `en_md5 = 1`：按下面的方式处理：

```javascript
upass = MD5(PID + password + CALG) + CALG + PID
```

其中 `PID` 和 `CALG` 来自登录页 JS，常见值为：

```javascript
var PID = '1';
var CALG = '12345678';
```

如果学校页面里这两个值不同，请以实际抓到的 JS 为准。

## 4. 返回页标志

登录响应是一个 GB2312 编码的 HTML 页面，用注释标记结果：

| 标志 | 含义 |
| --- | --- |
| `Dr.COMWebLoginID_1.htm` | 注销页 / 已在线页 |
| `Dr.COMWebLoginID_2.htm` | 登录失败页 |
| `Dr.COMWebLoginID_3.htm` | 登录成功页 |

失败页中会带有：

```javascript
Msg=01;
msga='userid error2';
```

脚本会提取 `Msg` 和 `msga`，再调用错误码接口翻译。

## 5. 常见错误码

| 错误码 | Portal 翻译 | 实际含义 |
| --- | --- | --- |
| `userid error1` | 账号不存在 | 账号写错或不在该认证域 |
| `userid error2` | 密码错误 | 部分部署中实际表示“账号已在线 / 重复认证” |
| `error5 waitsec <3` | 请求过于频繁 | 注销后不足 3 秒就重登 |
| `Error code: 205` | System Error1(-98) | 请求过于频繁或参数异常 |

### `userid error2` 的坑

某些 Dr.COM 部署在账号已在线时也会返回 `userid error2`，而 Portal 后台把它配置成“密码错误”。判断方法：

1. 用一个明显错误的密码提交；
2. 如果错误密码和真实密码返回完全相同的 `userid error2`；
3. 同时 `chkstatus` 显示 `result=1`，说明该错误码实际是“账号已在线”。

因此脚本正常模式会先查状态，只有 `result=0` 才登录，避免和已在线设备冲突。

## 6. 编码与网络

- 登录结果页为 `charset=gb2312`，脚本只解析 ASCII 标记，因此不受编码影响；
- 错误码接口返回 UTF-8 JSON；
- 如果学校使用 NAT/路由器，Portal 看到的可能是路由器的 MAC，而不是电脑网卡 MAC；
- 部分学校会做 MAC 绑定，换设备可能无法登录。
