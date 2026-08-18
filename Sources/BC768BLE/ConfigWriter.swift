import Foundation

/// 設定ファイル（.env 形式）の書き出し。CLI の `discover --save` と GUI の登録が共有する。
public enum ConfigWriter {
    public enum WriteError: Error, CustomStringConvertible {
        case failed(path: String, underlying: Error)

        public var description: String {
            switch self {
            case let .failed(path, underlying):
                return "\(path) へ書き出せませんでした: \(underlying.localizedDescription)"
            }
        }
    }

    /// 既に設定ファイルへ入っているクライアント識別子を読む。
    /// 環境変数が設定されていればそちらを優先する（CLI の探索順に合わせる）。
    public static func existingClientID(path: String = ConfigLoader.userConfigPath) -> String? {
        if let value = ProcessInfo.processInfo.environment["BC768_CLIENT_ID"], !value.isEmpty { return value }
        guard let contents = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
        for line in contents.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("BC768_CLIENT_ID=") else { continue }
            let value = String(trimmed.dropFirst("BC768_CLIENT_ID=".count))
            return value.isEmpty ? nil : value
        }
        return nil
    }

    /// UUID とクライアント識別子を書き出す。パーミッションは 600 にする（識別子が入るため）。
    public static func save(
        layout: BC768Layout,
        clientID: String?,
        to path: String = ConfigLoader.userConfigPath
    ) throws {
        let contents = layout.envFileContents(clientID: clientID)
        do {
            let directory = (path as NSString).deletingLastPathComponent
            try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
            try contents.write(toFile: path, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
        } catch {
            throw WriteError.failed(path: path, underlying: error)
        }
    }
}
