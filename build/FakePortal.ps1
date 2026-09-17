<#
  测试用假 Portal：把 Dr.COM ePortal 的几个接口用最简 HTTP 服务器复刻出来，
  并把收到的每一次请求记进 -LogPath（每行一条 "METHOD /path"），供测试断言请求次数。
  仅监听 127.0.0.1，不对外网开放。
#>
param(
    [Parameter(Mandatory = $true)][string]$Scenario,
    [Parameter(Mandatory = $true)][int]$Port,
    [Parameter(Mandatory = $true)][string]$LogPath
)

$ErrorActionPreference = 'Stop'

function Send-Response {
    param($Stream, [string]$Body, [string]$ContentType = 'text/html; charset=gb2312', [int]$Status = 200)
    $encoding = if ($ContentType -match 'utf-8') { [System.Text.Encoding]::UTF8 } else { [System.Text.Encoding]::ASCII }
    $bytes = $encoding.GetBytes($Body)
    $reason = switch ($Status) {
        200 { 'OK' }
        204 { 'No Content' }
        302 { 'Found' }
        500 { 'Internal Server Error' }
        default { 'Status' }
    }
    # 204 按 HTTP 规范不带响应体（这正是「只认 204」测试要的情形）
    if ($Status -eq 204) { $bytes = New-Object byte[] 0 }
    $head = "HTTP/1.1 $Status $reason`r`nContent-Type: $ContentType`r`nContent-Length: $($bytes.Length)`r`nConnection: close`r`n`r`n"
    $headBytes = [System.Text.Encoding]::ASCII.GetBytes($head)
    $Stream.Write($headBytes, 0, $headBytes.Length)
    $Stream.Write($bytes, 0, $bytes.Length)
    $Stream.Flush()
}

function Read-Request {
    param($Stream)
    $buffer = New-Object System.Collections.Generic.List[byte]
    $chunk = New-Object byte[] 1024
    $headerEnd = -1
    while ($headerEnd -lt 0) {
        $read = $Stream.Read($chunk, 0, $chunk.Length)
        if ($read -le 0) { break }
        for ($i = 0; $i -lt $read; $i++) { $buffer.Add($chunk[$i]) }
        $text = [System.Text.Encoding]::ASCII.GetString($buffer.ToArray())
        $headerEnd = $text.IndexOf("`r`n`r`n")
    }
    if ($headerEnd -lt 0) { return '' }
    $text = [System.Text.Encoding]::ASCII.GetString($buffer.ToArray())
    $head = $text.Substring(0, $headerEnd)
    $contentLength = 0
    $match = [regex]::Match($head, 'Content-Length:\s*(\d+)', 'IgnoreCase')
    if ($match.Success) { $contentLength = [int]$match.Groups[1].Value }
    $bodyStart = $headerEnd + 4
    while (($text.Length - $bodyStart) -lt $contentLength) {
        $read = $Stream.Read($chunk, 0, $chunk.Length)
        if ($read -le 0) { break }
        $text += [System.Text.Encoding]::ASCII.GetString($chunk, 0, $read)
    }
    return $text
}

$listener = New-Object System.Net.Sockets.TcpListener([System.Net.IPAddress]::Loopback, $Port)
$listener.Start()
Set-Content -LiteralPath $LogPath -Value "START $Scenario" -Encoding UTF8
$counts = @{ chkstatus = 0; login = 0; logout = 0; error = 0 }
$blackholeClients = New-Object System.Collections.Generic.List[object]

while ($true) {
    $client = $listener.AcceptTcpClient()
    $keepOpen = $false
    try {
        $stream = $client.GetStream()
        $request = Read-Request -Stream $stream
        if ([string]::IsNullOrEmpty($request)) { $client.Close(); continue }

        $firstLine = ($request -split "`r`n")[0]
        $parts = $firstLine -split ' '
        $method = $parts[0]
        $path = if ($parts.Length -gt 1) { $parts[1] } else { '/' }
        Add-Content -LiteralPath $LogPath -Value ("$method $path") -Encoding UTF8

        if ($Scenario -eq 'blackhole') {
            # 「连接得过、内容永远不来」：用来验证探测是并行的（串行会成倍变慢）
            $blackholeClients.Add($client)
            $keepOpen = $true
        }
        elseif ($path -like '*chkstatus*') {
            $counts.chkstatus++
            $online = $false
            switch ($Scenario) {
                'online' { $online = $true }
                'confirm-online' { if ($counts.chkstatus -ge 2) { $online = $true } }
                'offline-ok' { if ($counts.login -ge 1) { $online = $true } }
                # 登录接口回了「已在别处在线」，但会话其实已经建立：第 3 次查询起显示在线
                'conflict-then-online' { if ($counts.chkstatus -ge 3) { $online = $true } }
                'content-ok' { $online = $true }
                default { $online = $false }
            }
            $value = if ($online) { 1 } else { 0 }
            Send-Response -Stream $stream -Body "dr123({`"result`":$value,`"uid`":`"test`",`"v4ip`":`"127.0.0.1`"})"
        }
        elseif ($path -like '*login*') {
            $counts.login++
            switch ($Scenario) {
                'rate-limited' {
                    Send-Response -Stream $stream -Body "<!--Dr.COMWebLoginID_2.htm--><script>Msg=01;msga='error5 waitsec 3';</script>"
                }
                'conflict' {
                    Send-Response -Stream $stream -Body "<!--Dr.COMWebLoginID_2.htm--><script>Msg=01;msga='userid error2';</script>"
                }
                'login-fail' {
                    Send-Response -Stream $stream -Body "<!--Dr.COMWebLoginID_2.htm--><script>Msg=05;msga='error9 unknown';</script>"
                }
                'garbage' {
                    Send-Response -Stream $stream -Body '<html>something entirely unexpected</html>'
                }
                'echo-form' {
                    # 模拟「Portal 把提交的表单回显在错误页里」：用来验证密码/账号不会跟着落盘。
                    # 只回显请求体（含 DDDDD=账号&upass=密码），不发别的敏感内容。
                    $body = ''
                    $split = $request.IndexOf("`r`n`r`n")
                    if ($split -ge 0) { $body = $request.Substring($split + 4) }
                    Send-Response -Stream $stream -Body ('<html>form echo: ' + $body + '</html>')
                }
                default {
                    Send-Response -Stream $stream -Body "<!--Dr.COMWebLoginID_3.htm--><html>login ok</html>"
                }
            }
            if ($Scenario -eq 'drop-after-login') {
                # 登录接口回「成功」，但紧接着整个 Portal 就不可达了：
                # 用来验证「状态接口不可达 ≠ 登录成功」。
                try { $client.Client.Shutdown([System.Net.Sockets.SocketShutdown]::Send) } catch { }
                Start-Sleep -Milliseconds 200
            }
        }
        elseif ($path -like '*logout*') {
            $counts.logout++
            Send-Response -Stream $stream -Body 'dr123({"result":1,"msg":14,"uid":"test"})'
        }
        elseif ($path -like '*loadErrorPrompt*') {
            $counts.error++
            $code = 'userid error2'
            $prompt = '密码错误'
            $m = [regex]::Match($path, 'error_code=([^&]+)')
            if ($m.Success) { $code = [uri]::UnescapeDataString($m.Groups[1].Value) }
            if ($code -match 'waitsec') { $prompt = '请求过于频繁' }
            Send-Response -Stream $stream -ContentType 'application/json; charset=utf-8' `
                -Body ("dr1({`"result`":1,`"error_code`":`"$code`",`"error_prompt_zh`":`"$prompt`"})")
        }
        elseif (($Scenario -eq 'content-ok' -or $Scenario -eq 'content-204') -and $path -like '*connecttest.txt*') {
            # 内容校验测试用：content-ok 发关键字；content-204 发真正的 204 空响应
            if ($Scenario -eq 'content-204') {
                Send-Response -Stream $stream -Status 204 -Body ''
            } else {
                Send-Response -Stream $stream -ContentType 'text/plain; charset=utf-8' -Body 'Microsoft Connect Test'
            }
        }
        else {
            Send-Response -Stream $stream -Body 'not found'
        }
    }
    catch { }
    finally {
        if (-not $keepOpen) { try { $client.Close() } catch { } }
    }
    if ($Scenario -eq 'drop-after-login' -and $counts.login -ge 1) {
        try { $listener.Stop() } catch { }
        exit 0
    }
}
