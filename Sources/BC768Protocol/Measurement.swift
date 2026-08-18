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
        0x6A3C: Definition("生年月日?"),
        0x604F: Definition("年齢?"),
        0x6021: Definition("体重", divisor: 100, unit: "kg", confirmed: true),
        0x6022: Definition("体脂肪率", divisor: 10, unit: "%", confirmed: true),
        0x6023: Definition("筋肉量", divisor: 100, unit: "kg", confirmed: true),
        0x6025: Definition("内臓脂肪レベル?", divisor: 10),
        0x6027: Definition("基礎代謝?", unit: "kcal"),
        0x6028: Definition("体内年齢?", unit: "歳"),
        0x6029: Definition("推定骨量", divisor: 100, unit: "kg", confirmed: true),
        0x6056: Definition("BMI", divisor: 10, confirmed: true),
        0x6F21: Definition("体水分率?", divisor: 10, unit: "%"),
        0x6F22: Definition("インピーダンス?"),
        0x614B: Definition("インピーダンス?", signed: true),
        0x614C: Definition("インピーダンス?", signed: true),
    ]

    /// ログ表示用の 1 行を組み立てる。
    public static func describe(_ field: BC768TLVField) -> String {
        guard let definition = definitions[field.tag] else {
            return "\(field.tagHex)=<未知> raw=\(field.value.hexString)"
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
        return results
    }
}
