# apache-ufw-auto-ban

Apache のアクセスログを cron で巡回し、怪しいパスを叩いた IP をファイアウォールで
遮断する、それだけのshellスクリプト。
ファイアウォールは ufw / iptables / firewalld を設定ファイルで切り替えられます。

`.env` や `.git` の探索、WordPress / phpMyAdmin / Next.js など使っていない
技術スタックへの脆弱性スキャンは、公開サーバーには毎日大量に来ます。
fail2ban を入れるほどでもない個人サーバー向けに、依存なし・設定ファイル2つ・本体約30行のシンプルな構成です。

## 仕組み

```
cron (10分おき, root)
  └─ ban-ip.sh
       1. /etc/ban-ip.conf を読み込む (対象ログ等のパス設定)
       2. アクセスログから直近11分ぶんの行だけ抜く
       3. ban-keywords.conf のキーワードに掛かる行を抜く
       4. IPをユニーク化 (combined 形式の第1フィールド)
       5. 未登録なら遮断 (ufw: deny from <IP>/32 / iptables: INPUT に DROP / firewalld: rich rule で drop)
```

## ファイル

| ファイル | 設置先 | 役割 |
|---|---|---|
| `ban-ip.sh` | `/usr/local/sbin/ban-ip.sh` | 本体 |
| `ban-ip.conf` | `/etc/ban-ip.conf` | 設定 (監視ログ等のパス / FW切り替え) |
| `ban-keywords.conf` | `/etc/ban-keywords.conf` | ban対象キーワード (1行1つ) |
| `ban-ip.cron` | `/etc/cron.d/ban-ip` | 10分おき実行 |

## 動作環境

- Debian / Ubuntu 系 (Apache2 + ufw または iptables)
- RHEL 系 (RHEL / Oracle Linux / Rocky Linux / AlmaLinux など。httpd + firewalld)
- root の cron で実行すること (ファイアウォールを操作するため)
- ログは `/var/log/apache2/access.log` (combined 形式) を想定。
  `ban-ip.conf` の `LOG` はサンプル値なので、自分の環境のアクセスログに
  書き換えてください。vhost_combined 形式 (先頭にホスト名が付くログ) を
  使う場合は、`LOG` を変えたうえで本体の `awk '{print $1}'` を `$2` に
  変えてください (IP のフィールド位置が違います)

## インストール

```bash
sudo install -m 755 ban-ip.sh /usr/local/sbin/
sudo install -m 644 ban-ip.conf ban-keywords.conf /etc/
sudo install -m 644 ban-ip.cron /etc/cron.d/ban-ip
```

## 使い方

- キーワードの追加・削除は `/etc/ban-keywords.conf` を編集するだけ。
  次回実行 (10分以内) から反映されます。再起動は不要です
- 無効化は行頭に `#` を付けるだけです (コメント行は照合対象から外れます)
- ban の記録は `/var/log/ban-ip.log` に残ります
- 現在の ban 一覧: `sudo ufw status numbered`
- 解除: `sudo ufw delete deny from <IP>/32 to any`

## iptables で使う場合

`ban-ip.conf` の FW 指定をコメントの付け外しで切り替えるだけです。

```bash
#FW=ufw
FW=iptables
```

- ルールは `iptables -I INPUT 1 -s <IP>/32 -j DROP` で INPUT チェーンの
  先頭に入ります (既存の ACCEPT より先に評価させるため)。
  登録済みかどうかは `iptables -C` で確認するので重複しません
- **永続化に注意：** iptables のルールは再起動で消えます。残したい場合は
  `iptables-persistent` をインストールし、`ban-ip.sh` 内の
  `netfilter-persistent save` の行のコメントを外してください
- 対象は IPv4 のみです (IPv6 は ip6tables 側の話になるので未対応)
- Docker が iptables を管理している環境では、INPUT への直接挿入と
  競合する場合があります。そのような環境では ufw 側か、
  Docker 用のチェーン設計を別途検討してください

## firewalld で使う場合

RHEL 系 (RHEL / Oracle Linux / Rocky Linux / AlmaLinux など) の標準はこちらです。
同じく `ban-ip.conf` のコメントの付け外しで切り替えます。

```bash
#FW=ufw
FW=firewalld
```

- 遮断は rich rule `rule family="ipv4" source address="<IP>/32" drop` を
  デフォルトゾーンに入れます。登録済みかどうかは
  `--permanent --query-rich-rule` で確認するので重複しません
- `--permanent` (再起動後も残る) とランタイム (即反映) の両方に入れるので、
  reload は不要です
- RHEL 系では Apache のログは通常 `/var/log/httpd/access_log` です。
  `ban-ip.conf` の `LOG` を環境に合わせて書き換えてください
- 解除: `sudo firewall-cmd --permanent --remove-rich-rule='rule family="ipv4" source address="<IP>/32" drop'`
  のあと `sudo firewall-cmd --reload`
- 対象は IPv4 のみです

## 必ず先に読む注意

- **自分のサイトの正規パスと衝突させないこと。**
  - キーワードはログ行全体への単純な文字列照合です。
  - 自分のアプリに `/login` や `/admin` があるのにそれらを有効化すると、正規利用者 (自分を含む) が ban されます。
    - 同梱 conf では衝突しやすいものは「任意」節でコメントアウトしてあります
- **自分でテストアクセスすると自分が ban されます。**
  -  `/.env` などを動作確認で叩く前に、解除コマンドを手元に用意してください
- `favicon.ico`、`robots.txt`、`sitemap.xml` はキーワードに入れないでください。
  - 通常のブラウザや検索エンジンが普通に叩くパスで、サイト側で 404 を返す構成だと普通の訪問者が ban されます

## 制限 (割り切っていること)

- IPv4 のみ ( `/32` 前提)
- キーワードに現れないランダムパス探索 (例: `/aaa9`) は捕捉できません。
  - 404 の回数で判定する仕組みが要るので、この構成では対象外です
- Censys や zgrab のような調査系スキャナーは IP が分散していて、1件ずつ ban しても効果は限定的です
- ban は最大で10分遅れます。即応性が要るなら fail2ban 等を検討してください

## ライセンス

MIT License. 詳細は [LICENSE](LICENSE) を参照してください。
