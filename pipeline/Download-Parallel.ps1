#requires -Version 5.1
<#
  Download-Parallel.ps1 -- 多连接分段下载（绕开 hf-mirror 的单连接限速）

  背景：hf-mirror 单流只有 ~0.4 MB/s，但 4 并发能到 ~2.3 MB/s（实测），
  说明它限的是"每个连接"，不是总带宽。所以按 Range 切片、多进程并发抓，
  最后按顺序拼接即可。aria2c 没装，这里用 curl 的 --range 自己实现。

  特性：
    - 断点续传：已下完的分片（大小对得上）直接跳过，重跑不重复下
    - 分片校验：每个分片必须长度等于预期，否则重下
    - 后台友好：进度写日志文件，静默运行

  用法：
    powershell -NoProfile -ExecutionPolicy Bypass -File Download-Parallel.ps1 `
      -Url <直链> -OutFile <目标路径> [-Threads 12] [-ChunkMB 16]
#>
param(
  [Parameter(Mandatory=$true)][string]$Url,
  [Parameter(Mandatory=$true)][string]$OutFile,
  [int]$Threads = 12,
  [int]$ChunkMB = 16,
  [int]$MaxRetry = 6
)

$ErrorActionPreference = 'Stop'
$chunkBytes = [int64]$ChunkMB * 1MB
$partDir = "$OutFile.parts"
$logFile = "$OutFile.download.log"

function Log([string]$m) {
  $line = "[{0}] {1}" -f (Get-Date -Format 'HH:mm:ss'), $m
  Write-Host $line
  Add-Content -LiteralPath $logFile -Value $line -Encoding UTF8
}

# ---------- 1) 取总大小 ----------
function Get-RemoteSize([string]$u) {
  # 优先 curl -sIL：HF 直链会 302 到 CDN，必须跟完重定向；
  # 响应里会出现**多个** content-length（302 的响应体长度 + 最终文件长度），
  # 取**最大值**才是文件真实大小（拿第一个会得到 1KB 之类的假值 —— 这就是第一次失败的原因）。
  $h = & curl.exe -sIL --max-time 40 $u 2>$null
  $opt = [System.Text.RegularExpressions.RegexOptions]::IgnoreCase
  $lens = [System.Text.RegularExpressions.Regex]::Matches(($h -join "`n"), 'content-length:\s*(\d+)', $opt) |
    ForEach-Object { [int64]$_.Groups[1].Value } | Where-Object { $_ -gt 0 }
  if ($lens) { return [int64](($lens | Measure-Object -Maximum).Maximum) }
  # 退一步：Range 0-0 读 content-range 的总长
  $d = & curl.exe -s --max-time 40 -r 0-0 -D - -o NUL $u 2>$null
  $m = [System.Text.RegularExpressions.Regex]::Match(($d -join "`n"), 'content-range:\s*bytes\s+\d+-\d+/(\d+)', $opt)
  if ($m.Success) { return [int64]$m.Groups[1].Value }
  # 最后试 HttpWebRequest
  try {
    $req = [System.Net.HttpWebRequest]::Create($u)
    $req.Method = 'HEAD'; $req.Timeout = 40000; $req.AllowAutoRedirect = $true
    $resp = $req.GetResponse(); $len = $resp.ContentLength; $resp.Close()
    if ($len -gt 0) { return [int64]$len }
  } catch { }
  throw "取不到远端文件大小：$u"
}

Log ("目标: " + $OutFile)
$total = Get-RemoteSize $Url
Log ("大小: {0:N2} GB ({1:N0} 字节)" -f ($total/1GB), $total)

if ((Test-Path -LiteralPath $OutFile) -and ((Get-Item -LiteralPath $OutFile).Length -eq $total)) {
  Log "已存在且大小一致，跳过下载"
  return
}

New-Item -ItemType Directory -Path $partDir -Force | Out-Null
$count = [int][Math]::Ceiling($total / $chunkBytes)
Log ("分片: {0} 片 x {1} MB，并发 {2}" -f $count, $ChunkMB, $Threads)

# ---------- 2) 待下分片 ----------
$todo = New-Object System.Collections.ArrayList
for ($i = 0; $i -lt $count; $i++) {
  $start = [int64]$i * $chunkBytes
  $end = [Math]::Min($start + $chunkBytes - 1, $total - 1)
  $expect = $end - $start + 1
  $part = Join-Path $partDir ("p{0:D5}.bin" -f $i)
  $ok = (Test-Path -LiteralPath $part) -and ((Get-Item -LiteralPath $part).Length -eq $expect)
  if (-not $ok) { [void]$todo.Add([pscustomobject]@{ Index=$i; Start=$start; End=$end; Expect=$expect; Part=$part }) }
}
Log ("已完成 {0} 片，待下 {1} 片" -f ($count - $todo.Count), $todo.Count)

if ($todo.Count -eq 0) {
  Log "所有分片就绪，直接拼接"
} else {
  # ---------- 3) 并发下载 ----------
  $queue = [System.Collections.Queue]::new()
  foreach ($t in $todo) { $queue.Enqueue($t) }
  $running = @{}
  $doneBytes = [int64]0
  $fail = 0

  while ($queue.Count -gt 0 -or $running.Count -gt 0) {
    while ($running.Count -lt $Threads -and $queue.Count -gt 0) {
      $t = $queue.Dequeue()
      $args = @('-sL', '--max-time', '900', '--retry', '4', '--retry-delay', '2',
                '-r', ("{0}-{1}" -f $t.Start, $t.End), '-o', $t.Part, $Url)
      $p = Start-Process -FilePath 'curl.exe' -ArgumentList $args -PassThru -WindowStyle Hidden
      $running[$p.Id] = @{ Proc=$p; Task=$t; Retry=0 }
    }
    Start-Sleep -Milliseconds 800
    foreach ($id in @($running.Keys)) {
      $entry = $running[$id]
      if ($entry.Proc.HasExited) {
        $t = $entry.Task
        $sizeOk = (Test-Path -LiteralPath $t.Part) -and ((Get-Item -LiteralPath $t.Part).Length -eq $t.Expect)
        if ($sizeOk) {
          $doneBytes += $t.Expect
          $running.Remove($id)
        } else {
          $entry.Retry++
          if ($entry.Retry -ge $MaxRetry) {
            $fail++
            Log ("  ✗ 分片 {0} 失败 {1} 次，放弃" -f $t.Index, $entry.Retry)
            $running.Remove($id)
          } else {
            # 重下这一片
            $args = @('-sL','--max-time','900','--retry','3','--retry-delay','2',
                      '-r', ("{0}-{1}" -f $t.Start, $t.End), '-o', $t.Part, $Url)
            $p2 = Start-Process -FilePath 'curl.exe' -ArgumentList $args -PassThru -WindowStyle Hidden
            $running.Remove($id)
            $running[$p2.Id] = @{ Proc=$p2; Task=$t; Retry=$entry.Retry }
          }
        }
        $pct = if ($total -gt 0) { [math]::Round(100.0 * ($doneBytes + (($count - $todo.Count) * $chunkBytes)) / $total, 1) } else { 0 }
        if ($pct -gt 100) { $pct = 100 }
        Log ("  进度 {0}%  ({1:N0}/{2:N0} MB)  进行中 {3}" -f $pct, (($doneBytes)/1MB), ($total/1MB), $running.Count)
      }
    }
  }
  if ($fail -gt 0) { throw "有 $fail 个分片最终失败，请重跑（会续传）" }
}

# ---------- 4) 拼接 ----------
Log "拼接分片 → $OutFile"
$outStream = [System.IO.File]::Create($OutFile)
try {
  for ($i = 0; $i -lt $count; $i++) {
    $part = Join-Path $partDir ("p{0:D5}.bin" -f $i)
    if (-not (Test-Path -LiteralPath $part)) { throw "缺分片 $part" }
    $in = [System.IO.File]::OpenRead($part)
    try { $in.CopyTo($outStream) } finally { $in.Dispose() }
  }
} finally { $outStream.Dispose() }

$size = (Get-Item -LiteralPath $OutFile).Length
if ($size -eq $total) {
  Log ("✅ 完成，大小校验一致: {0:N2} GB" -f ($size/1GB))
  Remove-Item -LiteralPath $partDir -Recurse -Force -ErrorAction SilentlyContinue
} else {
  Log ("⚠️ 大小不一致: 实际 {0:N0} 期望 {1:N0}" -f $size, $total)
}
