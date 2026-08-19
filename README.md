# tnt-ble-probe

TANITA BC-768（体組成計）と macOS の BLE 通信を検証するための CLI `bc768-probe`。
CoreBluetooth で接続し、測定を実行して結果をデコードする。

- 仕様: [docs/BC-768_macOS_BLE_検証仕様書.md](docs/BC-768_macOS_BLE_検証仕様書.md)
- 実装の説明: [docs/implementation.md](docs/implementation.md)
- 検証結果: [docs/verification-log.md](docs/verification-log.md)

`scan` / `probe` は Scan / Connect / Discovery / Notify 購読 / ログまで。`handshake` / `measure` は
Android の HCI キャプチャで確認済みの通信手順を送る。**推測した payload は一切送らない。**

`measure` では macOS から BC-768 の測定を実行し、測定結果をデコードして表示する。
体重・身長・体脂肪率・筋肉量・推定骨量・BMI は BMI と除脂肪量の検算で裏づけ済み
（[docs/protocol.md](docs/protocol.md)）。

## セットアップ

BLE の Service / Characteristic UUID はリポジトリに含めない。ローカルの `.env`（git 管理外）か環境変数で与える。

```bash
cp .env.example .env
$EDITOR .env        # 6 つの UUID 実値を記入する
swift build
```

## 使い方

```bash
# BC-768 候補を探索する
.build/debug/bc768-probe scan
.build/debug/bc768-probe scan --no-filter --timeout 10

# scan → connect → discover → subscribe → wait
.build/debug/bc768-probe probe
.build/debug/bc768-probe probe --debug

# 確認済みのハンドシェイクを送る
.build/debug/bc768-probe handshake --debug

# 測定を実行して結果を受け取る
.build/debug/bc768-probe measure --debug

# 測定は開始せず、保持されているデータを引き取る
.build/debug/bc768-probe sync --debug

# ログに残した hex を後から解釈する（BLE 不要）
.build/debug/bc768-probe decode --command B010 <payload hex>

# 測定結果を JSON で受け取る / ファイルへ蓄積する
.build/debug/bc768-probe measure --json | jq .
.build/debug/bc768-probe measure --out ~/health/bc768.jsonl

# 新規の測定結果があるときだけ拾う（定期実行向け）
.build/debug/bc768-probe sync --only-new --out ~/health/bc768.jsonl
```

BC-768 は時計を持たないため、**接続下で測定したときだけ測定日時が付く**。
本体だけで測ったデータは値は読めるが日時が付かない（`hasTimestamp: false`）。
日時付きで残したいなら `measure` で測り、`--out` で保存しておく。

BC-768 側は、実行前に本体の**「入力モード」**を押して起動しておく。
設定/通信ボタンの長押しでは接続できてもセッションを拒否される（`ErCP` になる）。
BLE の Pairing / Bonding は不要（[docs/protocol.md](docs/protocol.md) 参照）。
終了は Ctrl+C（Notify 解除 → disconnect → cleanup を行ってから終了する）。

オプション一覧は `bc768-probe --help` を参照。

## 動かすために必要なもの

Service / Characteristic UUID とクライアント識別子は**このリポジトリに含まれていない**。

**UUID は自動で取得できる。** 事前に知っている必要はない。

```bash
bc768-probe discover --name TNT --save
```

接続して GATT の構成を調べ、「Service 1 つ + writeWithoutResponse × 2 + notify × 3」に
一致すれば UUID を割り当てて `~/.config/bc768-probe/env` へ書き出す。

**クライアント識別子だけは手当てが要る。** BC-768 に登録済みの値でないと拒否されるため、
Health Planet が使っている識別子が必要になる（`docs/protocol.md` の「0x8003 の応答コード」を参照）。

識別子は `0x0003` の payload に ASCII でそのまま乗っているので、
Android の HCI キャプチャ（`adb bugreport` の btsnoop）から読み取れる。

**Mac を BC-768 に見せかけて Health Planet から受け取る方法は失敗した。**
広告の生バイト列まで一致させても、Health Planet は BD アドレスを見て捨てる。
macOS には BD アドレスを変える手段がないため成立しない（詳細は `docs/verification-log.md`）。

受信側の実装自体は `impersonate` として残してある。
BD アドレスを設定できる環境（Linux + `btmgmt public-addr`、ESP32 など）なら再利用できるはず。

```bash
# BC-768 本体の電源は切っておく
bc768-probe impersonate
```

Service UUID と 5 本の Characteristic を持つ Peripheral として `TNT_BW` の名前で広告し、
Health Planet が送ってきた `0x0003` の payload をそのまま表示する。

```text
[CLIENT_ID] value=... length=36
クライアント識別子を受け取りました:
  BC768_CLIENT_ID=...
```

`--reply` を付けると観測済みの応答（`0x8003` / `0x8010` / `0xB000` / `0x8001` の `0000`）を返し、
やり取りを先へ進める。デバイス情報とユーザー設定の応答は個体ごとの値なので用意していない。

**BC-768 本体へは一切書き込まない。** 通信相手は Android アプリだけ。

Health Planet が登録済みの BD アドレスでしか繋がない作りだと、Mac は無視される可能性がある。
その場合はアプリの機器登録（新規スキャン）から接続させることになる。ここは未検証。

## GUI

```bash
./scripts/make-app.sh
open .build/BC-768.app
```

「設定」「入力」「確認」「送信（CSV 書き出し）」のボタンと、取り込んだ記録の表がある。
設定は GUI の「BC-768 を登録する」から行える（UUID は自動で割り出す）。
CLI と同じ `~/.config/bc768-probe/env` を読み書きする。
記録は `~/Library/Application Support/bc768-probe/records.jsonl` に貯まり、CLI の `--out` と同じ形式。

## BC-768 側の操作

BC-768 は広告を出していないと接続できないため、本体側の操作が必要になる。

| 操作 | 用途 | 対応する Health Planet の画面 |
| --- | --- | --- |
| 電源を押す | `sync`（保持データの確認・取得） | HOME 画面 |
| 「入力モード」を押す | `measure`（測定） | 入力画面 |

設定/通信ボタンの長押しは通信設定用で、接続はできてもセッションが拒否され、
本体に `ErCP` が出て電源が落ちる（故障ではない）。

## 免責

- **非公式**のツールである。株式会社タニタとは一切関係がなく、同社の許諾も支援も受けていない。
  `TANITA` および `BC-768` は各権利者の商標・製品名。
- プロトコルの記述は、手元の機器と Android アプリの通信を観測して**推定**したもの。
  公式仕様ではなく、誤りを含む可能性がある。機器のファームウェアやアプリの更新で通用しなくなることもある。
- **無保証**。動作、正確性、安全性のいずれも保証しない。利用は自己責任で行うこと。
  機器の状態が変わったり、エラー表示が出て電源が落ちることがある（実際に `ErCP` を観測している）。
- 実装は既定で、**観測済みの payload しか送らない**。推測したデータ、空データ、ランダムデータは送らない。
  BC-768 の設定を書き換える可能性がある `0x1002` も送らない。
- 測定値の解釈のうち、体重・身長・体脂肪率・筋肉量・推定骨量・BMI は BMI と除脂肪量の検算で
  裏づけている。基礎代謝・体内年齢・内臓脂肪レベル・体水分率は**推定**で、表示に `(推定)` と付く。

## ライセンス

[MIT](LICENSE)
