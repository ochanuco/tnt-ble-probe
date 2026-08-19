import Foundation

/// TLV フィールドを人が読める形へ直す。
///
/// **注意**: ラベルと係数の大半はまだ推定である。3 サンプル間の差分と、身長・体重から計算した
/// BMI・除脂肪量との整合から当てたもので、Health Planet の表示値との答え合わせは済んでいない。
/// 確定済みのものだけ `confirmed == true` にしてある。
public enum BC768Field {
    public struct Definition: Sendable {
        public let label: String
        /// 生値をこの数で割る。
        public let divisor: Double
        public let unit: String
        public let signed: Bool
        /// 答え合わせ済みかどうか。false は推定。
        public let confirmed: Bool

        init(_ label: String, divisor: Double = 1, unit: String = "", signed: Bool = false, confirmed: Bool = false) {
            self.label = label
            self.divisor = divisor
            self.unit = unit
            self.signed = signed
            self.confirmed = confirmed
        }
    }

    public static let definitions: [UInt16: Definition] = [
        // --- 確定済み（HCI キャプチャの送信時刻と秒単位まで一致） ---
        0x6A32: Definition("日付（2000-01-01 起点の日数）", confirmed: true),
        0x6A33: Definition("時刻（0.5 秒単位）", confirmed: true),
        // --- 推定 ---
        0x6A3E: Definition("身長", divisor: 10, unit: "cm", confirmed: true),
        0x6A13: Definition("性別?"),
        0x6A15: Definition("ユーザー番号?"),
        0x6A3C: Definition("生年月日（1899-12-31 起点の日数）", confirmed: true),
        // 実際の年齢と合わないため「年齢」ではない。値 50 の意味は不明。
        0x604F: Definition("不明"),
        0x6021: Definition("体重", divisor: 100, unit: "kg", confirmed: true),
        0x6022: Definition("体脂肪率", divisor: 10, unit: "%", confirmed: true),
        0x6023: Definition("筋肉量", divisor: 100, unit: "kg", confirmed: true),
        0x6025: Definition("内臓脂肪レベル", divisor: 10, confirmed: true),
        0x6027: Definition("基礎代謝", unit: "kcal", confirmed: true),
        0x6028: Definition("体内年齢", unit: "歳", confirmed: true),
        0x6029: Definition("推定骨量", divisor: 100, unit: "kg", confirmed: true),
        0x6056: Definition("BMI", divisor: 10, confirmed: true),
        0x6F21: Definition("体水分量", divisor: 10, unit: "kg", confirmed: true),
        0x6F22: Definition("不明（ほぼ一定）"),
        // Health Planet に「筋肉スコア」という項目がある。6024 と 6077 のどちらかが該当するが、
        // どの測定でも両方 3 のままなので区別できていない。
        0x6024: Definition("判定値または筋肉スコア?"),
        0x6077: Definition("判定値または筋肉スコア?"),
        0x614B: Definition("抵抗 R?", divisor: 10, unit: "Ω", signed: true),
        0x614C: Definition("リアクタンス Xc?", divisor: 10, unit: "Ω", signed: true),
    ]

    /// ログ表示用の 1 行を組み立てる。
    public static func describe(_ field: BC768TLVField) -> String {
        guard let definition = definitions[field.tag] else {
            return "\(field.tagHex)=<未知> raw=\(field.value.hexString)"
        }
        // 日数のままでは読めないので、カレンダー日付にして出す。
        if field.tag == 0x6A3C, let date = BC768DateTime.birthDate(days: Int(field.unsignedValue)) {
            return "\(definition.label)=\(Self.dayFormatter.string(from: date)) [tag=\(field.tagHex) raw=\(field.value.hexString)]"
        }
        if field.tag == 0x6A32,
           let date = BC768DateTime.date(days: Int(field.unsignedValue), halfSeconds: 0),
           field.unsignedValue > 0 {
            return "\(definition.label)=\(Self.dayFormatter.string(from: date)) [tag=\(field.tagHex) raw=\(field.value.hexString)]"
        }
        let raw = definition.signed ? Double(field.signedValue) : Double(field.unsignedValue)
        let scaled = raw / definition.divisor
        let formatted = definition.divisor == 1
            ? String(Int(scaled))
            : String(format: "%.\(decimals(for: definition.divisor))f", scaled)
        let mark = definition.confirmed ? "" : " (推定)"
        let unit = definition.unit.isEmpty ? "" : " \(definition.unit)"
        return "\(definition.label)=\(formatted)\(unit)\(mark) [tag=\(field.tagHex) raw=\(field.value.hexString)]"
    }

    /// 日付だけを出す整形。DateFormatter は Sendable ではないため都度作る（呼ばれる頻度は低い）。
    private static var dayFormatter: DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }

    private static func decimals(for divisor: Double) -> Int {
        divisor >= 100 ? 2 : 1
    }

    /// 値を取り出す（スケール適用後）。
    public static func scaledValue(_ fields: [BC768TLVField], tag: UInt16) -> Double? {
        guard let field = fields.first(where: { $0.tag == tag }),
              let definition = definitions[tag] else { return nil }
        let raw = definition.signed ? Double(field.signedValue) : Double(field.unsignedValue)
        return raw / definition.divisor
    }
}

/// デコード結果が物理的に整合しているかを確かめる。
/// ラベル付けの裏付けであり、この 2 つが合えば体重・身長・体脂肪率・筋肉量・骨量の解釈は正しい。
public enum BC768Consistency {
    public struct Check {
        public let label: String
        public let computed: Double
        public let received: Double
        public let tolerance: Double

        public var passed: Bool { abs(computed - received) <= tolerance }

        public var description: String {
            let mark = passed ? "一致" : "不一致"
            return String(format: "%@: 計算値 %.2f / 受信値 %.2f → %@", label, computed, received, mark)
        }
    }

    public static func checks(for fields: [BC768TLVField]) -> [Check] {
        var results: [Check] = []
        let weight = BC768Field.scaledValue(fields, tag: 0x6021)
        let height = BC768Field.scaledValue(fields, tag: 0x6A3E)
        let fatPercent = BC768Field.scaledValue(fields, tag: 0x6022)
        let muscle = BC768Field.scaledValue(fields, tag: 0x6023)
        let bone = BC768Field.scaledValue(fields, tag: 0x6029)
        let bmi = BC768Field.scaledValue(fields, tag: 0x6056)

        if let weight, let height, let bmi, height > 0 {
            let meters = height / 100
            results.append(Check(label: "BMI = 体重 / 身長^2",
                                 computed: weight / (meters * meters),
                                 received: bmi,
                                 tolerance: 0.15))
        }
        if let weight, let fatPercent, let muscle, let bone {
            results.append(Check(label: "除脂肪量 = 体重 x (1 - 体脂肪率) ≒ 筋肉量 + 推定骨量",
                                 computed: weight * (1 - fatPercent / 100),
                                 received: muscle + bone,
                                 tolerance: 0.15))
        }
        // 体水分量は除脂肪組織の 72〜74%。この関係が成り立つことで
        // 6F21 が「率(%)」ではなく「量(kg)」だと判断できる。
        if let muscle, let bone, let water = BC768Field.scaledValue(fields, tag: 0x6F21) {
            let lean = muscle + bone
            results.append(Check(label: "体水分量 / 除脂肪量 = 0.72〜0.75",
                                 computed: water / lean,
                                 received: 0.735,
                                 tolerance: 0.02))
        }
        // 基礎代謝は筋肉量に比例する（実測 30.13 kcal/kg、4 サンプルで ±0.02%）。
        if let muscle, let bmr = BC768Field.scaledValue(fields, tag: 0x6027), muscle > 0 {
            results.append(Check(label: "基礎代謝 / 筋肉量 = 30.1 kcal/kg",
                                 computed: bmr / muscle,
                                 received: 30.13,
                                 tolerance: 0.3))
        }
        return results
    }
}

/// 測定結果レコード（`0xB010`）の妥当性判定。
///
/// BC-768 は最後の測定値をバッファに保持しており、**取り出せるデータが無くても `0x3010` に応答する**。
/// その場合 payload の日付・時刻がともに 0 になり、先頭ヘッダの値も変わる。
/// 日時がゼロのレコードを新しい測定結果として扱ってはいけない。
public enum BC768Record {
    /// `0xB010` payload の先頭 2 バイト。測定直後は `0x0001`、残留値では `0x0501` を観測している。
    public static func header(of payload: Data) -> UInt16? {
        guard payload.count >= 2 else { return nil }
        let base = payload.startIndex
        return UInt16(payload[base]) << 8 | UInt16(payload[base + 1])
    }

    /// 日付・時刻が入っているか。ゼロなら BC-768 に残っていた前回値。
    public static func hasTimestamp(_ fields: [BC768TLVField]) -> Bool {
        let days = fields.first { $0.tag == 0x6A32 }?.unsignedValue ?? 0
        let halfSeconds = fields.first { $0.tag == 0x6A33 }?.unsignedValue ?? 0
        return !(days == 0 && halfSeconds == 0)
    }

    /// `0xB010` payload 先頭 2 バイトの下位バイト。`0x3010` で要求したレコード番号と一致する。
    /// 上位バイトは `0x00`（通常）と `0x05`（残留値）を観測している。
    public static func recordIndex(of payload: Data) -> Int? {
        header(of: payload).map { Int($0 & 0xFF) }
    }

    /// `0x3000` の応答（`0xB000`）payload が示す**保持件数**。
    /// 実測値は 0 / 1 / 2 で、本体だけで 2 回測ったときに 2 が返った。
    public static func pendingCount(_ payload: Data) -> Int? {
        guard payload.count >= 2 else { return nil }
        let base = payload.startIndex
        return Int(payload[base]) << 8 | Int(payload[base + 1])
    }

    /// 取り出せるデータがあるか（件数が 1 以上か）。
    public static func hasPendingData(_ payload: Data) -> Bool? {
        pendingCount(payload).map { $0 > 0 }
    }
}

/// 応答 payload が示す状態。
///
/// 2 バイトの payload を返す応答は状態コードで、`0x0000` が正常。
/// `0xB000` だけは `0x0001` が「送信対象データあり」を意味するため別扱いにする。
public enum BC768ResponseStatus: Equatable {
    case ok
    /// 0x8003 payload=0001。BC-768 に登録されていないクライアント識別子。
    case unregisteredClient
    /// 0x8003 payload=0701。BC-768 が設定/通信モードで、セッションを受け付けない。
    case wrongMode
    /// 意味の分かっていない状態コード。
    case unknown(UInt16)

    public var isOK: Bool { self == .ok }

    public var explanation: String {
        switch self {
        case .ok:
            return "正常"
        case .unregisteredClient:
            return "このクライアント識別子は BC-768 に登録されていません。Health Planet が使っている識別子が必要です"
        case .wrongMode:
            return "BC-768 が設定/通信モードです。電源または入力モードで起動し直してください"
        case let .unknown(code):
            return String(format: "未知の状態コード 0x%04X", code)
        }
    }

    /// 応答を解釈する。データを返す応答（0x8020 など）は対象外なので nil を返す。
    public static func status(command: UInt16, payload: Data) -> BC768ResponseStatus? {
        // 0xB000 は 0000/0001 のどちらも正常。判定は BC768Record.hasPendingData が担う。
        guard command != 0xB000 else { return nil }
        guard payload.count == 2 else { return nil }
        let base = payload.startIndex
        let code = UInt16(payload[base]) << 8 | UInt16(payload[base + 1])
        switch code {
        case 0x0000: return .ok
        case 0x0001 where command == 0x8003: return .unregisteredClient
        case 0x0701 where command == 0x8003: return .wrongMode
        default: return .unknown(code)
        }
    }
}
