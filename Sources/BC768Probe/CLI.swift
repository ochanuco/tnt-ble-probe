import Foundation

enum Command: String {
    case scan
    case probe
}

struct Options {
    var command: Command = .probe
    var debug = false
    var configPath: String?
    /// Service UUID フィルタなしで scan する（BC-768 が Service UUID を広告しない場合の保険）。
    var noFilter = false
    /// scan のタイムアウト秒。0 で無制限。
    var scanTimeout: Double = 20
    /// Case A（Connect のみ）検証用。Notify 購読を行わない。
    var noSubscribe = false
    /// readable な Characteristic を読む（Pairing 誘発の観測用。Write は一切行わない）。
    var readAll = false
    /// scan を省略して既知の Peripheral 識別子へ直接接続する。
    var peripheralID: UUID?
    /// 接続後の待機秒数。0 で Ctrl+C まで待機。
    var waitSeconds: Double = 0

    static let usage = """
    bc768-probe - TANITA BC-768 / macOS BLE Pairing 検証 CLI

    USAGE:
      bc768-probe <command> [options]

    COMMANDS:
      scan     BC-768 候補を探索して広告情報を表示する
      probe    scan → connect → discover → subscribe → wait を実行する

    OPTIONS:
      --debug             DEBUG ログを有効にする
      --config <path>     UUID 設定ファイル (.env 形式) のパス
      --no-filter         Service UUID フィルタなしで scan する
      --timeout <sec>     scan のタイムアウト秒 (既定 20 / 0 で無制限)
      --no-subscribe      Notify 購読を行わない (Pairing 検証 Case A)
      --read-all          readable な Characteristic を read する (Write は行わない)
      --id <uuid>         scan を省略して指定 Peripheral 識別子へ直接接続する
      --wait <sec>        接続後の待機秒数 (既定 0 = Ctrl+C まで待機)
      -h, --help          このヘルプを表示する

    ENVIRONMENT:
      BC768_SERVICE_UUID / BC768_WRITE_CHAR_1 / BC768_WRITE_CHAR_2 /
      BC768_NOTIFY_CHAR_1 / BC768_NOTIFY_CHAR_2 / BC768_NOTIFY_CHAR_3
      (未設定なら ./.env → ~/.config/bc768-probe/env を参照する)
    """
}

enum CLIError: Error, CustomStringConvertible {
    case unknownArgument(String)
    case missingValue(String)
    case invalidValue(option: String, value: String)

    var description: String {
        switch self {
        case let .unknownArgument(arg): return "不明な引数: \(arg)"
        case let .missingValue(option): return "\(option) には値が必要です"
        case let .invalidValue(option, value): return "\(option) の値が不正です: \(value)"
        }
    }
}

enum CLI {
    static func parse(_ arguments: [String]) throws -> Options? {
        var options = Options()
        var index = 0
        var sawCommand = false

        func nextValue(for option: String) throws -> String {
            index += 1
            guard index < arguments.count else { throw CLIError.missingValue(option) }
            return arguments[index]
        }

        while index < arguments.count {
            let arg = arguments[index]
            switch arg {
            case "-h", "--help":
                return nil
            case "--debug":
                options.debug = true
            case "--no-filter":
                options.noFilter = true
            case "--no-subscribe":
                options.noSubscribe = true
            case "--read-all":
                options.readAll = true
            case "--config":
                options.configPath = try nextValue(for: arg)
            case "--timeout":
                let value = try nextValue(for: arg)
                guard let parsed = Double(value), parsed >= 0 else {
                    throw CLIError.invalidValue(option: arg, value: value)
                }
                options.scanTimeout = parsed
            case "--wait":
                let value = try nextValue(for: arg)
                guard let parsed = Double(value), parsed >= 0 else {
                    throw CLIError.invalidValue(option: arg, value: value)
                }
                options.waitSeconds = parsed
            case "--id":
                let value = try nextValue(for: arg)
                guard let parsed = UUID(uuidString: value) else {
                    throw CLIError.invalidValue(option: arg, value: value)
                }
                options.peripheralID = parsed
            default:
                guard !arg.hasPrefix("-"), !sawCommand, let command = Command(rawValue: arg) else {
                    throw CLIError.unknownArgument(arg)
                }
                options.command = command
                sawCommand = true
            }
            index += 1
        }
        return options
    }
}
