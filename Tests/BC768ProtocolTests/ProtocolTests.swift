import XCTest
@testable import BC768Protocol

/// 期待値は Android HCI キャプチャで実際に観測されたメッセージから取っている
/// （コマンドと定数のみ。個体情報を含む payload は使わない）。
final class ProtocolTests: XCTestCase {
    func testEncodeKnownMessages() {
        // → 0x0020 00 （デバイス情報の要求）
        XCTAssertEqual(BC768Message(command: 0x0020, payload: Data([0x00])).encoded().hexString, "000400200 0db".replacingOccurrences(of: " ", with: ""))
        // → 0x1000 00 （データ取得要求）
        XCTAssertEqual(BC768Message(command: 0x1000, payload: Data([0x00])).encoded().hexString, "000410000 0eb".replacingOccurrences(of: " ", with: ""))
        // → 0x3000 00 （完了通知）
        XCTAssertEqual(BC768Message(command: 0x3000, payload: Data([0x00])).encoded().hexString, "0004300000cb")
        // → 0x0001 00 （セッション終了）
        XCTAssertEqual(BC768Message(command: 0x0001, payload: Data([0x00])).encoded().hexString, "0004000100fa")
    }

    func testChecksumInvariant() {
        // メッセージ全バイトの総和の下位 8bit は必ず 0xFF になる。
        for command: UInt16 in [0x0001, 0x0003, 0x0010, 0x0020, 0x1000, 0x1002, 0x3000] {
            for length in 0...40 {
                let payload = Data((0..<length).map { UInt8(($0 &* 7) & 0xFF) })
                let encoded = BC768Message(command: command, payload: payload).encoded()
                XCTAssertEqual(encoded.reduce(UInt8(0)) { $0 &+ $1 }, 0xFF, "command=\(command) length=\(length)")
            }
        }
    }

    func testDecodeResponse() {
        // ← 0x8003 0000 （受理応答）
        let raw = Data([0x00, 0x05, 0x80, 0x03, 0x00, 0x00, 0x77])
        let decoded = BC768Message.decode(raw)
        XCTAssertNotNil(decoded)
        XCTAssertEqual(decoded?.message.command, 0x8003)
        XCTAssertEqual(decoded?.message.payload, Data([0x00, 0x00]))
        XCTAssertTrue(decoded?.checksumValid ?? false)
    }

    func testDecodeDetectsBrokenChecksum() {
        let raw = Data([0x00, 0x05, 0x80, 0x03, 0x00, 0x00, 0x78])
        XCTAssertEqual(BC768Message.decode(raw)?.checksumValid, false)
    }

    func testRoundTrip() {
        let payload = Data("00000000-0000-4000-8000-000000000000".utf8)
        let encoded = BC768Message(command: 0x0003, payload: payload).encoded()
        let decoded = BC768Message.decode(encoded)
        XCTAssertEqual(decoded?.message.command, 0x0003)
        XCTAssertEqual(decoded?.message.payload, payload)
        XCTAssertTrue(decoded?.checksumValid ?? false)
    }

    func testFragmentLayout() {
        // 36 文字の識別子を載せた 0x0003 は 41 バイト（= 0x27 + 2）になり 3 フラグメントへ分かれる。
        let message = BC768Message(command: 0x0003, payload: Data(String(repeating: "a", count: 36).utf8)).encoded()
        XCTAssertEqual(message.count, 41)
        let fragments = BC768Fragment.split(message, seq: 0x02, maxPayload: 20)
        XCTAssertEqual(fragments.count, 3)
        XCTAssertEqual(fragments[0].prefix(4).hexString, "00000210")
        XCTAssertEqual(fragments[1].prefix(4).hexString, "00100210")
        XCTAssertEqual(fragments[2].prefix(4).hexString, "00200209")
        XCTAssertEqual(fragments.map(\.count), [20, 20, 13])
    }

    func testReassemble() {
        let message = BC768Message(command: 0x9000, payload: Data((0..<43).map { UInt8($0) })).encoded()
        let fragments = BC768Fragment.split(message, seq: 0x02, maxPayload: 20)
        var reassembler = BC768Reassembler()
        var result: Data?
        for fragment in fragments {
            result = reassembler.append(fragment)
        }
        XCTAssertEqual(result, message)
        XCTAssertEqual(BC768Message.decode(result ?? Data())?.message.command, 0x9000)
    }

    func testReassembleIgnoresIncompleteMessage() {
        let message = BC768Message(command: 0x9000, payload: Data((0..<43).map { UInt8($0) })).encoded()
        let fragments = BC768Fragment.split(message, seq: 0x03, maxPayload: 20)
        var reassembler = BC768Reassembler()
        XCTAssertNil(reassembler.append(fragments[0]))
        XCTAssertNil(reassembler.append(fragments[1]))
    }

    func testSingleFragmentMessage() {
        let message = BC768Message(command: 0x0020, payload: Data([0x00])).encoded()
        let fragments = BC768Fragment.split(message, seq: 0x00, maxPayload: 20)
        XCTAssertEqual(fragments.count, 1)
        XCTAssertEqual(fragments[0].hexString, "00000006" + "0004002000db")
        var reassembler = BC768Reassembler()
        XCTAssertEqual(reassembler.append(fragments[0]), message)
    }
}

/// 日時エンコードの期待値は Android HCI キャプチャの実測から取っている
/// （日時そのものは個体情報ではない）。
final class DateTimeTests: XCTestCase {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Tokyo")!
        return calendar
    }

    private func date(_ y: Int, _ mo: Int, _ d: Int, _ h: Int, _ mi: Int, _ s: Int) -> Date {
        calendar.date(from: DateComponents(year: y, month: mo, day: d, hour: h, minute: mi, second: s))!
    }

    func testEncodeObservedSamples() {
        // 2026-08-18 23:39:59 → 6a32=0x25fe (9726 日), 6a33=0x02999e (170398 = 85199 秒 × 2)
        XCTAssertEqual(
            BC768DateTime.encode(date(2026, 8, 18, 23, 39, 59), calendar: calendar)?.hexString,
            "6a3225fe6a3302999e"
        )
        // 2026-08-19 01:53:08 → 日が 1 増え、時刻カウンタは当日 0 時起点に戻る
        XCTAssertEqual(
            BC768DateTime.encode(date(2026, 8, 19, 1, 53, 8), calendar: calendar)?.hexString,
            "6a3225ff6a33003508"
        )
        // 2026-08-19 01:50:07
        XCTAssertEqual(
            BC768DateTime.encode(date(2026, 8, 19, 1, 50, 7), calendar: calendar)?.hexString,
            "6a3225ff6a3300339e"
        )
    }

    func testEncodeStartOfEpoch() {
        XCTAssertEqual(
            BC768DateTime.encode(date(2000, 1, 1, 0, 0, 0), calendar: calendar)?.hexString,
            "6a3200006a33000000"
        )
    }

    func testRoundTrip() {
        for sample in [date(2026, 8, 18, 23, 39, 59), date(2026, 1, 1, 0, 0, 0), date(2030, 12, 31, 23, 59, 59)] {
            let encoded = BC768DateTime.encode(sample, calendar: calendar)
            XCTAssertNotNil(encoded)
            let decoded = try? XCTUnwrap(BC768DateTime.decode(encoded!, calendar: calendar))
            XCTAssertEqual(decoded?.timeIntervalSince1970 ?? -1, sample.timeIntervalSince1970, accuracy: 0.5)
        }
    }

    func testPayloadLengthMatchesObserved() {
        // 実測の 0x0010 payload は 9 バイト。
        XCTAssertEqual(BC768DateTime.encode(date(2026, 8, 19, 1, 53, 8), calendar: calendar)?.count, 9)
    }
}

/// TLV は「タグごとに value 長が決まっている」形式。実測データは使わず、
/// 既知タグを組み合わせた合成 payload で構造だけを検証する。
final class TLVTests: XCTestCase {
    func testParsesKnownTagsToEnd() {
        var payload = Data([0x00, 0x01])                       // 0xB010 のヘッダ相当
        payload.append(contentsOf: [0x6A, 0x32, 0x25, 0xFF])   // 2 バイト値
        payload.append(contentsOf: [0x6A, 0x33, 0x00, 0x35, 0x08]) // 3 バイト値
        payload.append(contentsOf: [0x60, 0x24, 0x03])         // 1 バイト値
        payload.append(contentsOf: [0x6A, 0x15, 0, 0, 0, 1])   // 4 バイト値

        guard case let .complete(fields) = BC768TLV.parse(payload, headerLength: 2) else {
            return XCTFail("末尾まで解釈できるはず")
        }
        XCTAssertEqual(fields.map(\.tag), [0x6A32, 0x6A33, 0x6024, 0x6A15])
        XCTAssertEqual(fields.map(\.value.count), [2, 3, 1, 4])
        XCTAssertEqual(fields[0].unsignedValue, 0x25FF)
        XCTAssertEqual(fields[3].unsignedValue, 1)
    }

    func testStopsAtUnknownTag() {
        var payload = Data([0x00])
        payload.append(contentsOf: [0x60, 0x24, 0x03])
        payload.append(contentsOf: [0xAA, 0xBB, 0x01, 0x02])   // 未知タグ
        guard case let .partial(fields, unparsed) = BC768TLV.parse(payload, headerLength: 1) else {
            return XCTFail("未知タグで打ち切るはず")
        }
        XCTAssertEqual(fields.map(\.tag), [0x6024])
        XCTAssertEqual(unparsed.hexString, "aabb0102")
    }

    func testSignedValue() {
        // インピーダンス系は負の値を取る。0xFE16 は -490。
        let field = BC768TLVField(tag: 0x614C, value: Data([0xFE, 0x16]))
        XCTAssertEqual(field.signedValue, -490)
        XCTAssertEqual(field.unsignedValue, 0xFE16)
    }

    func testAllMeasurementTagsHaveLengths() {
        // 意味を定義したタグは、長さ表にも載っていること。
        for tag in BC768Field.definitions.keys {
            XCTAssertNotNil(BC768TLV.valueLengths[tag], "tag \(String(format: "%04X", tag)) の長さ定義がない")
        }
    }
}

/// 検算ロジックの確認。値は架空のもの（実測データは含めない）。
final class ConsistencyTests: XCTestCase {
    /// 体重 70.00kg / 身長 175.0cm / 体脂肪率 20.0% / 筋肉量 52.90kg / 推定骨量 3.10kg
    private var fields: [BC768TLVField] {
        [
            BC768TLVField(tag: 0x6A3E, value: Data([0x06, 0xD6])),   // 1750 → 175.0 cm
            BC768TLVField(tag: 0x6021, value: Data([0x1B, 0x58])),   // 7000 → 70.00 kg
            BC768TLVField(tag: 0x6022, value: Data([0x00, 0xC8])),   // 200  → 20.0 %
            BC768TLVField(tag: 0x6023, value: Data([0x14, 0xAA])),   // 5290 → 52.90 kg
            BC768TLVField(tag: 0x6029, value: Data([0x01, 0x36])),   // 310  → 3.10 kg
            BC768TLVField(tag: 0x6056, value: Data([0x00, 0xE5])),   // 229  → 22.9
        ]
    }

    func testScaledValues() {
        XCTAssertEqual(BC768Field.scaledValue(fields, tag: 0x6021), 70.00)
        XCTAssertEqual(BC768Field.scaledValue(fields, tag: 0x6A3E), 175.0)
        XCTAssertEqual(BC768Field.scaledValue(fields, tag: 0x6022), 20.0)
    }

    func testBothChecksPass() {
        let checks = BC768Consistency.checks(for: fields)
        XCTAssertEqual(checks.count, 2)
        // BMI = 70 / 1.75^2 = 22.857…、受信値 22.9
        XCTAssertTrue(checks[0].passed, checks[0].description)
        // 除脂肪量 = 70 × 0.8 = 56.0、筋肉量 + 骨量 = 52.90 + 3.10 = 56.0
        XCTAssertTrue(checks[1].passed, checks[1].description)
    }

    func testDetectsInconsistency() {
        var broken = fields
        broken.removeAll { $0.tag == 0x6023 }
        // 筋肉量を 10kg 多い値に差し替えると除脂肪量の検算が破れる
        broken.append(BC768TLVField(tag: 0x6023, value: Data([0x18, 0x9C])))  // 63.00 kg
        let checks = BC768Consistency.checks(for: broken)
        XCTAssertTrue(checks.contains { !$0.passed })
    }

    func testChecksAreSkippedWhenFieldsMissing() {
        XCTAssertTrue(BC768Consistency.checks(for: []).isEmpty)
    }
}

/// 「取り出せるデータがあるか」「返ってきたレコードが有効か」の判定。
/// BC-768 はデータが無くても 0x3010 に応答し、前回値をそのまま返すため必要になる。
final class RecordTests: XCTestCase {
    func testHeader() {
        XCTAssertEqual(BC768Record.header(of: Data([0x00, 0x01, 0x6A])), 0x0001)
        XCTAssertEqual(BC768Record.header(of: Data([0x05, 0x01])), 0x0501)
        XCTAssertNil(BC768Record.header(of: Data([0x00])))
    }

    func testHasTimestampDetectsResidualRecord() {
        // 日付・時刻がゼロ → BC-768 に残っていた前回値
        let residual = [
            BC768TLVField(tag: 0x6A32, value: Data([0x00, 0x00])),
            BC768TLVField(tag: 0x6A33, value: Data([0x00, 0x00, 0x00])),
        ]
        XCTAssertFalse(BC768Record.hasTimestamp(residual))

        let fresh = [
            BC768TLVField(tag: 0x6A32, value: Data([0x25, 0xFF])),
            BC768TLVField(tag: 0x6A33, value: Data([0x00, 0x35, 0x08])),
        ]
        XCTAssertTrue(BC768Record.hasTimestamp(fresh))
    }

    func testHasTimestampNeedsBothZero() {
        // 片方だけゼロなら残留値とは判定しない
        let dayOnly = [
            BC768TLVField(tag: 0x6A32, value: Data([0x25, 0xFF])),
            BC768TLVField(tag: 0x6A33, value: Data([0x00, 0x00, 0x00])),
        ]
        XCTAssertTrue(BC768Record.hasTimestamp(dayOnly))
    }

    func testPendingData() {
        XCTAssertEqual(BC768Record.hasPendingData(Data([0x00, 0x00])), false)
        XCTAssertEqual(BC768Record.hasPendingData(Data([0x00, 0x01])), true)
        // 未知の値では判断しない
        XCTAssertNil(BC768Record.hasPendingData(Data([0x00, 0x02])))
        XCTAssertNil(BC768Record.hasPendingData(Data([0x00])))
    }
}

/// JSON 出力の形。値はすべて架空のもの（実測データは使わない）。
final class MeasurementRecordTests: XCTestCase {
    /// 架空の 0xB010 payload を組み立てる。
    private func payload(days: UInt16, halfSeconds: UInt32) -> Data {
        var data = Data([0x00, 0x01])                                   // ヘッダ
        data.append(contentsOf: [0x6A, 0x32, UInt8(days >> 8), UInt8(days & 0xFF)])
        data.append(contentsOf: [0x6A, 0x33,
                                 UInt8((halfSeconds >> 16) & 0xFF),
                                 UInt8((halfSeconds >> 8) & 0xFF),
                                 UInt8(halfSeconds & 0xFF)])
        data.append(contentsOf: [0x6A, 0x3E, 0x06, 0xD6])               // 175.0 cm
        data.append(contentsOf: [0x60, 0x21, 0x1B, 0x58])               // 70.00 kg
        data.append(contentsOf: [0x60, 0x56, 0x00, 0xE5])               // BMI 22.9
        data.append(contentsOf: [0x60, 0x22, 0x00, 0xC8])               // 20.0 %
        data.append(contentsOf: [0x60, 0x23, 0x14, 0xAA])               // 52.90 kg
        data.append(contentsOf: [0x60, 0x29, 0x01, 0x36])               // 3.10 kg
        data.append(contentsOf: [0x60, 0x27, 0x06, 0x40])               // 1600 kcal
        return data
    }

    private func record(days: UInt16, halfSeconds: UInt32, sendPending: Bool?) throws -> [String: Any] {
        let data = payload(days: days, halfSeconds: halfSeconds)
        let parsed = BC768TLV.parse(data, headerLength: 2)
        let record = BC768MeasurementRecord(
            command: 0xB010,
            payload: data,
            parseResult: parsed,
            sendPending: sendPending,
            retrievedAt: Date(timeIntervalSince1970: 1_800_000_000)
        )
        let json = try record.jsonLine()
        let object = try JSONSerialization.jsonObject(with: Data(json.utf8))
        return try XCTUnwrap(object as? [String: Any])
    }

    func testConfirmedValuesAtTopLevel() throws {
        // 2020-01-01 は 2000-01-01 から 7305 日。12:00:00 は 43200 秒 × 2。
        let dict = try record(days: 7305, halfSeconds: 86400, sendPending: true)
        XCTAssertEqual(dict["weightKg"] as? Double, 70.00)
        XCTAssertEqual(dict["heightCm"] as? Double, 175.0)
        XCTAssertEqual(dict["bodyFatPercent"] as? Double, 20.0)
        XCTAssertEqual(dict["muscleMassKg"] as? Double, 52.90)
        XCTAssertEqual(dict["boneMassKg"] as? Double, 3.10)
        XCTAssertEqual(dict["bmi"] as? Double, 22.9)
        XCTAssertEqual(dict["sendPending"] as? Bool, true)
        XCTAssertEqual(dict["hasTimestamp"] as? Bool, true)
        XCTAssertNotNil(dict["measuredAt"] as? String)
    }

    func testEstimatedValuesAreSeparated() throws {
        let dict = try record(days: 7305, halfSeconds: 86400, sendPending: true)
        let estimated = try XCTUnwrap(dict["estimated"] as? [String: Any])
        XCTAssertEqual(estimated["basalMetabolismKcal"] as? Double, 1600)
        // 推定項目はトップレベルへ出さない
        XCTAssertNil(dict["basalMetabolismKcal"])
    }

    func testTimestampIsNullWhenZero() throws {
        let dict = try record(days: 0, halfSeconds: 0, sendPending: false)
        XCTAssertEqual(dict["hasTimestamp"] as? Bool, false)
        XCTAssertTrue(dict["measuredAt"] is NSNull || dict["measuredAt"] == nil)
        // 値そのものは読める
        XCTAssertEqual(dict["weightKg"] as? Double, 70.00)
    }

    func testRawIsPreserved() throws {
        let dict = try record(days: 7305, halfSeconds: 86400, sendPending: nil)
        let raw = try XCTUnwrap(dict["raw"] as? [String: Any])
        XCTAssertEqual(raw["command"] as? String, "0xB010")
        XCTAssertEqual(raw["header"] as? String, "0x0001")
        XCTAssertEqual(raw["payload"] as? String, payload(days: 7305, halfSeconds: 86400).hexString)
        let fields = try XCTUnwrap(raw["fields"] as? [[String: Any]])
        XCTAssertEqual(fields.count, 9)
        XCTAssertEqual(fields.first?["tag"] as? String, "6A32")
    }

    func testChecksAreIncluded() throws {
        let dict = try record(days: 7305, halfSeconds: 86400, sendPending: true)
        let checks = try XCTUnwrap(dict["checks"] as? [[String: Any]])
        XCTAssertEqual(checks.count, 2)
        XCTAssertTrue(checks.allSatisfy { $0["passed"] as? Bool == true })
    }
}
