# BC-768 BLE プロトコル（Android HCI キャプチャからの解析結果）

Health Planet (Android) と BC-768 の Bluetooth HCI キャプチャを解析して得た通信仕様。
キャプチャそのもの、UUID 実値、端末識別子、測定値は本ドキュメントに含めない（すべて git 管理外に置く）。

解析対象は 4 セッション、再構成できたメッセージ 68 件すべてでチェックサムが一致した。

## 1. Pairing は不要

**最も重要な発見。BC-768 との通信に BLE の Pairing / Bonding は必要ない。**

| 観測 | 内容 |
| --- | --- |
| `HCI_Encryption_Change` | キャプチャ全体で **0 件**。Android 側も暗号化していない |
| SMP | BC-768 → Android の `Security Request` (`0x0B`, AuthReq=`0x01`) が接続ごとに 1 回。**Android は応答していない** |
| ATT | すべて平文。認証エラー (`InsufficientAuthentication`) は 1 件も発生していない |

BC-768 は接続直後に Security Request を送るが、これを無視したまま GATT 通信が最後まで成立している。
macOS 側の検証（`verification-log.md`）で Pairing UI が出ず、Notify 購読も素通りしたのと整合する。

「Pairing 待機状態」は BLE の Pairing ではなく、**独自プロトコルのハンドシェイクを受け付ける状態**を指す。

## 2. 使用する属性

Android は Service 内の 5 つの Characteristic のうち、実際には 2 つしか使っていない。

| ATT handle | 役割 | 使用回数 |
| --- | --- | --- |
| `0x0017` | Notification 送信元（`NOTIFY_CHAR` のいずれか 1 本） | 75 |
| `0x0018` | `0x0017` の CCCD。`0x0001` を Write Request で書いて Notify 有効化 | 4 |
| `0x001A` | Write Command 送信先（`WRITE_CHAR` のいずれか 1 本） | 58 |

キャプチャに GATT Discovery が含まれていない（Android がキャッシュ済み）ため、
**handle と UUID の対応は未確定**。`WRITE_CHAR_1` / `WRITE_CHAR_2` のどちらへ書くかは実機で確かめる必要がある。
Notify 側は 3 本すべて購読しておけばどれに来ても受信できる。

書き込みはすべて Write Command（Write Without Response）。ATT MTU は既定の 23 のまま
（MTU 交換なし）なので、1 パケットのペイロードは 20 バイト。

## 3. フレーム構造

Characteristic 1 回の書き込み / 通知は、メッセージのフラグメント 1 個に相当する。

```text
[fragment_offset : 2 bytes, big endian]
[message_seq     : 1 byte ]
[fragment_length : 1 byte ]
[fragment_data   : fragment_length bytes]   ← 最大 16 バイト
```

- `fragment_offset` は再構成後メッセージ内のバイトオフセット。`0x0000`, `0x0010`, `0x0020` … と 16 ずつ増える。
- `message_seq` は複数フラグメントに分かれるメッセージを束ねる通番。1 フラグメントで収まる場合は `0x00`。
- 受信側は `fragment_offset` 順に `fragment_data` を連結する。

## 4. メッセージ構造

フラグメントを連結すると以下になる。

```text
[total_length : 2 bytes, big endian]   ← command 以降のバイト数（checksum を含む）
[command      : 2 bytes, big endian]
[payload      : total_length - 3 bytes]
[checksum     : 1 byte]
```

### チェックサム

```text
checksum = 0xFF - (sum(total_length .. payload の全バイト) & 0xFF)
```

言い換えると、**メッセージ全バイトの総和の下位 8 bit が必ず `0xFF` になる**。
再構成した 68 メッセージすべてでこの式が成立した。

## 5. コマンド

応答コマンドは要求コマンドに `0x8000` を立てたもの（`0x1000` 系は `0x9000`、`0x3000` は `0xB000`）。
正常応答の payload は `0x0000`。

| 方向 | command | payload | 意味（推定） |
| --- | --- | --- | --- |
| → | `0x0003` | ASCII 36 文字の UUID 文字列 | クライアント識別子の提示。ハンドシェイクの開始 |
| ← | `0x8003` | `0000` | 受理 |
| → | `0x0010` | 9 バイト（TLV） | セッション情報の設定 |
| ← | `0x8010` | `0000` | 受理 |
| → | `0x0020` | `00` | デバイス情報の要求 |
| ← | `0x8020` | 57 バイト（TLV。モデル名 `BC-768` を含む） | デバイス情報 |
| → | `0x1000` | `00` | データ取得要求 |
| ← | `0x9000` | 43 バイト（TLV） | データ応答 |
| → | `0x1002` | 64 バイト（TLV） | データ書き込み / 設定 |
| ← | `0x9002` | 43 バイト（TLV） | 応答 |
| → | `0x3000` | `00` | 完了通知 |
| ← | `0xB000` | `0000` | 受理 |
| → | `0x0001` | `00` | セッション終了 |
| ← | `0x8001` | `0000` | 受理 |

### 典型的なセッション

```text
LE Connection Complete
  ← SMP Security Request        （無視してよい）
  → Write Request  CCCD = 0x0001（Notify 有効化）
  → 0x0003 <client uuid>   ← 0x8003
  → 0x0010 <9 bytes>       ← 0x8010
  → 0x0020 00              ← 0x8020 <device info>
  → 0x1000 00              ← 0x9000 <data>
  → 0x1002 <64 bytes>      ← 0x9002 <data>
  → 0x3000 00              ← 0xB000
  → 0x0001 00              ← 0x8001
Disconnect (reason 0x08 Connection Timeout)
```

1 セッションは約 6 秒。切断は毎回 BC-768 側のタイムアウト（`reason=0x08`）で、正常終了でも同様。

## 6. payload の TLV

payload は `<tag:2 bytes><value>` の並びに見える。tag の先頭バイトは `0x6A` または `0x7E`。
value 長は tag ごとに固定（2 / 3 / 5 バイトなど）。個々の tag の意味は未解析で、
体組成値のデコード（Phase 4 以降）で扱う。

## 7. macOS 実装への含意

1. **Pairing を成立させる必要はない。** 仕様書 Phase 2 / Phase 3 は目的として不要になった。
2. Notify 3 本を購読したうえで、`WRITE_CHAR` へ `0x0003` から始まるハンドシェイクを送れば応答が返るはず。
3. 送信先が `WRITE_CHAR_1` / `WRITE_CHAR_2` のどちらかは実機で確認する。誤った方へ書いても、
   送るのは HCI ログで確認済みの正規 payload であり、推測データではない。
4. クライアント識別子（`0x0003` の 36 文字）は Android アプリが生成した UUID。
   macOS から別の UUID を送って受理されるかは未検証。
