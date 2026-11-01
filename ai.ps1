# AI 终端助手 — 默认走硅基流动免费 API；-local 走本机 Ollama（零积分、零联网）
# 用法:
#   .\ai.ps1 你的问题          单次问答（云端免费 API）
#   .\ai.ps1 -local 你的问题   单次问答（本机 Ollama，需已启动）
#   .\ai.ps1                   进入交互聊天（exit 退出）
#   .\ai.ps1 -m 模型ID 问题    指定模型
#   .\ai.ps1 -local -m qwen2.5:14b 问题   本地 + 指定模型
$m = "Qwen/Qwen2.5-7B-Instruct"
$mSet = $false
$local = $false
$Question = @($args)
while ($Question.Count -ge 1) {
    if ($Question[0] -eq "-m" -and $Question.Count -ge 2) {
        $m = $Question[1]; $mSet = $true
        if ($Question.Count -gt 2) { $Question = @($Question[2..($Question.Count - 1)]) } else { $Question = @() }
    } elseif ($Question[0] -in @("-local", "-l")) {
        $local = $true
        if (-not $mSet) { $m = "qwen2.5:7b" }
        if ($Question.Count -gt 1) { $Question = @($Question[1..($Question.Count - 1)]) } else { $Question = @() }
    } else { break }
}

$headers = @{}
if ($local) {
    $base = "http://localhost:11434/v1/chat/completions"
} else {
    $keyFile = Join-Path $PSScriptRoot ".sfkey"
    if (-not (Test-Path $keyFile)) { Write-Host "缺少 $keyFile（API key 文件）" -ForegroundColor Red; exit 1 }
    $key = (Get-Content $keyFile -Raw).Trim()
    $base = "https://api.siliconflow.cn/v1/chat/completions"
    $headers = @{ Authorization = "Bearer $key" }
}
$tag = if ($local) { "本地 Ollama" } else { "云端免费API" }

function Ask($model, $messages) {
    $body = @{ model = $model; messages = $messages; max_tokens = 2048; stream = $false } | ConvertTo-Json -Depth 5
    # WebClient 强制 UTF-8 解码响应（Ollama 响应头无 charset，Invoke-RestMethod 在 PS5 下会误用 Latin-1 导致中文乱码）
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    $wc = New-Object System.Net.WebClient
    $wc.Encoding = [Text.Encoding]::UTF8
    $wc.Headers["Content-Type"] = "application/json; charset=utf-8"
    foreach ($k in $headers.Keys) { $wc.Headers[$k] = $headers[$k] }
    $resp = $wc.UploadString($base, "POST", $body)
    return ($resp | ConvertFrom-Json).choices[0].message.content
}

if ($Question) {
    try { Ask $m @(@{ role = "user"; content = ($Question -join " ") }) }
    catch {
        if ($local) { Write-Host "本地 Ollama 未响应（服务未启动或正在加载）。稍等几秒重试，或手动拉起: schtasks /Run /TN OllamaServe" -ForegroundColor Red }
        else { Write-Host "云端 API 调用失败: $($_.Exception.Message)" -ForegroundColor Red }
        exit 1
    }
} else {
    if ([Console]::IsInputRedirected) { Write-Host "无交互终端，请用 .\ai.ps1 `"问题`" 单次模式" -ForegroundColor Red; exit 1 }
    Write-Host "AI 终端助手 [$tag | $m]" -ForegroundColor Cyan
    Write-Host "命令: exit=退出  /m 模型名=切换模型" -ForegroundColor DarkGray
    $history = @()
    while ($true) {
        Write-Host "你> " -NoNewline -ForegroundColor Green
        $text = Read-Host
        if ($text -eq "exit") { break }
        if ($text -like "/m *") { $m = $text.Substring(3).Trim(); $history = @(); Write-Host "  -> 模型切换为 $m" -ForegroundColor Cyan; continue }
        if (-not $text) { continue }
        $history += @{ role = "user"; content = $text }
        try {
            $ans = Ask $m $history
            Write-Host "AI> $ans`n" -ForegroundColor Yellow
            $history += @{ role = "assistant"; content = $ans }
        } catch {
            Write-Host "ERR: $($_.Exception.Message)" -ForegroundColor Red
        }
    }
}
