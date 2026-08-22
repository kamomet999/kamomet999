# netcheck — ネット環境の実測・診断

手元のマシンのネットワークを実測して、**どこがボトルネックなのか**と
**何をすれば速くなるのか**を、効果の大きい順に出します。

| OS | 使うファイル |
|----|--------------|
| **Windows** | `netcheck.ps1` |
| macOS / Linux / WSL | `netcheck.sh` |

## Windows での使い方

### A. リポジトリをクローンしていない場合 (いちばん手軽)

PowerShell を開いて、そのまま貼り付けてください。

```powershell
cd $env:USERPROFILE\Downloads
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
Invoke-WebRequest -UseBasicParsing -OutFile netcheck.ps1 `
  -Uri "https://raw.githubusercontent.com/kamomet999/kamomet999/refs/heads/claude/fastest-network-setup-xhpuy1/tools/netcheck.ps1"
Unblock-File .\netcheck.ps1
powershell -ExecutionPolicy Bypass -File .\netcheck.ps1
```

`C:\Windows\System32` のままだと書き込めないので、`cd` を省略しないでください。

### B. リポジトリをクローンしている場合

```powershell
cd (クローン先のパス)
powershell -ExecutionPolicy Bypass -File tools\netcheck.ps1
```

どちらも管理者権限は不要です。Windows PowerShell 5.1 と PowerShell 7 の
どちらでも動きます。1〜2 分で終わります。

> `-File` に渡したパスが存在しないと
> 「`-File` パラメーターの引数 '...' は存在しません」というエラーになります。
> その場合は今いるフォルダが違うだけなので、A の手順を使ってください。

### オプション

```powershell
# グローバル IP の外部確認をしない (二重 NAT の判定は省略される)
powershell -ExecutionPolicy Bypass -File tools\netcheck.ps1 -NoPublic

# 速度計測のダウンロード量を変える (既定 25MB)
powershell -ExecutionPolicy Bypass -File tools\netcheck.ps1 -SpeedTestMB 100
```

## macOS / Linux / WSL での使い方

```bash
bash tools/netcheck.sh
```

## 何を見ているか

| # | 項目 | 判定できること |
|---|------|----------------|
| 1 | 経路 | **ルーター経由かどうか**、テザリング (CGNAT)、ONU 直結、VPN、二重 NAT、他に使えるアダプタ |
| 2 | Wi-Fi / 有線 | 2.4GHz か 5GHz 以上か、規格 (11n/ac/ax/be)、電波強度、有線のリンク速度 |
| 3 | ping | ゲートウェイまで / インターネットまでの遅延・ジッター・パケットロス |
| 4 | DNS | 現在の DNS と 1.1.1.1 / 8.8.8.8 / 9.9.9.9 の応答速度比較 |
| 5 | 速度 | 実効スループットと、**負荷をかけた時のレイテンシ悪化 (バッファブロート)** |
| 6 | Windows 設定 | TCP 受信ウィンドウ自動チューニング、グローバル IPv6 (IPoE) の有無 |
| 7 | まとめ | 上記から導いた対処を、効果の大きい順に列挙 |

## 切り分けの考え方

**ゲートウェイまでの ping と、インターネットまでの ping を分けて測っている**のが肝です。

- ゲートウェイまでが遅い → 原因は**宅内の Wi-Fi**。回線契約を変えても直りません。
- ゲートウェイまでは速いのに外が遅い → 原因は**回線・ISP 側**。Wi-Fi をいじっても無駄です。

もうひとつの肝が **5 のバッファブロート**です。「速度は出ているのに体感が遅い」の
正体はたいていこれで、回線速度ではなくルーターのキュー制御 (QoS / SQM) の問題です。
速度テストの数字だけ見ていると絶対に見つかりません。

## 外部への通信について

このスクリプトが外部に出すのは次の 2 つだけです。

- 速度計測: `speed.cloudflare.com` からデータをダウンロード
- 二重 NAT 判定: `api.ipify.org` でグローバル IP を確認 (`-NoPublic` / `--no-public` で無効化)

計測結果をどこかに送信することはありません。
