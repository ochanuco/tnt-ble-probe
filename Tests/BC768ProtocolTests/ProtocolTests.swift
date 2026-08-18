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
