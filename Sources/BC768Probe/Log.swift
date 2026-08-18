import Foundation

enum LogLevel: Int, Comparable {
    case error = 0
    case info = 1
    case debug = 2

    static func < (lhs: LogLevel, rhs: LogLevel) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// 観測可能性と再現性を最優先するための、単純な行指向ロガー。
/// BLE のイベントは `[TAG]` + `key=value` 行の形式で出力する。
enum Log {
    nonisolated(unsafe) static var level: LogLevel = .info

    private static let lock = NSLock()

    private static let timestampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSSXXXXX"
        return f
    }()

    static func timestamp(_ date: Date = Date()) -> String {
        timestampFormatter.string(from: date)
    }

    static func info(_ message: String) { write(.info, message, toStderr: false) }
    static func debug(_ message: String) { write(.debug, message, toStderr: false) }
    static func error(_ message: String) { write(.error, "ERROR " + message, toStderr: true) }

    /// 仕様書のログ書式に合わせたイベント出力。
    ///
    ///     [SCAN]
    ///     name=<peripheral name>
    ///     rssi=-48
    static func event(_ tag: String, _ fields: [(String, String?)], level eventLevel: LogLevel = .info) {
        guard eventLevel <= level else { return }
        var text = "[\(tag)]\n"
        text += "timestamp=\(timestamp())\n"
        for (key, value) in fields {
            text += "\(key)=\(value ?? "nil")\n"
        }
        write(eventLevel, text, toStderr: false, newline: false)
    }

    private static func write(_ messageLevel: LogLevel, _ message: String, toStderr: Bool, newline: Bool = true) {
        guard messageLevel <= level else { return }
        lock.lock()
        defer { lock.unlock() }
        let line = newline ? message + "\n" : message
        if toStderr {
            FileHandle.standardError.write(Data(line.utf8))
        } else {
            FileHandle.standardOutput.write(Data(line.utf8))
        }
    }
}

extension Data {
    /// BLE の送受信データは必ず hex で残す。
    var hexString: String {
        map { String(format: "%02x", $0) }.joined()
    }

    var asciiPreview: String {
        map { byte -> String in
            (0x20...0x7e).contains(byte) ? String(UnicodeScalar(byte)) : "."
        }.joined()
    }

    var decimalBytes: String {
        map { String($0) }.joined(separator: " ")
    }
}

extension NSError {
    var logDescription: String {
        "\(localizedDescription) (domain=\(domain) code=\(code))"
    }
}

func describeError(_ error: Error?) -> String? {
    guard let error else { return nil }
    return (error as NSError).logDescription
}
