import BC768Protocol
import Foundation

/// 受信済みの hex を BLE なしで解釈する。ログに残した payload をあとから読み直すために使う。
enum DecodeCommand {
    static func run(_ options: Options) -> Int32 {
        guard !options.hexArguments.isEmpty else {
            FileHandle.standardError.write(Data("decode には hex 文字列が必要です\n".utf8))
            return 2
        }
        var failed = false
        for hex in options.hexArguments {
            guard let data = Data(hexString: hex) else {
                Log.error("hex として解釈できません: \(hex)")
                failed = true
                continue
            }
            if let command = options.decodeCommand {
                describe(command: command, payload: data)
            } else if let (message, checksumValid) = BC768Message.decode(data) {
                Log.event("MESSAGE", [
                    ("command", String(format: "0x%04X", message.command)),
                    ("length", String(message.payload.count)),
                    ("checksum", checksumValid ? "ok" : "INVALID"),
                ])
                describe(command: message.command, payload: message.payload)
            } else {
                Log.error("メッセージとして解釈できません（--command で payload として渡せます）: \(hex)")
                failed = true
            }
        }
        return failed ? 1 : 0
    }

    private static func describe(command: UInt16, payload: Data) {
        let headerLength: Int
        switch command {
        case 0xB010: headerLength = 2
        case 0x9000, 0x9002, 0x8020: headerLength = 1
        default: headerLength = 0
        }
        let result = BC768TLV.parse(payload, headerLength: headerLength)
        Log.event("DECODED", [
            ("command", String(format: "0x%04X", command)),
            ("headerLength", String(headerLength)),
            ("fields", String(result.fields.count)),
        ])
        for field in result.fields {
            Log.info("  " + BC768Field.describe(field))
        }
        if case let .partial(_, unparsed) = result, !unparsed.isEmpty {
            Log.info("  未解釈の残り: \(unparsed.hexString)")
        }
        for check in BC768Consistency.checks(for: result.fields) {
            Log.info("  [検算] " + check.description)
        }
    }
}
