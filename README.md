# tnt-ble-probe

TANITA BC-768（体組成計）と macOS の BLE Pairing / GATT 通信を検証するための CLI `bc768-probe`。

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

# ログに残した hex を後から解釈する（BLE 不要）
.build/debug/bc768-probe decode --command B010 <payload hex>
```

BC-768 側は、実行前に本体の**「入力モード」**を押して起動しておく。
設定/通信ボタンの長押しでは接続できてもセッションを拒否される（`ErCP` になる）。
BLE の Pairing / Bonding は不要（[docs/protocol.md](docs/protocol.md) 参照）。
終了は Ctrl+C（Notify 解除 → disconnect → cleanup を行ってから終了する）。

オプション一覧は `bc768-probe --help` を参照。
