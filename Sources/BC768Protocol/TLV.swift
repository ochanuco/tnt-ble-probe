import Foundation

/// BC-768 の payload に現れる TLV フィールド。
/// 形式は `<tag : 2 bytes BE><value : タグごとに決まった固定長>`。長さフィールドは存在しない。
public struct BC768TLVField: Sendable {
    public let tag: UInt16
    public let value: Data

    public init(tag: UInt16, value: Data) {
        self.tag = tag
        self.value = value
    }

    public var tagHex: String { String(format: "%04X", tag) }

    /// value をビッグエンディアン符号なし整数として読む。
    public var unsignedValue: UInt32 {
        value.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
    }

    /// value をビッグエンディアン符号付き整数として読む（インピーダンス系は負の値を取る）。
    public var signedValue: Int32 {
        guard let first = value.first else { return 0 }
        var result = Int32(Int8(bitPattern: first))
        for byte in value.dropFirst() {
            result = (result << 8) | Int32(byte)
        }
        return result
    }
}

public enum BC768TLV {
    /// タグごとの value 長。Android HCI キャプチャと macOS 実測の測定結果 / 設定応答から確定した。
    /// 0xB010（87 バイト）と 0x9000（43 バイト）の全長がこの表で誤差なく再現できることを確認済み。
    public static let valueLengths: [UInt16: Int] = [
        // 日時・身体設定系
        0x6A32: 2, 0x6A33: 3, 0x6A37: 1, 0x6A38: 1, 0x6A3B: 1, 0x6A3C: 2, 0x6A3E: 2,
        0x6A13: 1, 0x6A15: 4, 0x7E22: 1,
        // 測定値系
        0x6021: 2, 0x6022: 2, 0x6023: 2, 0x6024: 1, 0x6025: 2, 0x6027: 2, 0x6028: 1,
        0x6029: 2, 0x602F: 2, 0x604F: 2, 0x6056: 2, 0x605A: 1, 0x6070: 1, 0x6077: 1, 0x607D: 1,
        // インピーダンス系
        0x614B: 2, 0x614C: 2, 0x6F21: 2, 0x6F22: 2,
    ]

    public enum ParseResult {
        /// 末尾まで既知タグで解釈できた。
        case complete([BC768TLVField])
        /// 未知タグに当たって打ち切った。長さが分からないため以降は解釈しない。
        case partial(fields: [BC768TLVField], unparsed: Data)

        public var fields: [BC768TLVField] {
            switch self {
            case let .complete(fields): return fields
            case let .partial(fields, _): return fields
            }
        }
    }

    /// `headerLength` バイトのヘッダを飛ばして TLV を読む
    /// （0xB010 は 2 バイト、0x9000 は 1 バイトのヘッダを持つ）。
    public static func parse(_ payload: Data, headerLength: Int) -> ParseResult {
        var fields: [BC768TLVField] = []
        var index = payload.startIndex + headerLength
        guard index <= payload.endIndex else { return .partial(fields: [], unparsed: payload) }

        while index < payload.endIndex {
            guard index + 2 <= payload.endIndex else {
                return .partial(fields: fields, unparsed: Data(payload[index...]))
            }
            let tag = UInt16(payload[index]) << 8 | UInt16(payload[index + 1])
            guard let length = valueLengths[tag], index + 2 + length <= payload.endIndex else {
                return .partial(fields: fields, unparsed: Data(payload[index...]))
            }
            let value = Data(payload[(index + 2)..<(index + 2 + length)])
            fields.append(BC768TLVField(tag: tag, value: value))
            index += 2 + length
        }
        return .complete(fields)
    }
}
