import Foundation

/// 測定結果を JSON へ書き出すための表現。
///
/// 確定している項目はトップレベルに、検算できていない推定項目は `estimated` にまとめてある。
/// `raw` には受信 payload と TLV をそのまま入れるので、あとで解釈をやり直せる。
public struct BC768MeasurementRecord: Codable {
    public struct Estimated: Codable {
        /// BIA の抵抗成分（Ω）と推定。
        public let resistanceOhm: Double?
        /// BIA のリアクタンス成分（Ω）と推定。観測値は負。
        public let reactanceOhm: Double?
    }

    public struct Check: Codable {
        public let label: String
        public let computed: Double
        public let received: Double
        public let passed: Bool
    }

    public struct RawField: Codable {
        public let tag: String
        public let value: String
        public let label: String?
    }

    public struct Raw: Codable {
        public let command: String
        public let header: String?
        public let payload: String
        public let fields: [RawField]
        public let unparsed: String?
    }

    /// 測定日時。BC-768 が時計を持たないため、接続外で測定されたレコードでは null になる。
    public let measuredAt: String?
    /// このレコードを取得した時刻。
    public let retrievedAt: String
    /// 測定日時を持っているか。false なら測定時刻が不明で、最新かどうかも判断できない。
    public let hasTimestamp: Bool
    /// 0x3000 の応答が示した「タイムスタンプ付きで送信対象になるデータがあるか」。未取得なら null。
    public let sendPending: Bool?

    public let heightCm: Double?
    public let weightKg: Double?
    public let bmi: Double?
    public let bodyFatPercent: Double?
    public let muscleMassKg: Double?
    public let boneMassKg: Double?
    /// 体水分量。除脂肪量の 72〜74% になることで「率」ではなく「量」と確認した。
    public let bodyWaterKg: Double?
    public let basalMetabolismKcal: Double?
    public let metabolicAgeYears: Double?
    public let visceralFatLevel: Double?

    public let estimated: Estimated
    public let checks: [Check]
    public let raw: Raw

    /// ISO8601DateFormatter は Sendable ではないため、呼ぶたびに作る（頻度は低い）。
    public static func format(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = TimeZone.current
        return formatter.string(from: date)
    }

    public init(
        command: UInt16,
        payload: Data,
        parseResult: BC768TLV.ParseResult,
        sendPending: Bool?,
        retrievedAt: Date,
        calendar: Calendar = .current
    ) {
        let fields = parseResult.fields
        let measured = BC768DateTime.date(from: fields, calendar: calendar)

        measuredAt = measured.map { Self.format($0) }
        self.retrievedAt = Self.format(retrievedAt)
        hasTimestamp = BC768Record.hasTimestamp(fields)
        self.sendPending = sendPending

        heightCm = BC768Field.scaledValue(fields, tag: 0x6A3E)
        weightKg = BC768Field.scaledValue(fields, tag: 0x6021)
        bmi = BC768Field.scaledValue(fields, tag: 0x6056)
        bodyFatPercent = BC768Field.scaledValue(fields, tag: 0x6022)
        muscleMassKg = BC768Field.scaledValue(fields, tag: 0x6023)
        boneMassKg = BC768Field.scaledValue(fields, tag: 0x6029)
        bodyWaterKg = BC768Field.scaledValue(fields, tag: 0x6F21)
        basalMetabolismKcal = BC768Field.scaledValue(fields, tag: 0x6027)

        metabolicAgeYears = BC768Field.scaledValue(fields, tag: 0x6028)
        visceralFatLevel = BC768Field.scaledValue(fields, tag: 0x6025)

        estimated = Estimated(
            resistanceOhm: BC768Field.scaledValue(fields, tag: 0x614B),
            reactanceOhm: BC768Field.scaledValue(fields, tag: 0x614C)
        )

        checks = BC768Consistency.checks(for: fields).map {
            Check(label: $0.label, computed: $0.computed, received: $0.received, passed: $0.passed)
        }

        var unparsedHex: String?
        if case let .partial(_, unparsed) = parseResult, !unparsed.isEmpty {
            unparsedHex = unparsed.hexString
        }
        raw = Raw(
            command: String(format: "0x%04X", command),
            header: command == 0xB010 ? BC768Record.header(of: payload).map { String(format: "0x%04X", $0) } : nil,
            payload: payload.hexString,
            fields: fields.map {
                RawField(tag: $0.tagHex, value: $0.value.hexString, label: BC768Field.definitions[$0.tag]?.label)
            },
            unparsed: unparsedHex
        )
    }

    /// 新規の測定結果か。日時があり、かつ送信対象として立っているものだけを新規とみなす。
    /// BC-768 は引き取ると日時をクリアするため、この判定で重複も取り逃しも起きない。
    /// `sendPending` が取れていない場合（オフラインの `decode` など）は日時の有無だけで判断する。
    public var isNewMeasurement: Bool {
        guard hasTimestamp else { return false }
        return sendPending ?? true
    }

    /// JSON Lines の 1 行として出力する（改行なし）。
    public func jsonLine() throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        let data = try encoder.encode(self)
        return String(decoding: data, as: UTF8.self)
    }

    /// 人が読む用の整形 JSON。
    public func prettyJSON() throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes, .sortedKeys]
        let data = try encoder.encode(self)
        return String(decoding: data, as: UTF8.self)
    }
}
