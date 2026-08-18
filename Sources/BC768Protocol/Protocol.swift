import Foundation

/// BC-768 独自プロトコルのメッセージ。
///
///     [total_length : 2 bytes BE]  command 以降のバイト数（checksum 含む）
///     [command      : 2 bytes BE]
///     [payload      : total_length - 3 bytes]
///     [checksum     : 1 byte]
///
/// checksum は「メッセージ全バイトの総和の下位 8bit が 0xFF になる」値。
/// 詳細は docs/protocol.md を参照。
public struct BC768Message {
    public init(command: UInt16, payload: Data) {
        self.command = command
        self.payload = payload
    }

    public let command: UInt16
    public let payload: Data

    /// 応答コマンドは要求コマンドに 0x8000 を立てたもの。
    public var expectedResponse: UInt16 { command | 0x8000 }

    public func encoded() -> Data {
        let totalLength = UInt16(2 + payload.count + 1)
        var bytes = Data()
        bytes.append(UInt8(totalLength >> 8))
        bytes.append(UInt8(totalLength & 0xFF))
        bytes.append(UInt8(command >> 8))
        bytes.append(UInt8(command & 0xFF))
        bytes.append(payload)
        bytes.append(Self.checksum(of: bytes))
        return bytes
    }

    public static func checksum(of bytes: Data) -> UInt8 {
        let sum = bytes.reduce(UInt8(0)) { $0 &+ $1 }
        return 0xFF &- sum
    }

    /// 再構成済みメッセージを解釈する。checksum が合わない場合も値は返し、検証結果を添える。
    public static func decode(_ data: Data) -> (message: BC768Message, checksumValid: Bool)? {
        guard data.count >= 5 else { return nil }
        let totalLength = Int(data[data.startIndex]) << 8 | Int(data[data.startIndex + 1])
        guard data.count >= totalLength + 2 else { return nil }
        let body = data.prefix(totalLength + 2)
        let command = UInt16(body[body.startIndex + 2]) << 8 | UInt16(body[body.startIndex + 3])
        let payloadRange = (body.startIndex + 4)..<(body.startIndex + totalLength + 1)
        let payload = payloadRange.isEmpty ? Data() : Data(body[payloadRange])
        let valid = body.reduce(UInt8(0)) { $0 &+ $1 } == 0xFF
        return (BC768Message(command: command, payload: payload), valid)
    }
}

/// 1 回の Write / Notification に載るフラグメント。
///
///     [fragment_offset : 2 bytes BE][message_seq : 1 byte][fragment_length : 1 byte][data]
public enum BC768Fragment {
    public static let headerSize = 4

    /// メッセージをフラグメントへ分割する。`maxPayload` は Characteristic 1 回分の最大書き込みバイト数。
    public static func split(_ message: Data, seq: UInt8, maxPayload: Int) -> [Data] {
        let chunkSize = max(1, maxPayload - headerSize)
        var fragments: [Data] = []
        var offset = 0
        while offset < message.count {
            let end = min(offset + chunkSize, message.count)
            let chunk = message[message.startIndex + offset..<message.startIndex + end]
            var fragment = Data()
            fragment.append(UInt8(offset >> 8))
            fragment.append(UInt8(offset & 0xFF))
            fragment.append(seq)
            fragment.append(UInt8(chunk.count))
            fragment.append(contentsOf: chunk)
            fragments.append(fragment)
            offset = end
        }
        return fragments
    }
}

/// 受信フラグメントを message_seq ごとに束ねてメッセージへ戻す。
public struct BC768Reassembler {
    public init() {}

    private var buffers: [UInt8: [Int: Data]] = [:]

    /// フラグメントを 1 つ受け取り、メッセージが完成したら返す。
    public mutating func append(_ fragment: Data) -> Data? {
        guard fragment.count >= BC768Fragment.headerSize else { return nil }
        let base = fragment.startIndex
        let offset = Int(fragment[base]) << 8 | Int(fragment[base + 1])
        let seq = fragment[base + 2]
        let length = Int(fragment[base + 3])
        let available = fragment.count - BC768Fragment.headerSize
        let data = Data(fragment[(base + BC768Fragment.headerSize)..<(base + BC768Fragment.headerSize + min(length, available))])

        buffers[seq, default: [:]][offset] = data

        guard let first = buffers[seq]?[0], first.count >= 2 else { return nil }
        let totalLength = Int(first[first.startIndex]) << 8 | Int(first[first.startIndex + 1])
        var assembled = Data()
        for key in buffers[seq]!.keys.sorted() {
            // 連続していないフラグメントがあれば未完成とみなす。
            guard key == assembled.count else { return nil }
            assembled.append(buffers[seq]![key]!)
        }
        guard assembled.count >= totalLength + 2 else { return nil }
        buffers.removeValue(forKey: seq)
        return assembled.prefix(totalLength + 2)
    }

    public mutating func reset() { buffers.removeAll() }
}
