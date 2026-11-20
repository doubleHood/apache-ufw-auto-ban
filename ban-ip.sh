#!/bin/bash
# ban-ip.sh -- 直近のApacheログから、キーワードに掛かったIPを ufw deny する
# 設置: /usr/local/sbin/ban-ip.sh (755)
# 設定: /etc/ban-ip.conf (パス類は全部そっちに書く。本体は触らない)
# cron: */10 * * * * root /usr/local/sbin/ban-ip.sh

# 設定ファイル読み込み (LOG / CONF / BANLOG が入っている)
SETTINGS="${BAN_IP_SETTINGS:-/etc/ban-ip.conf}"
if [ ! -f "$SETTINGS" ]; then echo "設定ファイルがありません: $SETTINGS" >&2; exit 1; fi
. "$SETTINGS"

# FW の値チェック (ufw / iptables 以外なら設定ミスとして止める)
case "$FW" in
  ufw|iptables) ;;
  *) echo "FW の設定が不正です: '$FW' (ufw か iptables を指定)" >&2; exit 1 ;;
esac

# 直近11分分のタイムスタンプ文字列を作る (分単位)
# ・10分間隔cronで「同じ分の後半」を取りこぼさないよう1分重ねる (重複banは下で回避)
# ・LC_ALL=C は月の表記を Nov のように英語で固定するため (Apacheの表記と合わせる)
TIMES=$(for i in $(seq 0 10); do LC_ALL=C date -d "$i min ago" '+%d/%b/%Y:%H:%M'; done | paste -sd'|' -)

# キーワード: #コメント行と空行を除く (空行が混じると全行一致してしまうので必須)
KEYWORDS=$(grep -vE '^[[:space:]]*(#|$)' "$CONF")
[ -z "$KEYWORDS" ] && exit 0

# IPは combined 形式の第1フィールド。vhost_combined 形式 (先頭に
# ホスト名が付く) のログを使う場合は $1 を $2 に変えること
grep -E "$TIMES" "$LOG" \
  | grep -F "$KEYWORDS" \
  | awk '{print $1}' \
  | sort -u \
  | while read -r ip; do
      [ "$ip" = "127.0.0.1" ] && continue
      # ==== ファイアウォール切り替え (ban-ip.conf の FW で分岐) ====
      case "$FW" in
        ufw)
          # 既にdeny済みなら何もしない
          ufw status | grep -q "$ip" && continue
          ufw deny from "$ip"/32 to any || continue
          ;;
        iptables)
          # 既に同じDROPルールがあれば何もしない (-C = チェック)
          iptables -C INPUT -s "$ip"/32 -j DROP 2>/dev/null && continue
          # INPUTの先頭に入れる (既存のACCEPTより先に評価させるため)
          iptables -I INPUT 1 -s "$ip"/32 -j DROP || continue
          # 永続化したい場合は次の行の # を外す (要 iptables-persistent)
          # netfilter-persistent save
          ;;
      esac
      echo "$(date '+%F %T') deny $ip ($FW)" >> "$BANLOG"
    done
