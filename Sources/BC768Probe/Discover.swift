import BC768BLE
import BC768Protocol
import CoreBluetooth
import Foundation

/// UUID を知らない状態から端末を探し、GATT の構成を調べて設定を組み立てる。
enum DiscoverCommand {
    static func run(_ options: Options) -> Never {
        // 名前で絞っていないうちは接続しない（知らない機器へ勝手に繋がないため）。
        let inspects = options.nameFilter != nil
        if !inspects {
            Log.info("見つかった端末を一覧します。中身まで調べるには --name で絞ってください（例: --name TNT）。")
        }

        let session = BC768DiscoverySession(
            nameFilter: options.nameFilter,
            scanTimeout: options.scanTimeout,
            inspects: inspects
        ) { event in
            switch event {
            case let .log(tag, fields, level):
                Log.event(tag, fields, level: LogLevel(level))
            case let .message(text, level):
                if level == .error { Log.error(text) } else { Log.info(text) }
            case .peripheral:
                break       // ログで出している
            case let .inventory(peripheral, services, layout):
                report(peripheral: peripheral, services: services, layout: layout, options: options)
            case let .completed(completion):
                switch completion {
                case .finished, .cancelled: exit(0)
                case let .failed(reason):
                    Log.error(reason)
                    exit(1)
                }
            }
        }
        session.start()
        dispatchMain()
    }

    private static func report(
        peripheral: BC768DiscoveredPeripheral,
        services: [BC768DiscoveredService],
        layout: BC768Layout?,
        options: Options
    ) {
        Log.event("INVENTORY", [
            ("name", peripheral.name),
            ("localName", peripheral.localName),
            ("services", String(services.count)),
            ("characteristics", String(services.reduce(0) { $0 + $1.characteristics.count })),
        ])
        for service in services {
            Log.info("Service \(service.uuid.uuidString)")
            for characteristic in service.characteristics {
                Log.info("  \(characteristic.uuid.uuidString)  [\(characteristic.properties.description)]")
            }
        }

        guard let layout else {
            Log.error("BC-768 の構成（Service 1 つ・write 2 本・notify 3 本）に一致しませんでした。")
            return
        }

        Log.info("")
        Log.info("BC-768 の構成に一致しました。UUID を割り当てます。")
        Log.info("  SERVICE_UUID   = \(layout.service.uuidString)")
        for (index, uuid) in layout.writeChars.enumerated() {
            Log.info("  WRITE_CHAR_\(index + 1)   = \(uuid.uuidString)")
        }
        for (index, uuid) in layout.notifyChars.enumerated() {
            Log.info("  NOTIFY_CHAR_\(index + 1)  = \(uuid.uuidString)")
        }

        guard options.saveConfig else {
            Log.info("")
            Log.info("--save を付けると \(ConfigLoader.userConfigPath) へ書き出します。")
            return
        }
        save(layout: layout)
    }

    /// 既存のクライアント識別子は残したまま UUID だけ書き換える。
    private static func save(layout: BC768Layout) {
        let path = ConfigLoader.userConfigPath
        let existingClientID = currentClientID(path: path)
        let contents = layout.envFileContents(clientID: existingClientID)
        do {
            let directory = (path as NSString).deletingLastPathComponent
            try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
            try contents.write(toFile: path, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
            Log.info("")
            Log.info("書き出しました: \(path)")
            if existingClientID == nil || existingClientID?.isEmpty == true {
                Log.error("BC768_CLIENT_ID が空です。Health Planet が使っている識別子を書き足さないと通信できません。")
            } else {
                Log.info("既存の BC768_CLIENT_ID は残してあります。")
            }
        } catch {
            Log.error("書き出せませんでした: \(error.localizedDescription)")
        }
    }

    private static func currentClientID(path: String) -> String? {
        if let value = ProcessInfo.processInfo.environment["BC768_CLIENT_ID"], !value.isEmpty { return value }
        guard let contents = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
        for line in contents.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("BC768_CLIENT_ID=") else { continue }
            return String(trimmed.dropFirst("BC768_CLIENT_ID=".count))
        }
        return nil
    }
}
