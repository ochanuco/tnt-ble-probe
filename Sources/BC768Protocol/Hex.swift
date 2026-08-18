import Foundation

extension Data {
    /// BLE の送受信データは必ず hex で残す。
    public var hexString: String {
        map { String(format: "%02x", $0) }.joined()
    }

    public var asciiPreview: String {
        map { byte -> String in
            (0x20...0x7e).contains(byte) ? String(UnicodeScalar(byte)) : "."
        }.joined()
    }

    public var decimalBytes: String {
        map { String($0) }.joined(separator: " ")
    }
}


public extension Data {
    /// "0a1b2c" 形式の文字列を Data へ変換する。奇数長や非 hex 文字を含む場合は nil。
    init?(hexString: String) {
        let cleaned = hexString.replacingOccurrences(of: " ", with: "")
        guard cleaned.count % 2 == 0 else { return nil }
        var bytes = [UInt8]()
        var index = cleaned.startIndex
        while index < cleaned.endIndex {
            let next = cleaned.index(index, offsetBy: 2)
            guard let byte = UInt8(cleaned[index..<next], radix: 16) else { return nil }
            bytes.append(byte)
            index = next
        }
        self = Data(bytes)
    }
}
