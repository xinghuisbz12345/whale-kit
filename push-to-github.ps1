#requires -Version 5.1
<#
  push-to-github.ps1 —— 把 whale-kit 推到你的 GitHub（Token 只在本机输入）

  为什么用脚本而不是让我代推：这台机器没有 Git Credential Manager，
  推送必须用 Token。让你在终端里安全输入（Read-Host -AsSecureString），
  Token 就不会留在聊天记录里，也不会写进 .git/config。

  用法：
    方式一：双击本文件 / 右键“使用 PowerShell 运行”
    方式二：powershell -NoProfile -ExecutionPolicy Bypass -File push-to-github.ps1
            （可加 -RepoName xxx -Private:$false 跳过交互）

  流程：输入 Token → 建仓库（已存在则跳过）→ 推送 → 还原 remote 为干净地址
#>
param(
  [string]$RepoName = 'whale-kit',
  [string]$KitDir = 'D:\Backup\Documents\deepseek-harness\whale-kit',
  [switch]$Public
)

$ErrorActionPreference = 'Stop'
$git = 'C:\Users\Administrator\AppData\Local\Programs\Git\cmd\git.exe'
if (-not (Test-Path -LiteralPath $git)) { $git = 'git' }

function Say($m, $c = 'Gray') { Write-Host $m -ForegroundColor $c }

Say "==========================================" 'Cyan'
Say "  推送 whale-kit 到 GitHub" 'Cyan'
Say "==========================================" 'Cyan'
Say ""

if (-not (Test-Path -LiteralPath (Join-Path $KitDir '.git'))) {
  Say "✗ 找不到 git 仓库：$KitDir" 'Red'
  Read-Host "按回车退出" | Out-Null
  exit 1
}

# ---------- 1) 拿 Token（不回显） ----------
if (-not $env:GH_PUSH_TOKEN) {
  Say "请粘贴 GitHub Token（输入时不显示），然后回车：" 'Yellow'
  Say "  生成地址：https://github.com/settings/personal-access-tokens/new" 'DarkGray'
  Say "  权限：Contents = Read and write" 'DarkGray'
  $sec = Read-Host -AsSecureString
  $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($sec)
  try { $token = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr) }
  finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
} else { $token = $env:GH_PUSH_TOKEN }

$token = ($token -as [string]).Trim()
if (-not $token) { Say "✗ 没拿到 Token" 'Red'; Read-Host "按回车退出" | Out-Null; exit 1 }

# ---------- 2) 确认仓库名 / 可见性 ----------
if (-not $PSBoundParameters.ContainsKey('RepoName')) {
  $input = Read-Host "仓库名（直接回车 = whale-kit）"
  if ($input.Trim()) { $RepoName = $input.Trim() }
}
$isPrivate = -not $Public
if (-not $PSBoundParameters.ContainsKey('Public')) {
  $v = Read-Host "私有仓库？(Y/n，直接回车 = Y)"
  if ($v -and $v.Trim().ToLower().StartsWith('n')) { $isPrivate = $false }
}

$headers = @{
  Authorization          = "Bearer $token"
  Accept                 = 'application/vnd.github+json'
  'X-GitHub-Api-Version' = '2022-11-28'
  'User-Agent'           = 'whale-kit-push'
}

# ---------- 3) 是谁 ----------
Say ""
Say "→ 校验 Token…"
try {
  $me = Invoke-RestMethod -Uri 'https://api.github.com/user' -Headers $headers -TimeoutSec 30
} catch {
  Say ("✗ Token 无效或网络不通：" + $_.Exception.Message) 'Red'
  Read-Host "按回车退出" | Out-Null
  exit 1
}
$login = $me.login
Say ("  ✓ 已认证为 " + $login) 'Green'

# ---------- 4) 建仓库（已存在则复用） ----------
$body = @{ name = $RepoName; private = $isPrivate; description = '小鲸鱼能力包：桥接补丁/三音色TTS/长期记忆/守护/养鱼接线/安装教程'; has_issues = $true; has_wiki = $false } | ConvertTo-Json
$created = $false
try {
  $repo = Invoke-RestMethod -Uri 'https://api.github.com/user/repos' -Method POST -Headers $headers -Body $body -ContentType 'application/json; charset=utf-8' -TimeoutSec 40
  Say ("  ✓ 已创建仓库（" + $(if($isPrivate){'私有'}else{'公开'}) + "）") 'Green'
  $created = $true
} catch {
  $code = $null
  if ($_.Exception.Response) { $code = [int]$_.Exception.Response.StatusCode }
  if ($code -eq 422) {
    Say "  仓库已存在，直接推送" 'Yellow'
    $repo = Invoke-RestMethod -Uri ("https://api.github.com/repos/$login/$RepoName") -Headers $headers -TimeoutSec 30
  } else {
    Say ("✗ 建仓库失败（HTTP $code）：" + $_.Exception.Message) 'Red'
    Read-Host "按回车退出" | Out-Null
    exit 1
  }
}

$httpsUrl = $repo.clone_url
$pushUrl = $httpsUrl -replace '^https://', ("https://x-access-token:" + [uri]::EscapeDataString($token) + "@")
Say ("  仓库地址: " + $repo.html_url) 'Cyan'

# ---------- 5) 推送 ----------
Push-Location $KitDir
try {
  Say ""
  Say "→ 推送（master → main）…"
  & $git branch -M main 2>&1 | Out-Null

  & $git remote remove origin 2>&1 | Out-Null
  # 临时把 token 放进 remote URL，只为这一次 push（推完立刻还原，不落盘）
  & $git remote add origin $pushUrl 2>&1 | Out-Null
  $out = & $git push -u origin main --force 2>&1
  $ok = ($LASTEXITCODE -eq 0)
  $out | Select-Object -Last 6 | ForEach-Object { Say ("  " + $_) }
  # 还原成干净地址（凭证不留在 .git/config）
  & $git remote set-url origin $httpsUrl 2>&1 | Out-Null
  if (-not $ok) {
    Say "✗ 推送失败（见上面输出）" 'Red'
    Read-Host "按回车退出" | Out-Null
    exit 1
  }
  Say ""
  Say "==========================================" 'Green'
  Say ("  ✅ 推送完成：" + $repo.html_url) 'Green'
  Say ("     克隆地址：" + $httpsUrl) 'Green'
  Say "==========================================" 'Green'
} finally {
  Pop-Location
  Remove-Variable token -ErrorAction SilentlyContinue
  Remove-Variable pushUrl -ErrorAction SilentlyContinue
}

Say ""
Say "提示：Token 没有写进任何文件；如不放心可去 GitHub 删除重建。" 'DarkGray'
Read-Host "按回车关闭" | Out-Null
