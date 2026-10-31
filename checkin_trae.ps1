# Trae CN 每日自动签到（PowerShell 原生实现，零依赖）
# 原理：读取本地登录态 -> AES 解密出 token -> 直连官方签到 API
# 只读不写任何客户端文件；不打印 token；结果写入同目录 checkin.log

$ErrorActionPreference = "Stop"

# ---- 配置 ----
$AuthKey   = "iCubeAuthInfo://icube.cloudide"
$ApiBase   = "https://api.trae.cn/trae/api/v2/ug/checkin_credits"
$ReqSource = 1   # 1=Trae CN IDE
$StorageJson = Join-Path $env:APPDATA "Trae CN\User\globalStorage\storage.json"
$AhanetCfg   = Join-Path $env:APPDATA "Trae CN\ahanet\tt_net_config.config"
$LogFile     = Join-Path $PSScriptRoot "checkin.log"

# iCube 解密常量（与客户端加密格式对应）
$HdrLen = 6; $KeyLen = 32; $HmacLen = 64
$URE = [byte[]](82,9,106,213,48,54,165,56,191,64,163,158,129,243,215,251,124,227,57,130,155,47,255,135,52,142,67,68,196,222,233,203,84,123,148,50,166,194,35,61,238,76,149,11,66,250,195,78,8,46,161,102,40,217,36,178,118,91,162,73,109,139,209,37)
$DRE = [byte[]](31,221,168,51,136,7,199,49,177,18,16,89,39,128,236,95,96,81,127,169,25,181,74,13,45,229,122,159,147,201,156,239,160,224,59,77,174,42,245,176,200,235,187,60,131,83,153,97,23,43,4,126,186,119,214,38,225,105,20,99,85,33,12,125)

function Write-Log($msg) {
    $line = "[{0}] {1}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $msg
    Write-Host $line
    Add-Content -Path $LogFile -Value $line -Encoding UTF8
}

function Get-DeviceId {
    if (Test-Path $AhanetCfg) {
        $raw = Get-Content $AhanetCfg -Raw
        if ($raw -match 'device_id\D{0,10}(\d{5,})') { return $Matches[1] }
    }
    return ""
}

function Decrypt-Auth([string]$b64) {
    $t = [Convert]::FromBase64String($b64)
    $key = New-Object byte[] $KeyLen
    [Array]::Copy($t, $HdrLen, $key, 0, $KeyLen)
    $sha512 = [System.Security.Cryptography.SHA512]::Create()
    $sha = $sha512.ComputeHash($key)
    $xor = New-Object byte[] 64
    for ($i = 0; $i -lt 64; $i++) { $xor[$i] = $URE[$i] -bxor $DRE[$i] }
    $h = $sha512.ComputeHash(($sha + $xor))
    $aesKey = New-Object byte[] 16; [Array]::Copy($h, 0,  $aesKey, 0, 16)
    $iv     = New-Object byte[] 16; [Array]::Copy($h, 16, $iv,     0, 16)
    $ctLen  = $t.Length - $HdrLen - $KeyLen
    $ct = New-Object byte[] $ctLen
    [Array]::Copy($t, ($HdrLen + $KeyLen), $ct, 0, $ctLen)
    $aes = [System.Security.Cryptography.Aes]::Create()
    $aes.Mode = [System.Security.Cryptography.CipherMode]::CBC
    $aes.Padding = [System.Security.Cryptography.PaddingMode]::None
    $aes.Key = $aesKey; $aes.IV = $iv
    $dec = $aes.CreateDecryptor().TransformFinalBlock($ct, 0, $ct.Length)
    # 去 PKCS7 padding
    $padLen = $dec[$dec.Length - 1]
    if ($padLen -lt 1 -or $padLen -gt 16) { throw "bad padding" }
    $unpaddedLen = $dec.Length - $padLen
    # 跳过头部 HMAC，取 JSON 主体
    $body = New-Object byte[] ($unpaddedLen - $HmacLen)
    [Array]::Copy($dec, $HmacLen, $body, 0, $body.Length)
    return ([Text.Encoding]::UTF8.GetString($body) | ConvertFrom-Json)
}

function Invoke-CheckinApi([string]$path, $auth, [string]$deviceId) {
    $headers = @{
        "Authorization" = "Cloud-IDE-JWT $($auth.token)"
        "Content-Type"  = "application/json"
        "x-device-id"   = $deviceId
    }
    $region = $auth.userRegion.region
    if ($region) { $headers["X-User-Region"] = $region }
    $body = @{ req_source = $ReqSource } | ConvertTo-Json
    $resp = Invoke-RestMethod -Uri "$ApiBase/$path" -Method Post -Headers $headers -Body $body -ContentType "application/json" -TimeoutSec 30
    if ($resp.PSObject.Properties.Name -contains "data" -and $resp.data -and $resp.data.PSObject.Properties.Name -contains "checked_in") { return $resp.data }
    return $resp
}

# ---- 主流程 ----
try {
    if (-not (Test-Path $StorageJson)) { Write-Log "ERROR: 未找到 $StorageJson，请先登录 Trae CN"; exit 1 }
    $storage = Get-Content $StorageJson -Raw -Encoding UTF8 | ConvertFrom-Json
    $enc = $storage.$AuthKey
    if (-not $enc) { Write-Log "ERROR: storage.json 中无登录态，请重新登录"; exit 1 }

    $auth = Decrypt-Auth $enc
    if (-not $auth.token) { Write-Log "ERROR: 登录态中无 token，请重新登录"; exit 1 }

    $deviceId = Get-DeviceId
    $status = Invoke-CheckinApi "status" $auth $deviceId

    if ($status.checked_in) {
        Write-Log "[Trae CN] 今日已签到，当前积分：$($status.credits)"
        exit 0
    }
    if ($status.enable -eq $false) {
        Write-Log "[Trae CN] 签到不可用：$($status | ConvertTo-Json -Compress)"
        exit 1
    }

    $claim = Invoke-CheckinApi "claim" $auth $deviceId
    if ($claim.code -eq 0 -or -not $claim.code) {
        $after = Invoke-CheckinApi "status" $auth $deviceId
        Write-Log "[Trae CN] 签到成功，当前积分：$($after.credits)"
        exit 0
    }
    Write-Log "[Trae CN] 签到失败：$($claim.message)"
    exit 1
} catch {
    Write-Log "ERROR: $($_.Exception.Message)"
    exit 1
}
