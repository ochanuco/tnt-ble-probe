# 検証ログ

UUID の実値と Peripheral 識別子は記載しない（論理名 / `<masked>` で表記する）。

## 2026-08-19 初回検証

### 環境

| 項目 | 値 |
| --- | --- |
| macOS | 26.6.1 (25G76) |
| Swift | 6.3.3 / Xcode 26.6 |
| 対象 | TANITA BC-768 |
| コマンド | `bc768-probe scan` / `bc768-probe probe --debug --wait 45` |

BC-768 側の「設定/通信」ボタン長押しは**未実施**（本体は広告を出している状態だった）。

### scan

Service UUID フィルタあり / なしのどちらでも BC-768 を検出できた。

```text
[SCAN]
name=BC-768
id=<masked>
rssi=-70
services=<SERVICE_UUID>
manufacturerData=nil
serviceData=nil
connectable=1
matchesServiceUUID=true
```

- 広告に `SERVICE_UUID` が含まれるため、名前に依存せず Service UUID で識別できる。
- Manufacturer Data / Service Data は広告されない。
- 広告される名前は `BC-768` の後に空白が付く。名前一致で判定してはいけない根拠のひとつ。

### probe — Phase 1

| 項目 | 結果 |
| --- | --- |
| Connect | 成功（約 0.7 秒） |
| Service Discovery | Service は 1 件のみ。`SERVICE_UUID` に一致 |
| Characteristic Discovery | 5 件すべて発見（`VERIFY: configured=5 found=5 missing=nil propertyMismatch=nil`） |

実測した Property は設定と一致した。

| 論理名 | Properties | Descriptors |
| --- | --- | --- |
| `WRITE_CHAR_1` | `writeWithoutResponse` | なし |
| `WRITE_CHAR_2` | `writeWithoutResponse` | なし |
| `NOTIFY_CHAR_1` | `notify` | `2902` (CCCD) |
| `NOTIFY_CHAR_2` | `notify` | `2902` (CCCD) |
| `NOTIFY_CHAR_3` | `notify` | `2902` (CCCD) |

`read` 可能な Characteristic は 1 つも存在しない。標準の Device Information Service 等も公開されていない。
したがって「read によって Pairing を誘発する」経路は BC-768 には存在しない。

**Phase 1 は達成。**

### probe — Phase 2（Case B: Notify 購読）

```text
[NOTIFY_STATE] logical=NOTIFY_CHAR_1 enabled=true error=nil
[NOTIFY_STATE] logical=NOTIFY_CHAR_2 enabled=true error=nil
[NOTIFY_STATE] logical=NOTIFY_CHAR_3 enabled=true error=nil
```

- CCCD への書き込みは 3 件ともエラーなしで成功した。**認証・暗号化は要求されなかった。**
- macOS の Pairing UI は表示されなかった。
- Notify は 1 件も受信しなかった。
- 購読の約 11 秒後、Peripheral 側から切断された。

```text
[DISCONNECTED]
error=The connection has timed out unexpectedly. (domain=CBErrorDomain code=6)
```

**Phase 2 は未達。**

### 考察

- BC-768 の Notify Characteristic には Security Requirement が設定されていない。CCCD 書き込みが素通りするため、
  **Notify 購読だけでは macOS 側の Pairing は誘発されない**（仕様書 Case B は否定された）。
- GATT に read 可能な属性がないため、read 経由での誘発も不可能。
- 残る誘発経路は `WRITE_CHAR_1` / `WRITE_CHAR_2` への Write（Case C）だが、正しい payload が確定するまで
  実行しない。推測データは送らない。
- そもそも BC-768 が BLE Legacy Pairing を要求しない可能性もある。その場合「Pairing 待機状態の終了」は
  BLE の Bonding ではなく、独自プロトコルのハンドシェイク（Write → Notify）の完了を指していることになる。

### 次に試すこと

1. BC-768 の「設定/通信」ボタンを約 3 秒長押しして Pairing 待機状態にしたうえで `probe` を再実行し、
   接続維持時間と切断理由が変わるかを見る。
2. 同条件で `probe --no-subscribe`（Case A）を実行し、Connect のみで本体側の待機状態が終了するかを比較する。
3. `--wait` を長めに取り、11 秒での切断が Peripheral 側のアイドルタイムアウトかどうかを確認する。
4. Android の HCI ログから測定開始 Write の payload が確定したら Case C を検討する（Phase 4）。

## 2026-08-19 追加検証（Pairing 待機状態あり）

BC-768 の「設定/通信」ボタンを約 3 秒長押しし、Pairing 待機状態にしてから実行した。

### 実行順と結果

| # | 条件 | コマンド | 接続維持時間 | 切断理由 |
| --- | --- | --- | --- | --- |
| 1 | 待機状態**なし**（前回） | `probe --wait 45` | 約 11 秒 | `CBError code=6` (Peripheral 側) |
| 2 | 待機状態**あり** | `probe --wait 60` | **60 秒（切断されず）** | `--wait` 経過による自主切断 |
| 3 | #2 の直後に再接続 | `probe --wait 40` | 約 4.6 秒 | `CBError code=6` (Peripheral 側) |

### #2（Pairing 待機状態あり・Case B）

- Phase 1 は #1 と同じく成功。Service / Characteristic 構成に差はない。
- Notify 3 件の購読はすべて `error=nil` で成功。ここでも認証・暗号化は要求されなかった。
- **macOS の Pairing UI は表示されなかった。**
- **Notify の受信は 0 件。**
- 60 秒間、Peripheral 側から切断されなかった。

### #3（再接続 = Bonding 確認）

- scan で再発見・再接続はできたが、約 4.6 秒で `CBError code=6` により Peripheral 側から切断された。
- Pairing 待機状態でないときの挙動（#1）と同じ。**Bonding は成立していない。**

### 分かったこと

- 接続を維持できるかどうかは Pairing 待機状態か否かで決まる。待機状態でなければ数秒〜十数秒で
  Peripheral 側から切断される。BC-768 のアイドルタイムアウトではなく、待機状態のゲートと考えられる。
- **Notify 購読は Pairing のトリガーにならない**（待機状態の有無にかかわらず CCCD 書き込みが素通りする）。
  仕様書 Case B は待機状態ありでも否定された。
- macOS の Pairing UI が一度も出ないことから、**BC-768 は BLE Legacy Pairing / Bonding を要求していない**
  と考えられる。仕様書が言う「Pairing 待機状態の終了」は BLE の Bonding ではなく、
  独自プロトコル（`WRITE_CHAR` への Write → `NOTIFY_CHAR` での応答）のハンドシェイク完了を指す可能性が高い。
- BC-768 は待機状態の間、Write を待っている。こちらから何も送らないため、Notify も返らない。

### 次に試すこと

1. Case A（`probe --no-subscribe`）を待機状態で実行し、Notify 購読の有無で接続維持時間が変わるか確認する。
   変わらなければ「Notify 購読は接続維持に無関係」が確定する。
2. Android の HCI キャプチャから、Health Planet が待機状態の BC-768 へ最初に送る Write payload を特定する。
   これが分かるまで Case C（Write）は実行しない。
3. payload が確定したら、`WRITE_CHAR_1` / `WRITE_CHAR_2` への Write を実装し（Write Logger 付き）、
   Notify の応答を raw で記録する（Phase 4）。

## 2026-08-19 追加検証（Case A: Connect のみ）

Pairing 待機状態にしたうえで `probe --no-subscribe --debug --wait 60` を実行した。Notify 購読も Write も行わない。

| # | 条件 | 接続維持時間 | 切断理由 |
| --- | --- | --- | --- |
| 2 | 待機状態あり + Notify 購読（Case B） | 60 秒（切断されず） | `--wait` 経過による自主切断 |
| 4 | 待機状態あり + **購読なし**（Case A） | **60 秒（切断されず）** | `--wait` 経過による自主切断 |

- Phase 1 は同様に成功。
- Notify 購読を行わなくても、待機状態であれば 60 秒間切断されなかった。
- macOS の Pairing UI は表示されず、Notify も 0 件（購読していないので当然）。

### 結論（Pairing 検証 Case A / B）

| 観点 | 結果 |
| --- | --- |
| 接続維持を決めるもの | **BC-768 の Pairing 待機状態のみ**。Notify 購読の有無は無関係 |
| Notify 購読による Pairing 誘発 | **発生しない**（Case B 否定） |
| Connect のみによる待機状態の終了 | **発生しない**（Case A 否定） |
| macOS の Pairing UI | 一度も表示されない |
| Bonding | 成立しない（再接続時に待機状態なしと同じ挙動へ戻る） |

BC-768 は GATT レベルの Security Requirement を一切設定していない。CoreBluetooth 側から
「アクセスによって Pairing を誘発する」経路（read / notify）は存在せず、read 可能な Characteristic も無い。

したがって残る経路は `WRITE_CHAR_1` / `WRITE_CHAR_2` への Write（Case C / Phase 4）のみ。
正しい payload が Android HCI ログから確定するまで実行しない。

仕様書 22 の Phase 2「Notify enable → macOS Pairing 開始 → BC-768 Pairing 待機終了」は、
**成立しない前提だったと結論づける**。Phase 3（Bonding 済み再接続）も同じ理由で現状は到達不能。

## 2026-08-19 handshake の実機検証

`docs/protocol.md` で特定した手順を実際に送った。送ったのは HCI ログで観測済みの payload のみ。

### 確定したこと

| 項目 | 結果 |
| --- | --- |
| 送信先 Characteristic | **`WRITE_CHAR_1`**（HCI ログの ATT handle `0x001A` に対応） |
| 通知元 Characteristic | **`NOTIFY_CHAR_3`**（同 `0x0017`。CCCD は `0x0018`） |
| フラグメント / チェックサム | 実機で受理された。プロトコル解析は正しい |
| `0x0003` の送信 | 3 フラグメントに分割して送信し、**応答 `0x8003` が返った** |

Notify は 3 本購読していたが、実際に通知が来たのは `NOTIFY_CHAR_3` だけだった。
HCI ログで Android が 1 本しか購読していなかったことと一致する。

### 詰まっているところ

```text
→ 0x0003 <client id>   ← 0x8003 payload=0701   （Android は 4 セッションとも payload=0000）
→ 0x0010 <payload>     ← 応答なし → 約 3 秒後に BC-768 側から切断（CBError code=7）
```

`0x8003` の payload が Android と異なる。2 回実行して同じ結果になった（再現性あり）。

### 判明した BC-768 の広告条件

長押しをしていない状態では **BC-768 は広告を出さない**（Service UUID フィルタありの scan で 150 秒 0 件）。
接続できるのはボタン操作をした後だけ。

### 仮説と次に試すこと

`0701` が何を意味するかは未確定。差分として残っているのは以下。

1. **Notify の購読本数**。Android は 1 本のみ、こちらは 3 本購読していた
   → `--notify-char notify3` で Android と揃えられるようにした。
2. **タイミング**。Android は接続から CCCD 書き込みまで約 1.6 秒、そこから `0x0003` まで約 0.2 秒。
   こちらは接続から 0.3 秒で送っている → `--handshake-delay` で待てるようにした。
3. **BC-768 の動作モード**。長押しで入るモードと、Android がデータ送信していたモードが
   違う可能性がある。Android のキャプチャがどちらの状態で取られたかは未確認。
4. `0x0010` の payload に含まれるカウンタ。HCI ログの 4 セッションを比べると
   **0.5 秒刻み（2 カウント/秒）で単調増加**していた。基準時刻が不明なため現状は古い値をそのまま送っている。
   ただし `0x0003` の時点で応答が異なるため、これは直接の原因ではない。
