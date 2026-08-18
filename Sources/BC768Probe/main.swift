import BC768BLE
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
// JSON を標準出力へ出すときは、ログが混ざらないよう標準エラーへ回す。
Log.allToStderr = options.json

// decode は BLE も UUID 設定も使わない。
if options.command == .decode {
    exit(DecodeCommand.run(options))
}

// discover は UUID 設定を必要としない（構成から割り出すのが目的）。
if options.command == .discover {
    Log.info("bc768-probe command=discover debug=\(options.debug)")
    DiscoverCommand.run(options)
}

Log.info("bc768-probe command=\(options.command.rawValue) debug=\(options.debug)")

// JSON は測定結果 (0xB010) を受け取ったときだけ出る。受信しないコマンドでは黙って空振りするので知らせる。
if options.json || options.outputPath != nil, [.scan, .probe].contains(options.command) {
    Log.error("\(options.command.rawValue) は測定結果を受信しないため JSON は出力されません。measure か sync を使ってください。")
}

let config: BC768Configuration
do {
    // scan は Service UUID だけで動く。probe は 5 つの Characteristic UUID も必要。
    config = try ConfigLoader.load(
        explicitPath: options.configPath,
        requireCharacteristics: options.command != .scan,
        requireHandshake: [.handshake, .measure, .sync].contains(options.command),
        onLog: { Log.debug($0) }
    )
} catch {
    FileHandle.standardError.write(Data("\(error)\n".utf8))
    exit(2)
}

Log.event("CONFIG", [
    ("service", config.service.uuid.uuidString),
    ("writeChars", config.writeChars.map { $0.uuid.uuidString }.joined(separator: ",")),
    ("notifyChars", config.notifyChars.map { $0.uuid.uuidString }.joined(separator: ",")),
], level: .debug)
Log.info("設定済み UUID: SERVICE_UUID + write \(config.writeChars.count) 件 / notify \(config.notifyChars.count) 件")

let bleQueue = DispatchQueue(label: "com.ochanuco.bc768-probe.ble")
let capturedOptions = options

/// セッション層のイベントをログと JSON へ流す。表示の責任は CLI 側が持つ。
let session = BC768Session(configuration: config, options: options.sessionOptions, queue: bleQueue) { event in
    switch event {
    case let .log(tag, fields, level):
        Log.event(tag, fields, level: LogLevel(level))
    case let .message(text, level):
        if level == .error { Log.error(text) } else { Log.info(text) }
    case .phase:
        // 進み具合はログから読めるので CLI では使わない（GUI 用）。
        break
    case let .record(record):
        JSONOutput.emit(record, options: capturedOptions)
    case let .completed(completion):
        Log.info("bye")
        switch completion {
        case .finished, .cancelled: exit(0)
        case .failed: exit(1)
        }
    }
}

// Ctrl+C で Notify 解除 → disconnect → cleanup を経て終了する。
signal(SIGINT, SIG_IGN)
signal(SIGTERM, SIG_IGN)
let sigintSource = DispatchSource.makeSignalSource(signal: SIGINT, queue: bleQueue)
let sigtermSource = DispatchSource.makeSignalSource(signal: SIGTERM, queue: bleQueue)
for source in [sigintSource, sigtermSource] {
    source.setEventHandler {
        Log.info("")
        Log.info("シグナルを受信しました。終了処理を行います。")
        session.cancel()
    }
    source.resume()
}

session.start()
dispatchMain()
