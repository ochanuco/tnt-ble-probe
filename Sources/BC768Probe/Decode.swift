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
                describe(command: command, payload: data, options: options)
            } else if let (message, checksumValid) = BC768Message.decode(data) {
                Log.event("MESSAGE", [
                    ("command", String(format: "0x%04X", message.command)),
                    ("length", String(message.payload.count)),
                    ("checksum", checksumValid ? "ok" : "INVALID"),
                ])
                describe(command: message.command, payload: message.payload, options: options)
            } else {
                Log.error("メッセージとして解釈できません（--command で payload として渡せます）: \(hex)")
                failed = true
            }
        }
        return failed ? 1 : 0
    }

    private static func describe(command: UInt16, payload: Data, options: Options) {
        let headerLength: Int
        switch command {
        case 0xB010: headerLength = 2
        case 0x9000, 0x9002, 0x8020: headerLength = 1
        default: headerLength = 0
        }
        let result = BC768TLV.parse(payload, headerLength: headerLength)
        Log.event("DECODED", [
            ("command", String(format: "0x%04X", command)),
            ("header", command == 0xB010
                ? BC768Record.header(of: payload).map { String(format: "0x%04X", $0) }
                : nil),
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
        if command == 0xB010 {
            let record = BC768MeasurementRecord(
                command: command,
                payload: payload,
                parseResult: result,
                sendPending: nil,
                retrievedAt: Date()
            )
            JSONOutput.emit(record, options: options)
        }
        if command == 0xB010, !BC768Record.hasTimestamp(result.fields) {
            Log.error("このレコードは日付・時刻がゼロです。接続外で測定された結果か、既に引き取り済みの残留値です。測定時刻は分からず、最新かどうかも判断できません。")
        }
    }
}
