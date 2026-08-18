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
```

BC-768 側は、実行前に本体の**「入力モード」**を押して起動しておく。
設定/通信ボタンの長押しでは接続できてもセッションを拒否される（`ErCP` になる）。
BLE の Pairing / Bonding は不要（[docs/protocol.md](docs/protocol.md) 参照）。
終了は Ctrl+C（Notify 解除 → disconnect → cleanup を行ってから終了する）。

オプション一覧は `bc768-probe --help` を参照。

## 動かすために必要なもの

Service / Characteristic UUID とクライアント識別子は**このリポジトリに含まれていない**。
`.env`（git 管理外）に自分で用意する必要がある。設定がなければ、どの値が足りないかを表示して終了する。

UUID は手元の BC-768 に対して `bc768-probe scan --no-filter` や汎用の BLE ツールで確認できる。

## BC-768 側の操作

本体の**「入力モード」**を押して起動しておく。設定/通信ボタンの長押しでは接続はできても
セッションが拒否され、本体に `ErCP` が出て電源が落ちる（故障ではない）。

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
