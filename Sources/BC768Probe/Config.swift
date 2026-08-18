import BC768Protocol
import CoreBluetooth
import Foundation

/// 論理 UUID 名。実値はソースにも docs にも書かず、環境変数 / .env から与える。
enum ConfigKey: String, CaseIterable {
    case serviceUUID = "BC768_SERVICE_UUID"
    case writeChar1 = "BC768_WRITE_CHAR_1"
    case writeChar2 = "BC768_WRITE_CHAR_2"
    case notifyChar1 = "BC768_NOTIFY_CHAR_1"
    case notifyChar2 = "BC768_NOTIFY_CHAR_2"
    case notifyChar3 = "BC768_NOTIFY_CHAR_3"

    /// 仕様書上の論理名。
    var logicalName: String {
        switch self {
        case .serviceUUID: return "SERVICE_UUID"
        case .writeChar1: return "WRITE_CHAR_1"
        case .writeChar2: return "WRITE_CHAR_2"
        case .notifyChar1: return "NOTIFY_CHAR_1"
        case .notifyChar2: return "NOTIFY_CHAR_2"
        case .notifyChar3: return "NOTIFY_CHAR_3"
        }
    }
}

struct NamedUUID {
    let logicalName: String
    let uuid: CBUUID
}

/// handshake コマンドでのみ必要になる値。Android HCI キャプチャ由来なので設定として外に出す。
struct HandshakeConfig {
    /// 0x0003 で送るクライアント識別子（36 文字の UUID 文字列）。
    let clientID: String
    /// 0x0010 で送る payload。nil なら実行時に現在時刻から組み立てる。
    let sessionPayload: Data?
}

struct Config {
    let service: NamedUUID
    let writeChars: [NamedUUID]
    let notifyChars: [NamedUUID]
    let handshake: HandshakeConfig?

    var allCharacteristics: [NamedUUID] { writeChars + notifyChars }

    /// 実 UUID から論理名を引く（ログ表示用）。
    func logicalName(for uuid: CBUUID) -> String? {
        if uuid == service.uuid { return service.logicalName }
        return allCharacteristics.first { $0.uuid == uuid }?.logicalName
    }
}

enum ConfigError: Error, CustomStringConvertible {
    case missing([ConfigKey], searchedPaths: [String])
    case invalidUUID(key: ConfigKey, value: String)
    case missingHandshakeValue(keys: [String], searchedPaths: [String])
    case invalidHex(key: String, value: String)

    var description: String {
        switch self {
        case let .missing(keys, paths):
            var text = "UUID 設定が不足しています。以下の論理 UUID を設定してください:\n"
            for key in keys {
                text += "  - \(key.logicalName) (環境変数 \(key.rawValue))\n"
            }
            text += "\n探索した設定ファイル:\n"
            for path in paths {
                text += "  - \(path)\n"
            }
            text += "\n`cp .env.example .env` して .env に実値を書くか、環境変数を export してください。"
            return text
        case let .invalidUUID(key, value):
            return "\(key.logicalName) (\(key.rawValue)) の値が UUID として解釈できません: \"\(value)\""
        case let .missingHandshakeValue(keys, paths):
            var text = "handshake に必要な設定が不足しています:\n"
            for key in keys { text += "  - \(key)\n" }
            text += "\n探索した設定ファイル:\n"
            for path in paths { text += "  - \(path)\n" }
            text += "\nこれらは Android HCI キャプチャから得た値です。docs/protocol.md を参照してください。"
            return text
        case let .invalidHex(key, value):
            return "\(key) の値が hex として解釈できません: \"\(value)\""
        }
    }
}

enum ConfigLoader {
    /// 読み込み優先度: 環境変数 > 明示指定 .env > ./.env > ~/.config/bc768-probe/env
    static func load(explicitPath: String?, requireCharacteristics: Bool, requireHandshake: Bool = false) throws -> Config {
        var searchedPaths: [String] = []
        var fileValues: [String: String] = [:]

        for path in candidatePaths(explicitPath: explicitPath) {
            searchedPaths.append(path)
            guard FileManager.default.fileExists(atPath: path) else { continue }
            let loaded = parseEnvFile(atPath: path)
            Log.debug("config file loaded: \(path) (keys=\(loaded.keys.sorted().joined(separator: ",")))")
            // 先に見つかったファイルを優先し、後続では未定義キーだけ補う。
            for (key, value) in loaded where fileValues[key] == nil {
                fileValues[key] = value
            }
        }

        let requiredKeys: [ConfigKey] = requireCharacteristics
            ? ConfigKey.allCases
            : [.serviceUUID]

        var resolved: [ConfigKey: String] = [:]
        var missing: [ConfigKey] = []
        for key in requiredKeys {
            let raw = ProcessInfo.processInfo.environment[key.rawValue] ?? fileValues[key.rawValue]
            guard let raw, !raw.trimmingCharacters(in: .whitespaces).isEmpty else {
                missing.append(key)
                continue
            }
            resolved[key] = raw.trimmingCharacters(in: .whitespaces)
        }
        guard missing.isEmpty else {
            throw ConfigError.missing(missing, searchedPaths: searchedPaths)
        }

        func uuid(_ key: ConfigKey) throws -> NamedUUID {
            let value = resolved[key]!
            guard let parsed = makeCBUUID(value) else {
                throw ConfigError.invalidUUID(key: key, value: value)
            }
            return NamedUUID(logicalName: key.logicalName, uuid: parsed)
        }

        let service = try uuid(.serviceUUID)
        guard requireCharacteristics else {
            return Config(service: service, writeChars: [], notifyChars: [], handshake: nil)
        }

        var handshake: HandshakeConfig?
        if requireHandshake {
            func value(_ key: String) -> String? {
                let raw = ProcessInfo.processInfo.environment[key] ?? fileValues[key]
                guard let raw, !raw.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
                return raw.trimmingCharacters(in: .whitespaces)
            }
            let clientIDKey = "BC768_CLIENT_ID"
            let sessionKey = "BC768_CMD_0010_PAYLOAD"
            guard value(clientIDKey) != nil else {
                throw ConfigError.missingHandshakeValue(keys: [clientIDKey], searchedPaths: searchedPaths)
            }
            // 0x0010 は日時設定なので既定では現在時刻から生成する。
            // 設定されていれば固定値を使う（HCI ログとの比較実験用）。
            var sessionPayload: Data?
            if let raw = value(sessionKey) {
                guard let parsed = Data(hexString: raw) else {
                    throw ConfigError.invalidHex(key: sessionKey, value: raw)
                }
                sessionPayload = parsed
            }
            handshake = HandshakeConfig(clientID: value(clientIDKey)!, sessionPayload: sessionPayload)
        }

        return Config(
            service: service,
            writeChars: [try uuid(.writeChar1), try uuid(.writeChar2)],
            notifyChars: [try uuid(.notifyChar1), try uuid(.notifyChar2), try uuid(.notifyChar3)],
            handshake: handshake
        )
    }

    private static func candidatePaths(explicitPath: String?) -> [String] {
        var paths: [String] = []
        if let explicitPath {
            paths.append((explicitPath as NSString).expandingTildeInPath)
        }
        paths.append(FileManager.default.currentDirectoryPath + "/.env")
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let configHome = ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"] ?? (home + "/.config")
        paths.append(configHome + "/bc768-probe/env")
        return paths
    }

    /// KEY=VALUE 形式の最小パーサ。`#` 始まりの行と空行は無視する。
    private static func parseEnvFile(atPath path: String) -> [String: String] {
        guard let contents = try? String(contentsOfFile: path, encoding: .utf8) else {
            Log.error("設定ファイルを読み込めませんでした: \(path)")
            return [:]
        }
        var values: [String: String] = [:]
        for rawLine in contents.split(separator: "\n", omittingEmptySubsequences: false) {
            var line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            if line.hasPrefix("export ") { line = String(line.dropFirst("export ".count)) }
            guard let separator = line.firstIndex(of: "=") else { continue }
            let key = String(line[line.startIndex..<separator]).trimmingCharacters(in: .whitespaces)
            var value = String(line[line.index(after: separator)...]).trimmingCharacters(in: .whitespaces)
            if value.count >= 2,
               (value.hasPrefix("\"") && value.hasSuffix("\"")) || (value.hasPrefix("'") && value.hasSuffix("'")) {
                value = String(value.dropFirst().dropLast())
            }
            if let comment = value.range(of: " #") {
                value = String(value[value.startIndex..<comment.lowerBound]).trimmingCharacters(in: .whitespaces)
            }
            values[key] = value
        }
        return values
    }

    /// 16bit / 32bit / 128bit いずれの表記も受け付ける。
    private static func makeCBUUID(_ value: String) -> CBUUID? {
        let normalized = value.uppercased()
        let hexOnly = normalized.replacingOccurrences(of: "-", with: "")
        let validLengths = [4, 8, 32]
        guard validLengths.contains(hexOnly.count),
              hexOnly.allSatisfy({ $0.isHexDigit }) else { return nil }
        // CBUUID(string:) は不正値で例外を投げるため、事前検証済みの値だけを渡す。
        return CBUUID(string: normalized)
    }
}
