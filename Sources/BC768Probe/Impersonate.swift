import BC768BLE
import Foundation

/// BC-768 のふりをして広告し、Health Planet が送ってくる内容を読む。
///
/// BC-768 本体へは一切書き込まない。通信相手は Android アプリだけ。
enum ImpersonateCommand {
    static func run(_ options: Options) -> Never {
        let config: BC768Configuration
        do {
            // 必要なのは UUID だけ。クライアント識別子は相手から受け取る側なので要らない。
            config = try ConfigLoader.load(
                explicitPath: options.configPath,
                requireCharacteristics: true,
                requireHandshake: false,
                onLog: { Log.debug($0) }
            )
        } catch {
            FileHandle.standardError.write(Data("\(error)\n".utf8))
            exit(2)
        }

        Log.info("BC-768 本体の電源は切っておいてください。両方が広告していると、どちらへ繋がるか分かりません。")

        let queue = DispatchQueue(label: "com.ochanuco.bc768-probe.peripheral")
        let impersonator = BC768Impersonator(
            configuration: config,
            options: options.impersonatorOptions,
            queue: queue
        ) { event in
            switch event {
            case let .log(tag, fields, level):
                Log.event(tag, fields, level: LogLevel(level))
            case let .message(text, level):
                if level == .error { Log.error(text) } else { Log.info(text) }
            case .phase, .record:
                break
            case let .completed(completion):
                switch completion {
                case .finished, .cancelled: exit(0)
                case .failed: exit(1)
                }
            }
        }

        signal(SIGINT, SIG_IGN)
        signal(SIGTERM, SIG_IGN)
        let sigint = DispatchSource.makeSignalSource(signal: SIGINT, queue: queue)
        let sigterm = DispatchSource.makeSignalSource(signal: SIGTERM, queue: queue)
        for source in [sigint, sigterm] {
            source.setEventHandler {
                Log.info("")
                Log.info("広告を止めます。")
                impersonator.cancel()
            }
            source.resume()
        }

        impersonator.start()
        dispatchMain()
    }
}
