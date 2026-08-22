#!/usr/bin/env bash
#
# netcheck.sh - 手元のネット環境を実測して、最速化のための具体的な指示を出す
#
#   使い方:  bash tools/netcheck.sh
#
# 何もインストールせずに動きます (macOS / Linux)。
# 外部に投げるのは「グローバル IP の確認」だけで、これは --no-public で無効化できます。

LANG=C
CHECK_PUBLIC_IP=1
[ "$1" = "--no-public" ] && CHECK_PUBLIC_IP=0

OS="$(uname -s)"
RECOMMEND=()

bold()  { printf '\033[1m%s\033[0m\n' "$*"; }
head2() { printf '\n\033[1;36m== %s ==\033[0m\n' "$*"; }
ok()    { printf '  \033[32m[OK]\033[0m   %s\n' "$*"; }
warn()  { printf '  \033[33m[注意]\033[0m %s\n' "$*"; }
bad()   { printf '  \033[31m[問題]\033[0m %s\n' "$*"; }
info()  { printf '         %s\n' "$*"; }
rec()   { RECOMMEND+=("$*"); }

have()  { command -v "$1" >/dev/null 2>&1; }

PY=""
for c in python3 python; do have "$c" && { PY="$c"; break; }; done

bold "netcheck  —  $(date '+%Y-%m-%d %H:%M:%S')  on $OS"

# ---------------------------------------------------------------- 1. 経路
head2 "1. いま何を通って外に出ているか"

GW=""; IFACE=""; LOCAL_IP=""
if [ "$OS" = "Darwin" ]; then
    GW=$(route -n get default 2>/dev/null | awk '/gateway:/{print $2}')
    IFACE=$(route -n get default 2>/dev/null | awk '/interface:/{print $2}')
else
    GW=$(ip route show default 2>/dev/null | awk '/default/{print $3; exit}')
    IFACE=$(ip route show default 2>/dev/null | awk '/default/{print $5; exit}')
fi

if [ -z "$IFACE" ]; then
    bad "デフォルトルートがありません。オフラインです。"
    exit 1
fi

if [ "$OS" = "Darwin" ]; then
    LOCAL_IP=$(ipconfig getifaddr "$IFACE" 2>/dev/null)
else
    LOCAL_IP=$(ip -4 -br addr show "$IFACE" 2>/dev/null | awk '{print $3}' | cut -d/ -f1)
fi

# インターフェース名から接続の種類を推測する
MEDIA="不明"
case "$IFACE" in
    utun*|tun*|tap*|ppp*|ipsec*) MEDIA="VPN / トンネル" ;;
    en*|eth*|wl*)                MEDIA="物理NIC" ;;
    bridge*)                     MEDIA="ブリッジ" ;;
esac

SERVICE=""
if [ "$OS" = "Darwin" ] && have networksetup; then
    SERVICE=$(networksetup -listnetworkserviceorder 2>/dev/null \
        | awk -v i="$IFACE" '/^\(Hardware Port:/ { line=$0 }
             $0 ~ "Device: " i "\\)" { sub(/^\(Hardware Port: /,"",line); sub(/,.*$/,"",line); print line; exit }')
    [ -n "$SERVICE" ] && MEDIA="$SERVICE"
elif [ -d "/sys/class/net/$IFACE/wireless" ]; then
    MEDIA="Wi-Fi"
elif [ -e "/sys/class/net/$IFACE" ]; then
    MEDIA="有線 Ethernet"
fi

info "インターフェース : $IFACE  ($MEDIA)"
info "自分の IP        : ${LOCAL_IP:-取得できず}"
info "ゲートウェイ     : ${GW:-なし}"

# ---- ルーター経由かどうかの判定 (ここが今回の本題のひとつ)
GW_KIND="不明"
case "$GW" in
    192.168.*)  GW_KIND="private" ;;
    10.*)       GW_KIND="private" ;;
    172.1[6-9].*|172.2[0-9].*|172.3[01].*) GW_KIND="private" ;;
    100.6[4-9].*|100.[7-9][0-9].*|100.1[01][0-9].*|100.12[0-7].*) GW_KIND="cgnat" ;;
    "")         GW_KIND="none" ;;
    *)          GW_KIND="public" ;;
esac

case "$MEDIA" in *VPN*|*トンネル*) GW_KIND="vpn" ;; esac

case "$GW_KIND" in
  private)
    ok "ルーター ($GW) を経由しています。ご希望どおりの状態です。" ;;
  cgnat)
    warn "ゲートウェイが $GW = キャリアグレード NAT の帯域です。"
    info "スマホのテザリングか、ルーターを挟まずモバイル回線に直結している可能性が高いです。"
    rec "テザリングをやめ、自宅/事務所のルーターの Wi-Fi または有線に接続し直してください。CGNAT 配下は遅延が大きく、ポート開放もできません。" ;;
  public)
    warn "ゲートウェイ $GW がグローバル IP です。ルーターを挟まず ONU/モデムに直結しています。"
    rec "ONU に直結せず、間にルーターを入れてください。NAT/ファイアウォールが無い状態は速度面の利点がほぼ無く、セキュリティ上も危険です。" ;;
  vpn)
    warn "デフォルトルートが VPN ($IFACE) を通っています。"
    rec "速度を最優先するなら VPN を一時的に切ってください。VPN は暗号化と遠回りの分、実効速度とレイテンシを必ず悪化させます。" ;;
  *)
    warn "ゲートウェイの種別を判定できませんでした ($GW)。" ;;
esac

# 二重 NAT の検出
if [ "$CHECK_PUBLIC_IP" = "1" ] && have curl; then
    PUB=$(curl -s --max-time 5 https://api.ipify.org 2>/dev/null)
    if [ -n "$PUB" ]; then
        info "グローバル IP     : $PUB"
        case "$PUB" in
            10.*|192.168.*|172.1[6-9].*|172.2[0-9].*|172.3[01].*|100.6[4-9].*|100.[7-9][0-9].*|100.1[01][0-9].*|100.12[0-7].*)
                bad "グローバル IP がプライベート/CGNAT 帯域です = 二重 NAT になっています。"
                rec "二重 NAT です。ルーターが 2 台直列になっているか、ISP 側が CGNAT です。手前のルーターをブリッジ(APモード)にするか、ISP に固定/グローバル IP を確認してください。" ;;
        esac
    fi
fi

# ---------------------------------------------------------------- 2. Wi-Fi
head2 "2. Wi-Fi の品質"

WIFI_SEEN=0
if [ "$OS" = "Darwin" ] && have system_profiler; then
    WI=$(system_profiler SPAirPortDataType 2>/dev/null)
    if printf '%s' "$WI" | grep -q "Current Network"; then
        WIFI_SEEN=1
        CUR=$(printf '%s\n' "$WI" | sed -n '/Current Network Information:/,/Other Local Wi-Fi Networks:/p')
        SSID=$(printf '%s\n' "$CUR"  | awk 'NR==2{gsub(/^[ \t]+|:[ \t]*$/,"");print}')
        PHY=$(printf  '%s\n' "$CUR"  | awk -F': ' '/PHY Mode/{print $2; exit}')
        CHAN=$(printf '%s\n' "$CUR"  | awk -F': ' '/Channel/{print $2; exit}')
        RSSI=$(printf '%s\n' "$CUR"  | awk -F': ' '/Signal \/ Noise/{print $2; exit}')
        TXR=$(printf  '%s\n' "$CUR"  | awk -F': ' '/Transmit Rate/{print $2; exit}')
        SEC=$(printf  '%s\n' "$CUR"  | awk -F': ' '/Security/{print $2; exit}')
        info "SSID      : ${SSID:-?}"
        info "規格      : ${PHY:-?}     暗号: ${SEC:-?}"
        info "チャンネル: ${CHAN:-?}"
        info "電波       : ${RSSI:-?}"
        info "リンク速度: ${TXR:-?} Mbps"
    fi
elif have iw && [ -d "/sys/class/net/$IFACE/wireless" ]; then
    WIFI_SEEN=1
    iw dev "$IFACE" link 2>/dev/null | sed 's/^/         /'
    CHAN=$(iw dev "$IFACE" link 2>/dev/null | awk -F'[ (]' '/freq/{print $NF}')
    RSSI=$(iw dev "$IFACE" link 2>/dev/null | awk '/signal/{print $2}')
    PHY=""
fi

if [ "$WIFI_SEEN" = "1" ]; then
    # 2.4GHz 帯かどうか (ch 1-14)
    CH_NUM=$(printf '%s' "${CHAN:-}" | grep -o '^[0-9]\+' | head -1)
    if [ -n "$CH_NUM" ] && [ "$CH_NUM" -le 14 ] 2>/dev/null; then
        warn "2.4GHz 帯 (ch $CH_NUM) に接続しています。ここが今いちばん大きなボトルネックです。"
        rec "Wi-Fi を 5GHz または 6GHz の SSID に切り替えてください。2.4GHz は電子レンジ・Bluetooth・近隣の AP と干渉し、実効 100Mbps 前後で頭打ちになります。"
    elif [ -n "$CH_NUM" ]; then
        ok "5GHz 以上の帯域 (ch $CH_NUM) を使えています。"
    fi

    case "${PHY:-}" in
        *ax*|*be*) ok "Wi-Fi 6 以降 ($PHY) で接続できています。" ;;
        *ac*)      info "Wi-Fi 5 (802.11ac) です。ルーターとマシンが Wi-Fi 6 対応なら、そちらの方が速くなります。" ;;
        *n*|*g*|*b*) warn "古い規格 ($PHY) で接続しています。"
                     rec "Wi-Fi の規格が $PHY と古いです。ルーターが Wi-Fi 6 対応かを確認し、対応していれば 5/6GHz SSID に繋ぎ直してください。非対応ならルーターの買い替えが最も効果的です。" ;;
    esac

    # RSSI (dBm) を取り出す
    DBM=$(printf '%s' "${RSSI:-}" | grep -o -- '-[0-9]\+' | head -1)
    if [ -n "$DBM" ]; then
        if   [ "$DBM" -lt -75 ] 2>/dev/null; then
            bad "電波が弱すぎます (${DBM} dBm)。"
            rec "電波強度が ${DBM} dBm しかありません。ルーターに近づく、間の壁を減らす、またはメッシュ中継機を足してください。-67 dBm より強くしたいところです。"
        elif [ "$DBM" -lt -67 ] 2>/dev/null; then
            warn "電波がやや弱いです (${DBM} dBm)。"
            rec "電波強度 ${DBM} dBm はやや弱いです。ルーターとの距離・遮蔽物を見直すと実効速度が上がります。"
        else
            ok "電波強度は十分です (${DBM} dBm)。"
        fi
    fi

    rec "最速を狙うなら、可能であれば LAN ケーブルでルーターに有線接続してください。Wi-Fi のどんなチューニングよりも確実で、レイテンシとジッターが目に見えて改善します。"
else
    case "$MEDIA" in
        *Ethernet*|*有線*) ok "有線接続です。速度・安定性の面ではこれが最善です。" ;;
        *) info "Wi-Fi 情報は取得できませんでした (有線接続か、権限不足の可能性)。" ;;
    esac
fi

# ---------------------------------------------------------------- 3. 遅延
head2 "3. レイテンシとパケットロス"

# 結果は PING_AVG / PING_LOSS に入れて返す (表示と値の取得を混ぜない)
PING_AVG=""; PING_LOSS=""
ping_stat() { # $1=宛先 $2=ラベル
    local out
    PING_AVG=""; PING_LOSS=""
    out=$(ping -c 8 -q "$1" 2>/dev/null)
    if [ -z "$out" ]; then
        printf '         %-28s 応答なし\n' "$2 ($1)"
        return
    fi
    PING_LOSS=$(printf '%s' "$out" | grep -o '[0-9.]*% packet loss' | grep -o '^[0-9.]*')
    PING_AVG=$(printf  '%s' "$out" | awk -F'/' '/min\/avg|rtt|round-trip/{print $5; exit}')
    printf '         %-28s 平均 %-8s ms  ロス %s%%\n' "$2 ($1)" "${PING_AVG:-?}" "${PING_LOSS:-?}"
}

if [ -n "$GW" ]; then
    ping_stat "$GW" "ルーターまで"
    GW_AVG="$PING_AVG"; GW_LOSS="$PING_LOSS"
fi
ping_stat "1.1.1.1" "インターネットまで"
NET_AVG="$PING_AVG"; NET_LOSS="$PING_LOSS"

int_of() { printf '%.0f' "${1:-0}" 2>/dev/null || echo 0; }

if [ -n "${GW_AVG:-}" ]; then
    GI=$(int_of "$GW_AVG")
    if [ "$GW_KIND" = "private" ]; then
        # 本物の宅内ルーター相手なので、遅ければ原因は宅内 (Wi-Fi 区間) で確定できる
        if [ "$GI" -gt 20 ] 2>/dev/null; then
            bad "ルーターまでの往復が ${GW_AVG} ms もあります。宅内 (Wi-Fi 区間) が原因です。"
            rec "ルーターまでの ping が ${GW_AVG} ms と遅すぎます (有線なら 1ms 未満、良好な Wi-Fi で 5ms 以下)。回線契約ではなく宅内 Wi-Fi がボトルネックなので、有線化か 5GHz への移行を最優先で行ってください。"
        elif [ "$GI" -gt 5 ] 2>/dev/null; then
            warn "ルーターまで ${GW_AVG} ms。Wi-Fi 区間にやや無駄があります。"
        else
            ok "ルーターまで ${GW_AVG} ms。宅内は良好です。"
        fi
    else
        # ゲートウェイが宅内ではない (CGNAT/直結/VPN) ので宅内区間だけを切り分けられない
        info "最初のホップまで ${GW_AVG} ms (このゲートウェイは宅内ルーターではないため、宅内区間の切り分けには使えません)"
    fi
fi

if [ -n "${NET_AVG:-}" ]; then
    NI=$(int_of "$NET_AVG")
    if [ "$NI" -gt 50 ] 2>/dev/null; then
        warn "インターネットまで ${NET_AVG} ms。やや遅いです。"
        rec "外向きレイテンシが ${NET_AVG} ms あります。VPN・プロキシを切り、それでも改善しないなら ISP 側 (特に PPPoE 混雑) を疑ってください。"
    else
        ok "インターネットまで ${NET_AVG} ms。"
    fi
fi

LI=$(int_of "${NET_LOSS:-0}")
if [ "$LI" -gt 0 ] 2>/dev/null; then
    bad "パケットロスが ${NET_LOSS}% 発生しています。"
    rec "パケットロス ${NET_LOSS}% は速度以前の問題です。Wi-Fi の電波状況、LAN ケーブルの劣化、ルーターの過熱・再起動を順に確認してください。"
fi

# ---------------------------------------------------------------- 4. DNS
head2 "4. DNS (体感速度に効きます)"

CUR_DNS=""
if [ "$OS" = "Darwin" ] && have scutil; then
    CUR_DNS=$(scutil --dns 2>/dev/null | awk '/nameserver\[0\]/{print $3; exit}')
else
    CUR_DNS=$(awk '/^nameserver/{print $2; exit}' /etc/resolv.conf 2>/dev/null)
fi
info "現在の DNS: ${CUR_DNS:-不明}"

dns_ms() { # $1 = resolver
    if [ -z "$PY" ]; then echo ""; return; fi
    "$PY" - "$1" <<'EOF' 2>/dev/null
import random, socket, string, struct, sys, time
srv = sys.argv[1]
best = None
for _ in range(3):
    host = "".join(random.choices(string.ascii_lowercase, k=12)) + ".example.com"
    q = struct.pack(">HHHHHH", random.randint(0, 65535), 0x0100, 1, 0, 0, 0)
    for part in host.split("."):
        q += bytes([len(part)]) + part.encode()
    q += b"\x00" + struct.pack(">HH", 1, 1)
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    s.settimeout(2.0)
    try:
        t0 = time.time()
        s.sendto(q, (srv, 53))
        s.recvfrom(2048)
        dt = (time.time() - t0) * 1000
        best = dt if best is None else min(best, dt)
    except Exception:
        pass
    finally:
        s.close()
print(f"{best:.0f}" if best is not None else "")
EOF
}

if [ -z "$PY" ]; then
    info "python3 が無いため DNS ベンチマークはスキップします。"
else
    BEST_SRV=""; BEST_MS=""
    for pair in "${CUR_DNS:-skip}|現在の DNS" "1.1.1.1|Cloudflare" "8.8.8.8|Google" "9.9.9.9|Quad9"; do
        srv=${pair%%|*}; label=${pair##*|}
        [ "$srv" = "skip" ] && continue
        ms=$(dns_ms "$srv")
        if [ -n "$ms" ]; then
            printf '         %-12s %-14s %s ms\n' "$srv" "$label" "$ms"
            if [ -z "$BEST_MS" ] || [ "$ms" -lt "$BEST_MS" ] 2>/dev/null; then
                BEST_MS="$ms"; BEST_SRV="$srv"
            fi
        else
            printf '         %-12s %-14s 応答なし\n' "$srv" "$label"
        fi
    done

    if [ -n "$CUR_DNS" ] && [ -n "$BEST_SRV" ] && [ "$BEST_SRV" != "$CUR_DNS" ]; then
        CUR_MS=$(dns_ms "$CUR_DNS")
        if [ -n "$CUR_MS" ] && [ $((CUR_MS - BEST_MS)) -gt 10 ] 2>/dev/null; then
            warn "現在の DNS ($CUR_DNS, ${CUR_MS}ms) より $BEST_SRV (${BEST_MS}ms) の方が速いです。"
            rec "DNS を $BEST_SRV に変更すると 1 ページあたり数十 ms 短縮できます。ルーターの DHCP 設定で配れば、家じゅうの端末に一度で効きます (端末ごとの設定より推奨)。"
        else
            ok "DNS の応答速度は妥当です。"
        fi
    fi
fi

# ---------------------------------------------------------------- 5. 実効速度
head2 "5. 実効スループット"

if [ "$OS" = "Darwin" ] && have networkQuality; then
    info "macOS 標準の networkQuality を実行します (30秒ほどかかります)..."
    NQ=$(networkQuality -s -c 2>/dev/null)
    if [ -n "$NQ" ] && [ -n "$PY" ]; then
        printf '%s' "$NQ" | "$PY" -c '
import json,sys
try: d=json.load(sys.stdin)
except Exception: sys.exit(0)
dl=d.get("dl_throughput",0)/1e6; ul=d.get("ul_throughput",0)/1e6
rpm=d.get("responsiveness",0)
print(f"         下り  : {dl:.1f} Mbps")
print(f"         上り  : {ul:.1f} Mbps")
print(f"         応答性: {rpm} RPM  (高いほど良い / 目安: 900未満=低, 900-2000=中, 2000以上=高)")
'
        RPM=$(printf '%s' "$NQ" | "$PY" -c 'import json,sys
try: print(int(json.load(sys.stdin).get("responsiveness",0)))
except Exception: print(0)')
        if [ "${RPM:-0}" -lt 900 ] 2>/dev/null && [ "${RPM:-0}" -gt 0 ] 2>/dev/null; then
            warn "応答性 (RPM) が ${RPM} と低く、バッファブロートが起きています。"
            rec "バッファブロート (RPM=${RPM}) が出ています。ルーターの QoS / SQM (Smart Queue Management) を有効にすると、回線速度そのままで体感が大きく改善します。対応していないルーターなら、これが買い替えの一番の理由になります。"
        fi
    else
        printf '%s\n' "$NQ" | sed 's/^/         /'
    fi
elif have speedtest; then
    speedtest --progress=no 2>/dev/null | sed 's/^/         /'
else
    info "自動計測ツールがありません。https://fast.com か https://speed.cloudflare.com で測ってください。"
    info "(Linux なら: sudo apt install speedtest-cli && speedtest-cli)"
fi

# ---------------------------------------------------------------- 6. まとめ
head2 "6. やるべきこと (効果の大きい順)"

if [ ${#RECOMMEND[@]} -eq 0 ]; then
    ok "目立った問題は見つかりませんでした。現状がほぼ最速です。"
    info "これ以上を求めるなら、回線契約そのもの (IPv6 IPoE / 10Gbps プラン) の見直しになります。"
else
    i=1
    for r in "${RECOMMEND[@]}"; do
        printf '\n  \033[1m%d.\033[0m %s\n' "$i" "$r"
        i=$((i + 1))
    done
fi

printf '\n'
info "補足: 日本の光回線で夜間だけ遅い場合、原因はほぼ PPPoE の輻輳です。"
info "      ISP の IPv6 IPoE (v6プラス / OCNバーチャルコネクト等) に切り替え、"
info "      ルーター側も IPoE 対応機種にすると、混雑時間帯の速度が数倍変わります。"
printf '\n'
