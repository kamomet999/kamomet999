<#
    netcheck-wan.ps1 - 「回線全体が遅い」のか「特定の経路だけ遅い」のかを切り分ける。

    netcheck.ps1 で外向きが遅いと出た場合の二段目の診断です。
    宛先を変えて測ることで、原因が ISP 全体なのか、
    特定の相手までの経路 (ピアリング) なのかを判定します。

    使い方:
        powershell -ExecutionPolicy Bypass -File .\netcheck-wan.ps1
#>

[CmdletBinding()]
param(
    [int]$CapMB      = 80,   # 1 ソースあたり最大何 MB 落とすか
    [int]$CapSeconds = 20,   # 1 ソースあたり最大何秒かけるか
    [switch]$SkipTrace       # 経路表示 (tracert) を省略する
)

$ErrorActionPreference = 'Continue'
$ProgressPreference    = 'SilentlyContinue'

function Write-Head($t) { Write-Host ""; Write-Host "== $t ==" -ForegroundColor Cyan }
function Write-Ok($t)   { Write-Host "  [OK]   " -ForegroundColor Green  -NoNewline; Write-Host $t }
function Write-Warn($t) { Write-Host "  [注意] " -ForegroundColor Yellow -NoNewline; Write-Host $t }
function Write-Bad($t)  { Write-Host "  [問題] " -ForegroundColor Red    -NoNewline; Write-Host $t }
function Write-Info($t) { Write-Host "         $t" }

Write-Host ""
Write-Host "netcheck-wan  -  $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')" -ForegroundColor White
$hour = (Get-Date).Hour
if ($hour -ge 20 -or $hour -lt 2) {
    Write-Info "※ 今は日本の回線が最も混雑する時間帯です。昼間にもう一度測ると比較になります。"
}

# ----------------------------------------------------------------- 計測
function Measure-Latency([string]$Target, [int]$Count = 10) {
    $ping  = New-Object System.Net.NetworkInformation.Ping
    $times = New-Object System.Collections.ArrayList
    $lost  = 0
    for ($i = 0; $i -lt $Count; $i++) {
        try {
            $r = $ping.Send($Target, 2000)
            if ($r.Status -eq [System.Net.NetworkInformation.IPStatus]::Success) {
                $null = $times.Add([double]$r.RoundtripTime)
            } else { $lost++ }
        } catch { $lost++ }
        Start-Sleep -Milliseconds 100
    }
    $ping.Dispose()
    if ($times.Count -eq 0) { return $null }
    $arr = $times.ToArray()
    $jit = 0.0
    if ($arr.Count -gt 1) {
        $d = 0.0
        for ($i = 1; $i -lt $arr.Count; $i++) { $d += [math]::Abs($arr[$i] - $arr[$i-1]) }
        $jit = $d / ($arr.Count - 1)
    }
    [PSCustomObject]@{
        Avg     = [math]::Round((($arr | Measure-Object -Average).Average), 1)
        Min     = [math]::Round((($arr | Measure-Object -Minimum).Minimum), 1)
        Max     = [math]::Round((($arr | Measure-Object -Maximum).Maximum), 1)
        Jitter  = [math]::Round($jit, 1)
        LossPct = [math]::Round(100.0 * $lost / $Count, 0)
    }
}

function Measure-Source([string]$Url, [int]$CapBytes, [int]$CapSec) {
    try { Add-Type -AssemblyName System.Net.Http -ErrorAction SilentlyContinue } catch {}
    $client = $null; $stream = $null
    try {
        $client = New-Object System.Net.Http.HttpClient
        $client.Timeout = [TimeSpan]::FromSeconds($CapSec + 15)
        $stream = $client.GetStreamAsync($Url).GetAwaiter().GetResult()
        $buf   = New-Object byte[] 131072
        $total = 0L
        $sw    = [System.Diagnostics.Stopwatch]::StartNew()

        # TCP はコネクション開始直後、輻輳ウィンドウが小さく本来の速度が出ない
        # (スロースタート)。最初の 1.5 秒を捨てて、そこから先だけで速度を出す。
        $warmupSec   = 1.5
        $steadyStart = $null
        $steadyBytes = 0L

        while ($true) {
            $n = $stream.Read($buf, 0, $buf.Length)
            if ($n -le 0) { break }
            $total += $n
            if ($sw.Elapsed.TotalSeconds -ge $warmupSec) {
                if ($null -eq $steadyStart) { $steadyStart = $sw.Elapsed.TotalSeconds }
                else { $steadyBytes += $n }
            }
            if ($total -ge $CapBytes) { break }
            if ($sw.Elapsed.TotalSeconds -ge $CapSec) { break }
        }
        $sw.Stop()
        if ($total -lt 200000 -or $sw.Elapsed.TotalSeconds -le 0.05) { return $null }

        $overall = ($total * 8.0) / $sw.Elapsed.TotalSeconds / 1000000.0
        $mbps    = $overall
        $steady  = $false
        if ($null -ne $steadyStart) {
            $steadySec = $sw.Elapsed.TotalSeconds - $steadyStart
            if ($steadySec -ge 0.5 -and $steadyBytes -gt 500000) {
                $mbps   = ($steadyBytes * 8.0) / $steadySec / 1000000.0
                $steady = $true
            }
        }
        [PSCustomObject]@{
            Mbps    = [math]::Round($mbps, 1)
            Overall = [math]::Round($overall, 1)
            Steady  = $steady
            MB      = [math]::Round($total / 1000000.0, 1)
            Seconds = [math]::Round($sw.Elapsed.TotalSeconds, 1)
        }
    } catch {
        return $null
    } finally {
        if ($stream) { $stream.Dispose() }
        if ($client) { $client.Dispose() }
    }
}

# ================================================================= 1. 宛先別レイテンシ
Write-Head "1. 宛先別レイテンシ (IPv4)"
Write-Info "同じ回線から複数の相手に打ちます。相手ごとに差が出れば経路の問題です。"
Write-Host ""

$v4Targets = @(
    [PSCustomObject]@{ Ip='1.1.1.1';         Name='Cloudflare' },
    [PSCustomObject]@{ Ip='8.8.8.8';         Name='Google'     },
    [PSCustomObject]@{ Ip='9.9.9.9';         Name='Quad9'      },
    [PSCustomObject]@{ Ip='208.67.222.222';  Name='OpenDNS'    }
)
$v4Results = New-Object System.Collections.ArrayList
foreach ($t in $v4Targets) {
    $r = Measure-Latency $t.Ip 10
    if ($r) {
        Write-Info ("{0,-16} {1,-12} 平均 {2,6} ms  最小 {3,6} ms  ジッター {4,5} ms  ロス {5}%" -f $t.Ip, $t.Name, $r.Avg, $r.Min, $r.Jitter, $r.LossPct)
        $null = $v4Results.Add([PSCustomObject]@{ Ip=$t.Ip; Name=$t.Name; Avg=$r.Avg; Min=$r.Min; Jitter=$r.Jitter })
    } else {
        Write-Info ("{0,-16} {1,-12} 応答なし" -f $t.Ip, $t.Name)
    }
}

$routeIssue = $false
if ($v4Results.Count -ge 2) {
    $fast = $v4Results | Sort-Object Avg | Select-Object -First 1
    $slow = $v4Results | Sort-Object Avg -Descending | Select-Object -First 1
    Write-Host ""
    if (($slow.Avg - $fast.Avg) -gt 50) {
        $routeIssue = $true
        Write-Bad "相手によって $($fast.Avg) ms 〜 $($slow.Avg) ms と大きく差があります。"
        Write-Info "回線そのものではなく、$($slow.Name) 方向の経路だけが悪化しています。"
    } else {
        Write-Info "どの相手もほぼ同じ ($($fast.Avg) 〜 $($slow.Avg) ms) です。特定経路の問題ではありません。"
        if ($fast.Avg -gt 40) {
            Write-Warn "ただし全体的に遅く、最速の相手でも $($fast.Avg) ms かかっています。回線全体の問題です。"
        }
    }
}

# ================================================================= 2. IPv6
Write-Head "2. IPv6 での同じ相手へのレイテンシ"
Write-Info "IPv4 が遅く IPv6 が速いなら、IPv4 だけ混雑した経路 (PPPoE) を通っています。"
Write-Host ""

$v6Targets = @(
    [PSCustomObject]@{ Ip='2606:4700:4700::1111'; Name='Cloudflare'; V4='1.1.1.1' },
    [PSCustomObject]@{ Ip='2001:4860:4860::8888'; Name='Google';     V4='8.8.8.8' }
)
$v6Any = $false
$v6Better = $false
foreach ($t in $v6Targets) {
    $r = Measure-Latency $t.Ip 10
    if ($r) {
        $v6Any = $true
        $v4 = $v4Results | Where-Object { $_.Ip -eq $t.V4 } | Select-Object -First 1
        $cmp = ''
        if ($v4) {
            $diff = [math]::Round($v4.Avg - $r.Avg, 1)
            if ($diff -gt 30) { $cmp = "  <- IPv4 より $diff ms 速い"; $v6Better = $true }
            elseif ($diff -lt -30) { $cmp = "  <- IPv4 より $([math]::Abs($diff)) ms 遅い" }
            else { $cmp = "  <- IPv4 とほぼ同じ" }
        }
        Write-Info ("{0,-24} {1,-12} 平均 {2,6} ms  ジッター {3,5} ms{4}" -f $t.Ip, $t.Name, $r.Avg, $r.Jitter, $cmp)
    } else {
        Write-Info ("{0,-24} {1,-12} 応答なし" -f $t.Ip, $t.Name)
    }
}
Write-Host ""
if (-not $v6Any) {
    Write-Warn "IPv6 で外に出られていません。IPv6 アドレスがあっても経路が通っていない状態です。"
} elseif ($v6Better) {
    Write-Bad "IPv6 の方が明確に速いです。IPv4 だけが混雑した経路を通っています。"
} else {
    Write-Ok "IPv4 と IPv6 で大きな差はありません。"
}

# ================================================================= 3. ソース別スループット
Write-Head "3. ダウンロード元を変えた速度比較"
Write-Info "1 ソースあたり最大 ${CapMB}MB / ${CapSeconds}秒 で打ち切ります。"
Write-Host ""

$capBytes = $CapMB * 1000000
$sources = @(
    [PSCustomObject]@{ Name='Cloudflare (世界CDN)'; Url="https://speed.cloudflare.com/__down?bytes=104857600" },
    [PSCustomObject]@{ Name='Linode 東京 (国内)';   Url='http://speedtest.tokyo2.linode.com/100MB-tokyo2.bin' },
    [PSCustomObject]@{ Name='GitHub (Fastly CDN)';  Url='https://github.com/PowerShell/PowerShell/releases/download/v7.4.6/PowerShell-7.4.6-win-x64.zip' }
)
$dlResults = New-Object System.Collections.ArrayList
$dlFailed  = New-Object System.Collections.ArrayList
foreach ($s in $sources) {
    Write-Host ("         {0,-22} " -f $s.Name) -NoNewline
    $r = Measure-Source $s.Url $capBytes $CapSeconds
    if ($r) {
        $note = ''
        if (-not $r.Steady) { $note = '  ※転送が短すぎて立ち上がり中に終了。実力より低く出ています' }
        Write-Host ("{0,7} Mbps   ({1}MB / {2}秒){3}" -f $r.Mbps, $r.MB, $r.Seconds, $note)
        $null = $dlResults.Add([PSCustomObject]@{ Name=$s.Name; Mbps=$r.Mbps; Steady=$r.Steady })
    } else {
        Write-Host "計測できず"
        $null = $dlFailed.Add($s.Name)
    }
}

# ================================================================= 4. 経路
if (-not $SkipTrace) {
    Write-Head "4. 経路 (どこで遅くなっているか)"
    $traceTarget = '1.1.1.1'
    if ($v4Results.Count -ge 1) {
        $traceTarget = ($v4Results | Sort-Object Avg -Descending | Select-Object -First 1).Ip
    }
    Write-Info "いちばん遅い相手 ($traceTarget) までの経路を表示します。30秒ほどかかります。"
    Write-Info "自分のルーター (192.168.x.1) の次のホップから急に遅くなっていれば、ISP 側です。"
    Write-Host ""
    try {
        & tracert -d -h 12 -w 800 $traceTarget 2>$null | ForEach-Object { Write-Host "         $_" }
    } catch {
        Write-Info "tracert を実行できませんでした。"
    }
}

# ================================================================= 5. 判定
Write-Head "5. 判定"

$allSlow = $false
$mixed   = $false
if ($dlResults.Count -ge 2) {
    $best  = ($dlResults | Sort-Object Mbps -Descending | Select-Object -First 1)
    $worst = ($dlResults | Sort-Object Mbps | Select-Object -First 1)
    if ($best.Mbps -lt 30) { $allSlow = $true }
    elseif ($best.Mbps -gt ($worst.Mbps * 3)) { $mixed = $true }
}

if ($allSlow) {
    Write-Bad "どのダウンロード元でも速度が出ていません。回線全体が遅い状態です。"
    Write-Host ""
    Write-Info "考えられる原因を、確認しやすい順に挙げます。"
    Write-Info ""
    Write-Info "  1. 宅内の他の端末が帯域を使い切っている"
    Write-Info "     (ゲーム機のダウンロード、クラウドバックアップ、動画配信など)"
    Write-Info "     → ルーターの管理画面で接続端末ごとの通信量を確認してください。"
    Write-Info ""
    Write-Info "  2. IPv4 が PPPoE のまま輻輳している"
    Write-Info "     → 上の 2 で IPv6 の方が速いと出ていれば、これが原因です。"
    Write-Info "     → ルーターの管理画面で接続方式を確認し、IPoE (v6プラス / MAP-E /"
    Write-Info "        DS-Lite / transix 等) に対応していれば有効化してください。"
    Write-Info ""
    Write-Info "  3. ルーターの性能不足または不調"
    Write-Info "     → まずルーターを再起動してください。それで直るなら熱か処理落ちです。"
    Write-Info ""
    Write-Info "  4. ISP 側の輻輳 (この時間帯だけ遅い)"
    Write-Info "     → 昼間にもう一度このスクリプトを実行して比較してください。"
} elseif ($mixed) {
    Write-Bad "ダウンロード元によって速度が大きく違います ($($worst.Name) が遅く、$($best.Name) は出ています)。"
    Write-Info "回線そのものは生きていて、特定の相手までの経路 (ピアリング) が詰まっています。"
    Write-Host ""
    Write-Info "  → ISP と特定 CDN の間の混雑なので、宅内では直せません。"
    Write-Info "  → IPoE (v6プラス等) に切り替えると経路が変わり、改善することがあります。"
    Write-Info "  → 昼夜で差が出るかを確認すると、輻輳かどうかが確定します。"
} elseif ($routeIssue) {
    Write-Warn "速度は出ていますが、特定の相手へのレイテンシだけが悪化しています。"
    Write-Info "  → その相手までの経路の問題です。日常利用への影響は限定的です。"
} elseif ($dlResults.Count -ge 2) {
    Write-Ok "計測できたダウンロード元では十分な速度が出ています。"
} elseif ($dlResults.Count -eq 1) {
    Write-Warn "1 ソースしか計測できませんでした ($($dlResults[0].Name): $($dlResults[0].Mbps) Mbps)。"
    Write-Info "比較対象が無いため、経路固有の問題かどうかは判定できません。時間をおいて再実行してください。"
} else {
    Write-Warn "ダウンロード計測ができませんでした。ネットワークが不安定な可能性があります。"
}

if ($dlFailed.Count -gt 0 -and $dlResults.Count -gt 0) {
    Write-Host ""
    Write-Warn "$($dlFailed -join ' / ') にはそもそも接続できませんでした。"
    Write-Info "他のソースは取得できているので、回線ではなくその相手への経路だけが"
    Write-Info "遮断されているか、極端に劣化しています。ブラウザで直接開けるか確認してください。"
}

if (($dlResults | Where-Object { -not $_.Steady }).Count -gt 0) {
    Write-Host ""
    Write-Warn "転送が短時間で終わったソースがあります。表示された速度は実力より低い値です。"
    Write-Info "正確に測るには上限を上げてください:  -CapMB 200 -CapSeconds 30"
}

if ($v6Better) {
    Write-Host ""
    Write-Bad "最も重要: IPv6 の方が明確に速い、という結果が出ています。"
    Write-Info "IPv4 通信だけが混雑した PPPoE 経路を通っている可能性が非常に高いです。"
    Write-Info "ルーターの管理画面で接続方式を確認し、IPv4 over IPv6 (IPoE) を"
    Write-Info "有効にできれば、それが今回いちばん効く対策です。"
}
Write-Host ""
