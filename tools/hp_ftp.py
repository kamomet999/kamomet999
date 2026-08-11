#!/usr/bin/env python3
"""ISP のホームページ領域を FTP でバックアップ / 確認 / 削除するツール。

標準ライブラリのみで動くので、pip install は不要。

    python3 hp_ftp.py list     --host www.example.ne.jp --user cb00000
    python3 hp_ftp.py backup   --host www.example.ne.jp --user cb00000 --dest ./backup
    python3 hp_ftp.py wipe     --host www.example.ne.jp --user cb00000 --backup ./backup
    python3 hp_ftp.py redirect --host www.example.ne.jp --user cb00000 --to https://new.example.com/

パスワードは getpass で聞くので、コマンド履歴には残らない。
環境変数 FTP_PASSWORD に入れておけばそちらを使う。
"""

from __future__ import annotations

import argparse
import ftplib
import getpass
import html
import io
import json
import os
import posixpath
import sys
import urllib.parse
from dataclasses import dataclass, field

# 2000年代の国内 ISP のホームページ領域は、ファイル名が Shift_JIS のことが多い。
# cp932 -> utf-8 の順で試す。
ENCODINGS = ("cp932", "utf-8", "latin-1")

MANIFEST = "manifest.json"


@dataclass
class Entry:
    path: str          # リモートの絶対パス
    is_dir: bool
    size: int = 0


@dataclass
class Stats:
    files: int = 0
    dirs: int = 0
    bytes: int = 0
    errors: list[str] = field(default_factory=list)


def connect(host: str, user: str, password: str, *, encoding: str,
            use_tls: bool, port: int, timeout: int) -> ftplib.FTP:
    cls = ftplib.FTP_TLS if use_tls else ftplib.FTP
    ftp = cls(timeout=timeout)
    ftp.encoding = encoding
    ftp.connect(host, port)
    ftp.login(user, password)
    if use_tls:
        ftp.prot_p()
    ftp.set_pasv(True)  # NAT 越しはパッシブでないと繋がらない
    return ftp


def _connect(args, password: str, enc: str) -> ftplib.FTP:
    try:
        return connect(args.host, args.user, password, encoding=enc,
                       use_tls=args.tls, port=args.port, timeout=args.timeout)
    except ftplib.error_perm as e:
        raise SystemExit(f"ログイン失敗: {e}\n"
                         "ユーザー名 / パスワードを確認してください。") from e


def connect_autodetect(args, password: str) -> tuple[ftplib.FTP, str]:
    """日本語ファイル名が化けない文字コードで接続する。

    まず FEAT を見て、サーバーが UTF8 を名乗ればそれを信じる。名乗らなければ
    古いサーバーなので、国内 ISP なら Shift_JIS(cp932) の可能性が高い。
    それでも化ける場合は --encoding で明示指定する。
    """
    if args.encoding:
        return _connect(args, password, args.encoding), args.encoding

    ftp = _connect(args, password, "utf-8")
    try:
        advertises_utf8 = "UTF8" in ftp.sendcmd("FEAT").upper()
    except (ftplib.error_perm, ftplib.error_proto, UnicodeDecodeError):
        advertises_utf8 = False
    if advertises_utf8:
        return ftp, "utf-8"
    ftp.close()

    last: object = None
    for enc in ENCODINGS:
        try:
            ftp = _connect(args, password, enc)
        except Exception as e:  # noqa: BLE001 - 接続系は何が来るか分からない
            last = e
            continue
        try:
            ftp.nlst(args.remote_root)  # 実際に一覧を読んで化けないか確かめる
            return ftp, enc
        except UnicodeDecodeError:
            ftp.close()
            last = f"{enc} でデコード失敗"
            continue
        except ftplib.error_perm:
            return ftp, enc  # 空ディレクトリ等。接続自体は成立している
    raise SystemExit(f"接続できませんでした: {last}")


# Unix の LIST 行は先頭がファイル種別 + パーミッション（例 -rw-r--r-- / drwxr-xr-x）。
# 通常ファイルは '-' 始まりなので、ここを取りこぼすと「ファイル0個」になる。
UNIX_TYPES = "-dlbcps"


def _parse_unix(line: str) -> tuple[str, bool, int] | None:
    parts = line.split(maxsplit=8)
    if len(parts) < 9:
        return None
    perms = parts[0]
    if len(perms) < 10 or perms[0] not in UNIX_TYPES:
        return None
    try:
        size = int(parts[4])
    except ValueError:
        size = 0
    return parts[8], perms[0] == "d", size


def _parse_dos(line: str) -> tuple[str, bool, int] | None:
    # 例: 08-11-25  05:25PM       <DIR>          images
    parts = line.split(maxsplit=3)
    if len(parts) < 4 or "-" not in parts[0]:
        return None
    if parts[2] == "<DIR>":
        return parts[3].strip(), True, 0
    try:
        return parts[3].strip(), False, int(parts[2])
    except ValueError:
        return None


def list_entries(ftp: ftplib.FTP, path: str) -> tuple[list[Entry], list[str]]:
    """path 直下のエントリと、解釈できなかった行を返す。

    MLSD が無ければ LIST にフォールバックする。解釈できない行は黙って捨てず
    必ず呼び出し元へ返すこと。取りこぼしに気付けないまま「バックアップ成功」と
    表示するのが、このツールで最も危険な壊れ方なので。
    """
    try:
        out = []
        for name, facts in ftp.mlsd(path):
            if name in (".", ".."):
                continue
            t = facts.get("type")
            if t == "dir":
                out.append(Entry(posixpath.join(path, name), True))
            elif t == "file":
                out.append(Entry(posixpath.join(path, name), False,
                                 int(facts.get("size") or 0)))
        return out, []
    except (ftplib.error_perm, ftplib.error_proto, AttributeError):
        pass  # 古いサーバーは MLSD 非対応

    lines: list[str] = []
    ftp.retrlines(f"LIST {path}" if path else "LIST", lines.append)
    out, unparsed = [], []
    for line in lines:
        if not line.strip() or line.lower().startswith("total "):
            continue
        parsed = _parse_unix(line) or _parse_dos(line)
        if parsed is None:
            unparsed.append(f"{path or '/'}: {line}")
            continue
        name, is_dir, size = parsed
        if name in (".", ".."):
            continue
        if line[0] == "l":
            continue  # シンボリックリンクは辿らない（ループ防止）
        out.append(Entry(posixpath.join(path, name), is_dir, size))
    return out, unparsed


def walk(ftp: ftplib.FTP, root: str, stats: Stats) -> list[Entry]:
    """root 以下を再帰的に辿って、全エントリを平坦なリストで返す。"""
    found: list[Entry] = []
    stack = [root]
    seen: set[str] = set()
    while stack:
        cur = stack.pop()
        if cur in seen:
            continue
        seen.add(cur)
        try:
            entries, unparsed = list_entries(ftp, cur)
        except Exception as e:  # noqa: BLE001
            stats.errors.append(f"一覧取得失敗 {cur}: {e}")
            continue
        for line in unparsed:
            stats.errors.append(f"一覧の行を解釈できず（取りこぼしの可能性）: {line}")
        for e in entries:
            found.append(e)
            if e.is_dir:
                stats.dirs += 1
                stack.append(e.path)
            else:
                stats.files += 1
                stats.bytes += e.size
    return found


def human(n: int) -> str:
    for unit in ("B", "KB", "MB", "GB"):
        if n < 1024 or unit == "GB":
            return f"{n:.1f}{unit}" if unit != "B" else f"{n}B"
        n /= 1024
    return f"{n}B"


def cmd_list(ftp: ftplib.FTP, args) -> int:
    stats = Stats()
    entries = walk(ftp, args.remote_root, stats)
    for e in sorted(entries, key=lambda x: x.path):
        mark = "[DIR] " if e.is_dir else "      "
        size = "" if e.is_dir else f"  {human(e.size)}"
        print(f"{mark}{e.path}{size}")
    print(f"\nファイル {stats.files} 個 / ディレクトリ {stats.dirs} 個 / "
          f"合計 {human(stats.bytes)}")
    for err in stats.errors:
        print(f"  ! {err}", file=sys.stderr)
    return 0


# 旧URLを開いた人を新ページへ送るページ。meta refresh 0 は検索エンジンにも
# リダイレクト扱いされ、noindex + canonical で旧URLは検索結果から消えていく。
REDIRECT_TEMPLATE = """<!DOCTYPE html>
<html lang="ja">
<head>
<meta charset="utf-8">
<meta name="robots" content="noindex">
<meta http-equiv="refresh" content="0; url={attr}">
<link rel="canonical" href="{attr}">
<title>移転のお知らせ</title>
</head>
<body>
<p>このホームページは移転しました。自動で移動しない場合は、次のリンクをクリックしてください。</p>
<p><a href="{attr}">{text}</a></p>
<script>location.replace({js});</script>
</body>
</html>
"""


def make_redirect_html(url: str) -> bytes:
    safe = html.escape(url, quote=True)
    return REDIRECT_TEMPLATE.format(attr=safe, text=safe,
                                    js=json.dumps(url)).encode("utf-8")


def download_entries(ftp: ftplib.FTP, entries: list[Entry], root: str,
                     dest: str, stats: Stats) -> list[dict]:
    """entries のファイルを dest へ保存し、目録リストを返す。"""
    manifest = []
    for e in sorted(entries, key=lambda x: x.path):
        rel = e.path[len(root):].lstrip("/") if root else e.path.lstrip("/")
        local = os.path.join(dest, *rel.split("/"))
        if e.is_dir:
            os.makedirs(local, exist_ok=True)
            continue
        os.makedirs(os.path.dirname(local) or dest, exist_ok=True)
        try:
            with open(local, "wb") as fh:
                ftp.retrbinary(f"RETR {e.path}", fh.write)
        except Exception as ex:  # noqa: BLE001
            stats.errors.append(f"取得失敗 {e.path}: {ex}")
            print(f"  ! 失敗 {rel}")
            continue
        got = os.path.getsize(local)
        # サーバー申告サイズと突き合わせる。0 申告のサーバーもあるので警告のみ。
        if e.size and got != e.size:
            stats.errors.append(f"サイズ不一致 {e.path}: 申告 {e.size} / 実際 {got}")
        manifest.append({"remote": e.path, "local": rel, "size": got})
        print(f"  OK {rel} ({human(got)})")
    return manifest


def write_manifest(dest: str, host: str, root: str, manifest: list[dict]) -> str:
    path = os.path.join(dest, MANIFEST)
    with open(path, "w", encoding="utf-8") as fh:
        json.dump({"host": host, "root": root, "files": manifest},
                  fh, ensure_ascii=False, indent=2)
    return path


def remove_entries(ftp: ftplib.FTP, files: list[Entry], dirs: list[Entry],
                   stats: Stats) -> int:
    removed = 0
    for e in sorted(files, key=lambda x: x.path):
        try:
            ftp.delete(e.path)
            removed += 1
            print(f"  削除 {e.path}")
        except Exception as ex:  # noqa: BLE001
            stats.errors.append(f"削除失敗 {e.path}: {ex}")
    # 深い階層から順にディレクトリを消す
    for e in sorted(dirs, key=lambda x: x.path.count("/"), reverse=True):
        try:
            ftp.rmd(e.path)
            print(f"  削除 {e.path}/")
        except Exception as ex:  # noqa: BLE001
            stats.errors.append(f"ディレクトリ削除失敗 {e.path}: {ex}")
    return removed


def cmd_backup(ftp: ftplib.FTP, args) -> int:
    dest = os.path.abspath(args.dest)
    os.makedirs(dest, exist_ok=True)

    stats = Stats()
    entries = walk(ftp, args.remote_root, stats)

    # 空の目録を書くと、それを根拠に wipe が通ってしまう。必ずここで止める。
    if stats.files == 0:
        print("ファイルが 1 個も見つかりませんでした。目録を書かずに中止します。",
              file=sys.stderr)
        for err in stats.errors:
            print(f"  ! {err}", file=sys.stderr)
        print("\n--remote-root の指定違い、または一覧の解釈失敗が疑われます。\n"
              "list コマンドで中身が見えるか先に確認してください。", file=sys.stderr)
        return 1

    print(f"対象: ファイル {stats.files} 個 / {human(stats.bytes)}\n")

    root = args.remote_root.rstrip("/")
    manifest = download_entries(ftp, entries, root, dest, stats)
    mpath = write_manifest(dest, args.host, args.remote_root, manifest)

    print(f"\n完了: {len(manifest)}/{stats.files} 個を {dest} に保存")
    print(f"目録: {mpath}")
    for err in stats.errors:
        print(f"  ! {err}", file=sys.stderr)
    if stats.errors:
        print("\n※ エラーがあります。削除する前に必ず解消してください。", file=sys.stderr)
        return 1
    return 0


def cmd_wipe(ftp: ftplib.FTP, args) -> int:
    # バックアップの実在を確認できない限り、絶対に消さない。
    mpath = os.path.join(args.backup, MANIFEST)
    if not os.path.isfile(mpath):
        raise SystemExit(f"バックアップ目録が見つかりません: {mpath}\n"
                         "先に backup を実行してください。")
    with open(mpath, encoding="utf-8") as fh:
        saved = json.load(fh)

    missing = [f["local"] for f in saved["files"]
               if not os.path.isfile(os.path.join(args.backup, *f["local"].split("/")))]
    if missing:
        raise SystemExit(f"バックアップに {len(missing)} 個の欠損があります。中止します。\n"
                         + "\n".join(f"  - {m}" for m in missing[:10]))

    stats = Stats()
    entries = walk(ftp, args.remote_root, stats)
    files = [e for e in entries if not e.is_dir]
    dirs = [e for e in entries if e.is_dir]

    if not files and saved["files"]:
        raise SystemExit(
            f"目録には {len(saved['files'])} ファイルあるのに、サーバー側は 0 個に見えます。\n"
            "一覧の解釈に失敗している可能性が高いので中止します。")

    backed_up = {f["remote"] for f in saved["files"]}
    unsaved = [e.path for e in files if e.path not in backed_up]
    if unsaved:
        raise SystemExit(f"バックアップに含まれないファイルが {len(unsaved)} 個あります。"
                         "中止します。backup を取り直してください。\n"
                         + "\n".join(f"  - {p}" for p in unsaved[:10]))

    print(f"以下の {len(files)} ファイル / {len(dirs)} ディレクトリを削除します:\n")
    for e in sorted(files, key=lambda x: x.path):
        print(f"  {e.path}")

    if args.dry_run:
        print("\n--dry-run のため、実際には削除していません。")
        return 0

    print(f"\nバックアップ確認済み: {args.backup} ({len(saved['files'])} ファイル)")
    if input('本当に削除する場合は DELETE と入力: ').strip() != "DELETE":
        print("中止しました。")
        return 1

    removed = remove_entries(ftp, files, dirs, stats)
    print(f"\n{removed}/{len(files)} ファイルを削除しました。")
    for err in stats.errors:
        print(f"  ! {err}", file=sys.stderr)
    return 1 if stats.errors else 0


def cmd_redirect(ftp: ftplib.FTP, args) -> int:
    """領域の中身をリダイレクトページ 1 枚に置き換える。

    流れ: 全ファイルを自動バックアップ → 全削除 → index.html を設置 → 検証。
    ホームページ契約そのものは残す前提（ポータルで「利用しない」にすると
    このリダイレクトごと消えるので注意）。
    """
    stats = Stats()
    entries = walk(ftp, args.remote_root, stats)
    if stats.errors:
        for err in stats.errors:
            print(f"  ! {err}", file=sys.stderr)
        raise SystemExit("一覧に問題があるため、何も変更せず中止します。")

    files = [e for e in entries if not e.is_dir]
    dirs = [e for e in entries if e.is_dir]
    root = args.remote_root.rstrip("/")
    target = posixpath.join(args.remote_root, "index.html") if args.remote_root \
        else "index.html"
    body = make_redirect_html(args.to)

    print(f"リダイレクト先: {args.to}")
    print(f"既存: ファイル {len(files)} 個 / ディレクトリ {len(dirs)} 個 "
          f"→ すべて削除して index.html 1枚 ({human(len(body))}) に置き換えます\n")
    for e in sorted(files, key=lambda x: x.path):
        print(f"  消える: {e.path}")

    if args.dry_run:
        print("\n--dry-run のため、何も変更していません。")
        return 0

    if files:
        dest = os.path.abspath(args.dest)
        os.makedirs(dest, exist_ok=True)
        print(f"\n念のためバックアップを {dest} に取ります:")
        manifest = download_entries(ftp, entries, root, dest, stats)
        if stats.errors:
            for err in stats.errors:
                print(f"  ! {err}", file=sys.stderr)
            raise SystemExit("バックアップに失敗があるため、削除せず中止します。")
        write_manifest(dest, args.host, args.remote_root, manifest)

    if input('置き換えを実行する場合は REPLACE と入力: ').strip() != "REPLACE":
        print("中止しました。")
        return 1

    remove_entries(ftp, files, dirs, stats)
    ftp.storbinary(f"STOR {target}", io.BytesIO(body))

    # 置き換え結果を検証: index.html だけが、正しいサイズで残っていること
    after, unparsed = list_entries(ftp, args.remote_root)
    names = {e.path: e for e in after}
    ok = target in names and not names[target].is_dir
    if ok and names[target].size and names[target].size != len(body):
        stats.errors.append(f"index.html のサイズ不一致: "
                            f"サーバー {names[target].size} / 手元 {len(body)}")
        ok = False
    leftover = sorted(p for p in names if p != target)
    for p in leftover:
        stats.errors.append(f"残存: {p}")
    stats.errors.extend(f"一覧の行を解釈できず: {u}" for u in unparsed)

    print()
    if ok and not leftover:
        print(f"完了: {target} ({human(len(body))}) だけが残っています。")
        print("\nブラウザでホームページの URL を開いて、新しいページへ"
              "飛ぶことを確認してください。")
        print("注意: ポータルで「利用しない」にするとこのリダイレクトごと消えます。"
              "契約は「利用する」のまま維持してください。")
    for err in stats.errors:
        print(f"  ! {err}", file=sys.stderr)
    return 0 if ok and not leftover and not stats.errors else 1


def main() -> int:
    p = argparse.ArgumentParser(
        description="ホームページ領域を FTP でバックアップ / 確認 / 削除する",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=__doc__)
    p.add_argument("command", choices=["list", "backup", "wipe", "redirect"])
    p.add_argument("--host", required=True, help="FTP サーバー名")
    p.add_argument("--user", required=True, help="FTP ユーザー名")
    p.add_argument("--port", type=int, default=21)
    p.add_argument("--tls", action="store_true", help="FTPS (明示的 TLS) を使う")
    p.add_argument("--timeout", type=int, default=30)
    p.add_argument("--encoding", help=f"指定しなければ {'/'.join(ENCODINGS)} を順に試す")
    p.add_argument("--remote-root", default="",
                   help="公開ディレクトリ。空ならログイン直後の場所")
    p.add_argument("--dest", default="./hp-backup",
                   help="backup/redirect: バックアップ保存先")
    p.add_argument("--backup", default="./hp-backup", help="wipe: 確認に使うバックアップ")
    p.add_argument("--dry-run", action="store_true",
                   help="wipe/redirect: 変更せずに対象だけ表示")
    p.add_argument("--to", help="redirect: 飛ばし先 URL (https://... )")
    args = p.parse_args()

    if args.command == "redirect":
        u = urllib.parse.urlparse(args.to or "")
        if u.scheme not in ("http", "https") or not u.netloc:
            p.error("redirect には --to https://新しいページのURL が必要です")

    password = os.environ.get("FTP_PASSWORD") or getpass.getpass("FTP パスワード: ")

    ftp, enc = connect_autodetect(args, password)
    print(f"接続: {args.host} (文字コード {enc})")
    try:
        print(f"カレント: {ftp.pwd()}\n")
    except Exception:  # noqa: BLE001
        print()

    try:
        return {"list": cmd_list, "backup": cmd_backup, "wipe": cmd_wipe,
                "redirect": cmd_redirect}[args.command](ftp, args)
    finally:
        try:
            ftp.quit()
        except Exception:  # noqa: BLE001
            ftp.close()


if __name__ == "__main__":
    sys.exit(main())
