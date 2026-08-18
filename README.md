# tnt-ble-probe

TANITA BC-768（体組成計）と macOS の BLE Pairing / GATT 通信を検証するための CLI `bc768-probe`。

- 仕様: [docs/BC-768_macOS_BLE_検証仕様書.md](docs/BC-768_macOS_BLE_検証仕様書.md)
- 実装の説明: [docs/implementation.md](docs/implementation.md)
- 検証結果: [docs/verification-log.md](docs/verification-log.md)

`scan` / `probe` は Scan / Connect / Discovery / Notify 購読 / ログまで。`handshake` は Android の
HCI キャプチャで確認済みの通信手順を送る。**推測した payload は一切送らない。**

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
```

BC-768 側は、実行前に「設定/通信」ボタンを約 3 秒長押しして待機状態にしておく。
待機状態でないと数秒で BC-768 側から切断される。BLE の Pairing / Bonding は不要
（[docs/protocol.md](docs/protocol.md) 参照）。
終了は Ctrl+C（Notify 解除 → disconnect → cleanup を行ってから終了する）。

オプション一覧は `bc768-probe --help` を参照。
