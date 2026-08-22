<#
    netcheck.ps1 - 手元の Windows PC のネット環境を実測して、
                   どこがボトルネックなのかと、何をすれば速くなるのかを出す。

    使い方:
        powershell -ExecutionPolicy Bypass -File tools\netcheck.ps1

    Windows PowerShell 5.1 / PowerShell 7 の両方で動きます。管理者権限は不要です。
    外部に出るのは速度計測 (Cloudflare) とグローバル IP 確認だけで、
    -NoPublic を付ければグローバル IP の確認は行いません。
#>

[CmdletBinding()]
param(
    [switch]$NoPublic,
    [int]$SpeedTestMB = 25
)

$ErrorActionPreference = 'Continue'
$ProgressPreference    = 'SilentlyContinue'

# ----------------------------------------------------------------- 表示ヘルパ
function Write-Head($t) { Write-Host ""; Write-Host "== $t ==" -ForegroundColor Cyan }
function Write-Ok($t)   { Write-Host "  [OK]   " -ForegroundColor Green  -NoNewline; Write-Host $t }
function Write-Warn($t) { Write-Host "  [注意] " -ForegroundColor Yellow -NoNewline; Write-Host $t }
function Write-Bad($t)  { Write-Host "  [問題] " -ForegroundColor Red    -NoNewline; Write-Host $t }
function Write-Info($t) { Write-Host "         $t" }

$script:Recs = New-Object System.Collections.ArrayList
function Add-Rec([int]$Priority, [string]$Text) {
    $null = $script:Recs.Add([PSCustomObject]@{ Priority = $Priority; Text = $Text })
}

Write-Host ""
Write-Host "netcheck  -  $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')" -ForegroundColor White
Write-Host "PowerShell $($PSVersionTable.PSVersion)  /  $([System.Environment]::OSVersion.VersionString)"

# ----------------------------------------------------------------- 判定ロジック
# IP アドレスの種別を返す (テストしやすいよう純粋な関数にしてある)
function Get-AddressKind([string]$ip) {
    if ([string]::IsNullOrWhiteSpace($ip)) { return 'none' }
    $a = $null
    if (-not [System.Net.IPAddress]::TryParse($ip, [ref]$a)) { return 'unknown' }
    if ($a.AddressFamily -ne [System.Net.Sockets.AddressFamily]::InterNetwork) { return 'unknown' }
    $o = $a.GetAddressBytes()
    if ($o[0] -eq 10)                                  { return 'private' }
    if ($o[0] -eq 192 -and $o[1] -eq 168)              { return 'private' }
    if ($o[0] -eq 172 -and $o[1] -ge 16 -and $o[1] -le 31) { return 'private' }
    if ($o[0] -eq 100 -and $o[1] -ge 64 -and $o[1] -le 127) { return 'cgnat' }
    if ($o[0] -eq 169 -and $o[1] -eq 254)              { return 'linklocal' }
    if ($o[0] -eq 127)                                 { return 'loopback' }
    return 'public'
}

# アダプタの説明文から VPN / 仮想アダプタらしさを判定する
function Test-VirtualAdapter([string]$desc, [string]$name) {
    $s = "$desc $name"
    return ($s -match 'VPN|TAP-|TAP\b|WireGuard|OpenVPN|Tailscale|ZeroTier|AnyConnect|FortiClient|Pulse|GlobalProtect|SoftEther|Hyper-V|vEthernet|VirtualBox|VMware|Loopback|WAN Miniport')
}

# Wi-Fi のチャネル番号と帯域表記から周波数帯を決める
function Resolve-WifiBand([string]$bandText, [int]$channel) {
    if ($bandText -match '6\s*GHz') { return '6GHz' }
    if ($bandText -match '5\s*GHz') { return '5GHz' }
    if ($bandText -match '2\.4\s*GHz') { return '2.4GHz' }
    if ($channel -ge 1 -and $channel -le 14)   { return '2.4GHz' }
    if ($channel -ge 32 -and $channel -le 177) { return '5GHz' }
    return 'unknown'
}

# Windows のシグナル品質 (%) を dBm におおよそ換算する
function ConvertTo-Dbm([int]$qualityPercent) {
    return [math]::Round(($qualityPercent / 2.0) - 100, 0)
}

# ----------------------------------------------------------------- 計測ヘルパ
function Measure-Latency([string]$Target, [int]$Count = 8, [int]$TimeoutMs = 1500) {
    $ping  = New-Object System.Net.NetworkInformation.Ping
    $times = New-Object System.Collections.ArrayList
    $lost  = 0
    for ($i = 0; $i -lt $Count; $i++) {
        try {
            $r = $ping.Send($Target, $TimeoutMs)
            if ($r.Status -eq [System.Net.NetworkInformation.IPStatus]::Success) {
                $null = $times.Add([double]$r.RoundtripTime)
            } else { $lost++ }
        } catch { $lost++ }
        Start-Sleep -Milliseconds 120
    }
    $ping.Dispose()
    if ($times.Count -eq 0) {
        return [PSCustomObject]@{ Ok = $false; Avg = $null; Min = $null; Max = $null; Jitter = $null; LossPct = 100 }
    }
    $arr = $times.ToArray()
    $avg = ($arr | Measure-Object -Average).Average
    # ジッター = 連続するパケット間の変動の平均
    $jit = 0.0
    if ($arr.Count -gt 1) {
        $d = 0.0
        for ($i = 1; $i -lt $arr.Count; $i++) { $d += [math]::Abs($arr[$i] - $arr[$i-1]) }
        $jit = $d / ($arr.Count - 1)
    }
    return [PSCustomObject]@{
        Ok      = $true
        Avg     = [math]::Round($avg, 1)
        Min     = [math]::Round(($arr | Measure-Object -Minimum).Minimum, 1)
        Max     = [math]::Round(($arr | Measure-Object -Maximum).Maximum, 1)
        Jitter  = [math]::Round($jit, 1)
        LossPct = [math]::Round(100.0 * $lost / $Count, 0)
    }
}

# DNS サーバに直接 UDP でクエリを投げて応答時間を測る (言語・OS 非依存)
function Measure-Dns([string]$Server, [int]$Tries = 3) {
    $best = $null
    for ($t = 0; $t -lt $Tries; $t++) {
        # キャッシュに当たらないようランダムなホスト名を使う
        $label = -join ((1..12) | ForEach-Object { [char](Get-Random -Minimum 97 -Maximum 123) })
        $fqdn  = "$label.example.com"
        $id    = Get-Random -Minimum 1 -Maximum 65534
        $pkt   = New-Object System.Collections.Generic.List[byte]
        $pkt.Add([byte](($id -shr 8) -band 0xFF)); $pkt.Add([byte]($id -band 0xFF))
        foreach ($b in @(0x01,0x00, 0x00,0x01, 0x00,0x00, 0x00,0x00, 0x00,0x00)) { $pkt.Add([byte]$b) }
        foreach ($part in $fqdn.Split('.')) {
            $pkt.Add([byte]$part.Length)
            foreach ($b in [System.Text.Encoding]::ASCII.GetBytes($part)) { $pkt.Add($b) }
        }
        foreach ($b in @(0x00, 0x00,0x01, 0x00,0x01)) { $pkt.Add([byte]$b) }

        $udp = $null
        try {
            $udp = New-Object System.Net.Sockets.UdpClient
            $udp.Client.ReceiveTimeout = 2000
            $udp.Connect($Server, 53)
            $sw = [System.Diagnostics.Stopwatch]::StartNew()
            $null = $udp.Send($pkt.ToArray(), $pkt.Count)
            $ep = New-Object System.Net.IPEndPoint([System.Net.IPAddress]::Any, 0)
            $null = $udp.Receive([ref]$ep)
            $sw.Stop()
            $ms = $sw.Elapsed.TotalMilliseconds
            if ($null -eq $best -or $ms -lt $best) { $best = $ms }
        } catch {
        } finally {
            if ($udp) { $udp.Close() }
        }
    }
    if ($null -eq $best) { return $null }
    return [math]::Round($best, 0)
}

# ダウンロードしながら同時に ping を打ち、負荷時のレイテンシ (バッファブロート) も測る
function Measure-Download([int]$Megabytes, [string]$PingTarget, [string]$Url) {
    $bytes = $Megabytes * 1000000
    if (-not $Url) { $Url = "https://speed.cloudflare.com/__down?bytes=$bytes" }
    try { Add-Type -AssemblyName System.Net.Http -ErrorAction SilentlyContinue } catch {}

    $handler = $null; $client = $null; $stream = $null
    $loaded  = New-Object System.Collections.ArrayList
    try {
        $handler = New-Object System.Net.Http.HttpClientHandler
        try { $handler.UseProxy = $true } catch {}
        $client = New-Object System.Net.Http.HttpClient($handler)
        $client.Timeout = [TimeSpan]::FromSeconds(90)
        $stream = $client.GetStreamAsync($Url).GetAwaiter().GetResult()

        $ping   = New-Object System.Net.NetworkInformation.Ping
        $buf    = New-Object byte[] 131072
        $total  = 0L
        $sw     = [System.Diagnostics.Stopwatch]::StartNew()
        $lastPing = 700   # 最初の 0.7 秒は回線が立ち上がるまで待つ
        # ICMP がブロックされている環境では ping が毎回タイムアウトし、
        # その待ち時間がダウンロード計測そのものを歪めてしまう。
        # 続けて失敗したら以降の ping はあきらめる。
        $pingFails = 0

        while ($true) {
            $n = $stream.Read($buf, 0, $buf.Length)
            if ($n -le 0) { break }
            $total += $n
            if ($PingTarget -and $pingFails -lt 2 -and $sw.ElapsedMilliseconds -gt $lastPing) {
                $lastPing = $sw.ElapsedMilliseconds + 400
                try {
                    $r = $ping.Send($PingTarget, 1000)
                    if ($r.Status -eq [System.Net.NetworkInformation.IPStatus]::Success) {
                        $null = $loaded.Add([double]$r.RoundtripTime)
                        $pingFails = 0
                    } else { $pingFails++ }
                } catch { $pingFails++ }
            }
            if ($sw.Elapsed.TotalSeconds -gt 60) { break }
        }
        $sw.Stop()
        $ping.Dispose()

        if ($total -lt 100000 -or $sw.Elapsed.TotalSeconds -le 0) { return $null }
        $mbps = ($total * 8.0) / $sw.Elapsed.TotalSeconds / 1000000.0
        $loadedAvg = $null
        if ($loaded.Count -gt 0) {
            $loadedAvg = [math]::Round((($loaded.ToArray()) | Measure-Object -Average).Average, 1)
        }
        return [PSCustomObject]@{
            Mbps        = [math]::Round($mbps, 1)
            Seconds     = [math]::Round($sw.Elapsed.TotalSeconds, 1)
            MB          = [math]::Round($total / 1000000.0, 1)
            LoadedMs    = $loadedAvg
            LoadedCount = $loaded.Count
        }
    } catch {
        return $null
    } finally {
        if ($stream) { $stream.Dispose() }
        if ($client) { $client.Dispose() }
        if ($handler) { $handler.Dispose() }
    }
}

# ================================================================= 1. 経路
Write-Head "1. いま何を通って外に出ているか"

$gw = $null; $ifIndex = $null; $localIp = $null; $adapter = $null
try {
    # Windows が実際に外向き通信で選ぶ経路をそのまま聞く
    $fnr = Find-NetRoute -RemoteIPAddress '1.1.1.1' -ErrorAction Stop
    $r   = $fnr | Where-Object { $_.NextHop } | Select-Object -First 1
    $a   = $fnr | Where-Object { $_.IPAddress } | Select-Object -First 1
    if ($r) { $gw = $r.NextHop; $ifIndex = $r.InterfaceIndex }
    if ($a) { $localIp = $a.IPAddress }
} catch {
    try {
        $cfg = Get-NetIPConfiguration -ErrorAction Stop |
               Where-Object { $_.IPv4DefaultGateway } | Select-Object -First 1
        if ($cfg) {
            $gw      = ($cfg.IPv4DefaultGateway | Select-Object -First 1).NextHop
            $ifIndex = $cfg.InterfaceIndex
            $localIp = ($cfg.IPv4Address | Select-Object -First 1).IPAddress
        }
    } catch {}
}

if (-not $gw -or $gw -eq '0.0.0.0') {
    Write-Bad "デフォルトゲートウェイが見つかりません。オフラインか、この環境は Windows ではありません。"
    Write-Info "Windows 上で実行してください:  powershell -ExecutionPolicy Bypass -File tools\netcheck.ps1"
    exit 1
}

try { $adapter = Get-NetAdapter -InterfaceIndex $ifIndex -ErrorAction Stop } catch {}

$adName  = if ($adapter) { $adapter.Name } else { "ifIndex $ifIndex" }
$adDesc  = if ($adapter) { $adapter.InterfaceDescription } else { '' }
$adSpeed = if ($adapter) { $adapter.LinkSpeed } else { '' }
$isWifi  = $false
if ($adapter -and ($adapter.PhysicalMediaType -match '802\.11' -or $adDesc -match 'Wireless|Wi-?Fi|WLAN')) { $isWifi = $true }
$isVirtual = Test-VirtualAdapter $adDesc $adName

Write-Info "アダプタ     : $adName"
if ($adDesc)  { Write-Info "               $adDesc" }
if ($adSpeed) { Write-Info "リンク速度   : $adSpeed" }
Write-Info "自分の IP    : $localIp"
Write-Info "ゲートウェイ : $gw"

$gwKind = Get-AddressKind $gw
if ($isVirtual) { $gwKind = 'vpn' }

switch ($gwKind) {
    'private' {
        Write-Ok "ルーター ($gw) を経由しています。ご希望どおりの状態です。"
    }
    'cgnat' {
        Write-Warn "ゲートウェイ $gw はキャリアグレード NAT (CGNAT) の帯域です。"
        Write-Info "スマホのテザリングか、モバイル回線に直結している可能性が高いです。"
        Add-Rec 1 "テザリング / モバイル直結をやめ、ルーターの Wi-Fi か有線 LAN に接続し直してください。CGNAT 配下は遅延が大きく不安定で、ポート開放もできません。"
    }
    'vpn' {
        Write-Warn "通信が VPN / 仮想アダプタ ($adName) を経由しています。"
        Add-Rec 2 "速度を最優先するなら VPN を一時的に切ってください。VPN は暗号化と経路の遠回りの分、実効速度とレイテンシを必ず悪化させます。"
    }
    'public' {
        Write-Warn "ゲートウェイ $gw がグローバル IP です。ルーターを挟まず ONU / モデムに直結しています。"
        Add-Rec 1 "ONU に直結せず、間にルーターを入れてください。速度面の利点はほぼ無く、PC が直接インターネットに晒されるためセキュリティ上も危険です。"
    }
    'linklocal' {
        Write-Bad "リンクローカルアドレス ($gw) です。DHCP からアドレスを取得できていません。"
        Add-Rec 1 "DHCP でアドレスを取得できていません。ルーターを再起動するか、LAN ケーブル / Wi-Fi の接続を確認してください。"
    }
    default {
        Write-Warn "ゲートウェイの種別を判定できませんでした ($gw)。"
    }
}

# --- 他に使える経路があるか (ルーター経由に切り替えたい場合の候補)
try {
    $others = @(Get-NetIPConfiguration -ErrorAction Stop | Where-Object {
        $_.IPv4DefaultGateway -and $_.InterfaceIndex -ne $ifIndex
    })
    if ($others.Count -gt 0) {
        Write-Info ""
        Write-Info "他にゲートウェイを持つアダプタ:"
        foreach ($o in $others) {
            $og   = ($o.IPv4DefaultGateway | Select-Object -First 1).NextHop
            $kind = Get-AddressKind $og
            $mark = if ($kind -eq 'private') { ' <- ルーター配下' } else { '' }
            Write-Info ("  - {0,-28} GW {1,-16} [{2}]{3}" -f $o.InterfaceAlias, $og, $kind, $mark)
        }
        if ($gwKind -ne 'private' -and ($others | Where-Object { (Get-AddressKind ($_.IPv4DefaultGateway | Select-Object -First 1).NextHop) -eq 'private' })) {
            Add-Rec 1 "ルーター配下の別アダプタが既に使える状態です。今の経路より優先されるよう、使わないアダプタを無効化するか、そのアダプタのインターフェイスメトリックを下げてください。"
        }
    }
} catch {}

# --- 二重 NAT の確認
if (-not $NoPublic) {
    try {
        $pub = (Invoke-RestMethod -Uri 'https://api.ipify.org' -TimeoutSec 8 -ErrorAction Stop).ToString().Trim()
        if ($pub) {
            Write-Info "グローバル IP: $pub"
            $pk = Get-AddressKind $pub
            if ($pk -eq 'private' -or $pk -eq 'cgnat') {
                Write-Bad "グローバル IP が $pk 帯域です = 二重 NAT になっています。"
                Add-Rec 2 "二重 NAT です。ルーターが 2 台直列になっているか、ISP 側が CGNAT です。手前の機器をブリッジ (AP) モードにするか、ISP にグローバル IP の付与状況を確認してください。"
            }
        }
    } catch {}
}

# ================================================================= 2. Wi-Fi
Write-Head "2. Wi-Fi の品質"

$wifiBand = 'unknown'
if ($isWifi) {
    $raw = $null
    try { $raw = & netsh wlan show interfaces 2>$null } catch {}
    if ($raw) {
        $kv = @{}
        foreach ($line in $raw) {
            if ($line -match '^\s*([^:]+?)\s*:\s*(.+?)\s*$') { $kv[$Matches[1].Trim()] = $Matches[2].Trim() }
        }
        function Get-Kv([string]$pattern) {
            foreach ($k in $kv.Keys) { if ($k -match $pattern) { return $kv[$k] } }
            return $null
        }
        # netsh の表示は OS の言語で変わるため、日本語 / 英語の両方に当てる
        $ssid  = Get-Kv '^SSID$'
        $radio = Get-Kv '無線の種類|Radio type'
        $chTxt = Get-Kv '^チャネル$|^Channel$'
        $sigTx = Get-Kv 'シグナル|^Signal$'
        $rxTxt = Get-Kv '受信速度|Receive rate'
        $bnTxt = Get-Kv '^帯域$|^Band$'
        $auth  = Get-Kv '^認証$|^Authentication$'

        $ch = 0; if ($chTxt -match '(\d+)') { $ch = [int]$Matches[1] }
        $wifiBand = Resolve-WifiBand $bnTxt $ch

        Write-Info "SSID       : $ssid"
        Write-Info "規格       : $radio    暗号: $auth"
        Write-Info "チャネル   : $chTxt  ($wifiBand)"
        Write-Info "シグナル   : $sigTx"
        Write-Info "受信速度   : $rxTxt Mbps"

        if ($wifiBand -eq '2.4GHz') {
            Write-Warn "2.4GHz 帯 (ch $ch) に接続しています。ここが今いちばん大きなボトルネックです。"
            Add-Rec 2 "Wi-Fi を 5GHz または 6GHz の SSID に切り替えてください。2.4GHz は電子レンジ・Bluetooth・近隣の AP と干渉し、実効 100Mbps 前後で頭打ちになります。"
        } elseif ($wifiBand -ne 'unknown') {
            Write-Ok "$wifiBand 帯 (ch $ch) を使えています。"
        }

        if ($radio -match '802\.11(be|ax)') {
            Write-Ok "Wi-Fi 6 以降 ($radio) で接続できています。"
        } elseif ($radio -match '802\.11ac') {
            Write-Info "Wi-Fi 5 (802.11ac) です。PC とルーターが Wi-Fi 6 対応ならそちらの方が速くなります。"
        } elseif ($radio -match '802\.11[abgn]') {
            Write-Warn "古い規格 ($radio) で接続しています。"
            Add-Rec 2 "Wi-Fi の規格が $radio と古いです。ルーターが Wi-Fi 6 対応か確認し、対応していれば 5/6GHz の SSID に繋ぎ直してください。非対応ならルーター買い替えが最も効果的です。"
        }

        if ($sigTx -match '(\d+)\s*%') {
            $q   = [int]$Matches[1]
            $dbm = ConvertTo-Dbm $q
            if ($q -lt 45) {
                Write-Bad "電波が弱すぎます ($q% / 約 $dbm dBm)。"
                Add-Rec 2 "電波強度が $q% (約 $dbm dBm) しかありません。ルーターに近づく、間の壁を減らす、メッシュ中継機を足す、のいずれかが必要です。-67 dBm (約 66%) 以上を目安にしてください。"
            } elseif ($q -lt 66) {
                Write-Warn "電波がやや弱いです ($q% / 約 $dbm dBm)。"
                Add-Rec 3 "電波強度 $q% (約 $dbm dBm) はやや弱いです。ルーターとの距離や遮蔽物を見直すと実効速度が上がります。"
            } else {
                Write-Ok "電波強度は十分です ($q% / 約 $dbm dBm)。"
            }
        }

        Add-Rec 4 "最速を狙うなら、可能な限り LAN ケーブルでルーターに有線接続してください。Wi-Fi のどんなチューニングよりも確実で、レイテンシとジッターが目に見えて改善します。"
    } else {
        Write-Info "netsh から Wi-Fi 情報を取得できませんでした。"
    }
} else {
    if ($adapter -and $adapter.PhysicalMediaType -match '802\.3') {
        Write-Ok "有線 Ethernet です。速度・安定性の面ではこれが最善です。"
        if ($adSpeed -match '^\s*(\d+(?:\.\d+)?)\s*(M|G)bps') {
            $v = [double]$Matches[1]; $u = $Matches[2]
            $mbps = if ($u -eq 'G') { $v * 1000 } else { $v }
            if ($mbps -le 100) {
                Write-Warn "リンク速度が $adSpeed です。ここで頭打ちになります。"
                Add-Rec 2 "有線のリンク速度が $adSpeed しかありません。LAN ケーブルが CAT5e 未満か、ハブ / ルーターのポートが 100Mbps です。CAT5e 以上のケーブルとギガビット対応ポートに変えてください。"
            }
        }
    } else {
        Write-Info "Wi-Fi アダプタではないため、この項目はスキップします。"
    }
}

# ================================================================= 3. レイテンシ
Write-Head "3. レイテンシとパケットロス"

$gwStat = Measure-Latency -Target $gw -Count 8
if ($gwStat.Ok) {
    Write-Info ("ゲートウェイ   {0,-16} 平均 {1,6} ms  ジッター {2,5} ms  ロス {3}%" -f $gw, $gwStat.Avg, $gwStat.Jitter, $gwStat.LossPct)
} else {
    Write-Info "ゲートウェイまで ($gw) 応答なし (ICMP がブロックされている可能性があります)"
}

$netStat = Measure-Latency -Target '1.1.1.1' -Count 8
if ($netStat.Ok) {
    Write-Info ("インターネット {0,-16} 平均 {1,6} ms  ジッター {2,5} ms  ロス {3}%" -f '1.1.1.1', $netStat.Avg, $netStat.Jitter, $netStat.LossPct)
} else {
    Write-Bad "インターネット (1.1.1.1) に到達できません。"
}

if ($gwStat.Ok -and $gwKind -eq 'private') {
    # 相手が本物の宅内ルーターのときだけ、宅内区間の切り分けに使える
    if ($gwStat.Avg -gt 20) {
        Write-Bad "ルーターまでの往復が $($gwStat.Avg) ms もあります。原因は宅内 (Wi-Fi 区間) です。"
        Add-Rec 1 "ルーターまでの ping が $($gwStat.Avg) ms と遅すぎます (有線なら 1ms 未満、良好な Wi-Fi で 5ms 以下)。回線契約ではなく宅内 Wi-Fi がボトルネックなので、有線化か 5GHz への移行を最優先で行ってください。"
    } elseif ($gwStat.Avg -gt 5) {
        Write-Warn "ルーターまで $($gwStat.Avg) ms。Wi-Fi 区間にやや無駄があります。"
    } else {
        Write-Ok "ルーターまで $($gwStat.Avg) ms。宅内は良好です。"
    }
} elseif ($gwStat.Ok) {
    Write-Info "(このゲートウェイは宅内ルーターではないため、宅内区間の切り分けには使えません)"
}

# 宅内 (自分〜ルーター) が健全かどうか。
# ここが健全なら、外向きの不調の原因は宅内ではなく回線側だと言い切れる。
$lanClean = ($gwStat.Ok -and $gwKind -eq 'private' -and $gwStat.Avg -le 5 -and $gwStat.LossPct -eq 0)

if ($netStat.Ok) {
    if ($netStat.Avg -gt 50) {
        Write-Warn "インターネットまで $($netStat.Avg) ms。やや遅いです。"
        if ($lanClean) {
            Add-Rec 2 "外向きレイテンシが $($netStat.Avg) ms あります。宅内 (ルーターまで $($gwStat.Avg) ms) は正常なので、原因は回線側で確定です。ISP の輻輳か、その宛先までの経路が悪化しています。"
        } else {
            Add-Rec 3 "外向きレイテンシが $($netStat.Avg) ms あります。VPN やプロキシを切り、それでも改善しないなら ISP 側 (特に PPPoE の輻輳) を疑ってください。"
        }
    } else {
        Write-Ok "インターネットまで $($netStat.Avg) ms。"
    }
    if ($netStat.LossPct -gt 0) {
        Write-Bad "パケットロスが $($netStat.LossPct)% 発生しています。"
        Add-Rec 1 "パケットロス $($netStat.LossPct)% は速度以前の問題です。Wi-Fi の電波状況、LAN ケーブルの劣化、ルーターの過熱や再起動を順に確認してください。"
    }
    if ($netStat.Jitter -gt 30) {
        Write-Warn "ジッターが $($netStat.Jitter) ms と大きく、通話やビデオ会議が乱れやすい状態です。"
        if ($lanClean) {
            Add-Rec 2 "ジッター $($netStat.Jitter) ms は大きすぎます。ただし宅内 (ルーターまで $($gwStat.Avg) ms / ロス 0%) は正常なので、原因は宅内ではなく回線側です。宅内をいじっても直りません。"
        } elseif ($isWifi) {
            Add-Rec 3 "ジッター $($netStat.Jitter) ms は大きすぎます。Wi-Fi の干渉が原因の可能性が高いので、有線化を試してください。"
        } else {
            Add-Rec 3 "ジッター $($netStat.Jitter) ms は大きすぎます。ルーターの処理能力不足か回線側の問題です。"
        }
    }
}

# ================================================================= 4. DNS
Write-Head "4. DNS (体感速度に効きます)"

$curDns = $null
try {
    $curDns = (Get-DnsClientServerAddress -InterfaceIndex $ifIndex -AddressFamily IPv4 -ErrorAction Stop).ServerAddresses |
              Select-Object -First 1
} catch {}
Write-Info "現在の DNS: $(if ($curDns) { $curDns } else { '取得できず' })"

$candidates = New-Object System.Collections.ArrayList
if ($curDns) { $null = $candidates.Add([PSCustomObject]@{ Ip = $curDns;   Name = '現在の DNS' }) }
foreach ($c in @(
    @{ Ip = '1.1.1.1'; Name = 'Cloudflare' },
    @{ Ip = '8.8.8.8'; Name = 'Google'     },
    @{ Ip = '9.9.9.9'; Name = 'Quad9'      })) {
    if ($c.Ip -ne $curDns) { $null = $candidates.Add([PSCustomObject]@{ Ip = $c.Ip; Name = $c.Name }) }
}

$dnsResults = New-Object System.Collections.ArrayList
foreach ($c in $candidates) {
    $ms = Measure-Dns $c.Ip
    if ($null -ne $ms) {
        Write-Info ("{0,-16} {1,6} ms   {2}" -f $c.Ip, $ms, $c.Name)
        $null = $dnsResults.Add([PSCustomObject]@{ Ip = $c.Ip; Name = $c.Name; Ms = $ms })
    } else {
        Write-Info ("{0,-16} {1,6}       {2}" -f $c.Ip, '応答なし', $c.Name)
    }
}

if ($dnsResults.Count -gt 1 -and $curDns) {
    $cur  = $dnsResults | Where-Object { $_.Ip -eq $curDns } | Select-Object -First 1
    $best = $dnsResults | Sort-Object Ms | Select-Object -First 1
    if ($cur -and $best -and $best.Ip -ne $curDns -and ($cur.Ms - $best.Ms) -gt 10) {
        Write-Warn "現在の DNS ($curDns / $($cur.Ms)ms) より $($best.Ip) ($($best.Ms)ms) の方が速いです。"
        Add-Rec 4 "DNS を $($best.Ip) ($($best.Name)) に変更すると、1 ページあたり数十 ms 短縮できます。PC ごとに設定するより、ルーターの DHCP 設定で配ると家じゅうの端末に一度で効きます。"
    } else {
        Write-Ok "DNS の応答速度は妥当です。"
    }

    # 公開リゾルバ同士で大きく差が出るのは DNS の優劣ではなく、
    # 特定の宛先への経路だけが悪化しているサインになる
    $pub = @($dnsResults | Where-Object { $_.Ip -ne $curDns })
    if ($pub.Count -ge 2) {
        $fast = ($pub | Sort-Object Ms | Select-Object -First 1)
        $slow = ($pub | Sort-Object Ms -Descending | Select-Object -First 1)
        if (($slow.Ms - $fast.Ms) -gt 50) {
            Write-Warn "公開 DNS 間で応答時間の差が大きすぎます ($($fast.Ip) $($fast.Ms)ms / $($slow.Ip) $($slow.Ms)ms)。"
            Add-Rec 2 "$($slow.Ip) だけが $($slow.Ms) ms と極端に遅く、$($fast.Ip) は $($fast.Ms) ms で届いています。回線全体ではなく $($slow.Ip) 方向の経路だけが悪化している可能性が高いです。netcheck-wan.ps1 で宛先ごとに切り分けてください。"
        }
    }
}

# ================================================================= 5. 速度
Write-Head "5. 実効スループットと負荷時のレイテンシ"

Write-Info "Cloudflare から ${SpeedTestMB}MB ダウンロードしながら ping を打ちます (最大 60 秒)..."
$pingOkTarget = ''
if ($netStat.Ok) { $pingOkTarget = '1.1.1.1' }
$dl = Measure-Download -Megabytes $SpeedTestMB -PingTarget $pingOkTarget
if ($dl) {
    Write-Info ("下り速度       : {0} Mbps  ({1}MB / {2}秒)" -f $dl.Mbps, $dl.MB, $dl.Seconds)
    if ($dl.LoadedMs -and $netStat.Ok) {
        $bloat = [math]::Round($dl.LoadedMs - $netStat.Avg, 1)
        $sign = ''
        if ($bloat -ge 0) { $sign = '+' }
        Write-Info ("負荷時レイテンシ: {0} ms  (アイドル時 {1} ms / 変化 {2}{3} ms)" -f $dl.LoadedMs, $netStat.Avg, $sign, $bloat)
        if ($bloat -gt 200) {
            Write-Bad "ダウンロード中にレイテンシが $sign$bloat ms 悪化しています。重度のバッファブロートです。"
            Add-Rec 2 "バッファブロートが深刻です (負荷時に +$bloat ms)。誰かが大きなダウンロードをすると、家じゅうの通信がカクつきます。ルーターの QoS / SQM を有効にしてください。回線速度はそのままで体感が劇的に改善します。非対応ルーターなら、これが買い替えの一番の理由です。"
        } elseif ($bloat -gt 60) {
            Write-Warn "ダウンロード中にレイテンシが $sign$bloat ms 悪化しています (バッファブロート)。"
            Add-Rec 3 "負荷時にレイテンシが +$bloat ms 悪化します。ルーターに QoS / SQM 設定があれば有効にしてください。"
        } else {
            Write-Ok "負荷をかけてもレイテンシは安定しています ($sign$bloat ms)。"
        }
    }
    if ($dl.Mbps -lt 30) {
        Write-Bad "下り $($dl.Mbps) Mbps しか出ていません。回線種別を問わず異常に遅い値です。"
        if ($lanClean) {
            Add-Rec 1 "下り $($dl.Mbps) Mbps は異常です。宅内 (ルーターまで $($gwStat.Avg) ms / ロス 0%) もリンク速度 ($adSpeed) も正常なので、PC や宅内 LAN の問題ではありません。回線側かこの宛先までの経路が原因です。netcheck-wan.ps1 で切り分けてください。"
        } else {
            Add-Rec 1 "下り $($dl.Mbps) Mbps は異常です。まず宅内 (Wi-Fi / ケーブル / ルーター) を確認してください。"
        }
    } elseif ($dl.Mbps -lt 100) {
        Write-Warn "下り $($dl.Mbps) Mbps。光回線であれば遅めです。"
        if ($isWifi) {
            Add-Rec 2 "下り $($dl.Mbps) Mbps は Wi-Fi 経由としても遅めです。5GHz 帯への切り替えか有線化で改善する可能性が高いです。"
        } else {
            Add-Rec 2 "下り $($dl.Mbps) Mbps は有線としては遅めです。回線側か経路の問題を疑ってください。"
        }
    } else {
        Write-Ok "下り $($dl.Mbps) Mbps 出ています。"
    }
} else {
    Write-Info "速度計測に失敗しました。https://speed.cloudflare.com で手動で測ってください。"
}

# ================================================================= 6. Windows 設定
Write-Head "6. Windows 側の設定"

try {
    $tcp = Get-NetTCPSetting -SettingName Internet -ErrorAction Stop
    $atl = $tcp.AutoTuningLevelLocal
    if ($atl -eq 'Normal') {
        Write-Ok "TCP 受信ウィンドウ自動チューニング: $atl (正常)"
    } else {
        Write-Warn "TCP 受信ウィンドウ自動チューニングが $atl になっています。"
        Add-Rec 2 "TCP 自動チューニングが $atl です。高速回線で速度が出ない典型的な原因です。管理者権限の PowerShell で次を実行してください:  netsh int tcp set global autotuninglevel=normal"
    }
} catch {}

# IPv6 が使えるか (日本では IPoE / v6プラス が使えているかの目安になる)
try {
    $v6 = @(Get-NetIPAddress -InterfaceIndex $ifIndex -AddressFamily IPv6 -ErrorAction Stop |
            Where-Object { $_.IPAddress -match '^[23]' })
    if ($v6.Count -gt 0) {
        Write-Ok "グローバル IPv6 アドレスあり ($($v6[0].IPAddress))。IPoE が使えている可能性が高いです。"
    } else {
        Write-Warn "グローバル IPv6 アドレスがありません。IPv4 (PPPoE) のみで接続している可能性が高いです。"
        Add-Rec 3 "IPv6 が使えていません。日本の光回線で『夜だけ遅い』原因はほぼ PPPoE の輻輳です。ISP の IPv6 IPoE (v6プラス / OCN バーチャルコネクト / transix 等) に申し込み、ルーターも IPoE 対応機種にすると、混雑時間帯の速度が数倍変わります。ここが今回いちばん効く可能性があります。"
    }
} catch {}

# ================================================================= 7. まとめ
Write-Head "7. やるべきこと (効果の大きい順)"

if ($script:Recs.Count -eq 0) {
    Write-Ok "目立った問題は見つかりませんでした。現状がほぼ最速です。"
    Write-Info "これ以上を求めるなら、回線契約そのもの (IPv6 IPoE / 10Gbps プラン) の見直しになります。"
} else {
    $i = 1
    foreach ($r in ($script:Recs | Sort-Object Priority)) {
        Write-Host ""
        Write-Host "  $i. " -ForegroundColor White -NoNewline
        Write-Host $r.Text
        $i++
    }
}
Write-Host ""
