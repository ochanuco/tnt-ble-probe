import Foundation

let arguments = Array(CommandLine.arguments.dropFirst())

let options: Options
do {
    guard let parsed = try CLI.parse(arguments) else {
        print(Options.usage)
        exit(0)
    }
    options = parsed
} catch {
    FileHandle.standardError.write(Data("\(error)\n\n\(Options.usage)\n".utf8))
    exit(2)
}

Log.level = options.debug ? .debug : .info

// decode は BLE も UUID 設定も使わない。
if options.command == .decode {
    exit(DecodeCommand.run(options))
}

Log.info("bc768-probe command=\(options.command.rawValue) debug=\(options.debug)")

let config: Config
do {
    // scan は Service UUID だけで動く。probe は 5 つの Characteristic UUID も必要。
    config = try ConfigLoader.load(
        explicitPath: options.configPath,
        requireCharacteristics: options.command != .scan,
        requireHandshake: [.handshake, .measure, .sync].contains(options.command)
    )
} catch {
    FileHandle.standardError.write(Data("\(error)\n".utf8))
    exit(2)
}

Log.event("CONFIG", [
    ("service", config.service.uuid.uuidString),
    ("writeChars", config.writeChars.map(\.uuid.uuidString).joined(separator: ",")),
    ("notifyChars", config.notifyChars.map(\.uuid.uuidString).joined(separator: ",")),
], level: .debug)
Log.info("設定済み UUID: SERVICE_UUID + write \(config.writeChars.count) 件 / notify \(config.notifyChars.count) 件")

let bleQueue = DispatchQueue(label: "com.ochanuco.bc768-probe.ble")
let client = BC768Client(config: config, options: options, queue: bleQueue)

// Ctrl+C で Notify 解除 → disconnect → cleanup を経て終了する。
signal(SIGINT, SIG_IGN)
signal(SIGTERM, SIG_IGN)
let sigintSource = DispatchSource.makeSignalSource(signal: SIGINT, queue: bleQueue)
let sigtermSource = DispatchSource.makeSignalSource(signal: SIGTERM, queue: bleQueue)
for source in [sigintSource, sigtermSource] {
    source.setEventHandler {
        Log.info("")
        Log.info("シグナルを受信しました。終了処理を行います。")
        client.shutdown(exitCode: 0)
    }
    source.resume()
}

dispatchMain()
