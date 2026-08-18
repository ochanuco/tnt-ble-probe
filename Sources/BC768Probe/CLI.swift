import Foundation

enum Command: String {
    case scan
    case probe
    case handshake
}

/// handshake の送信先 Characteristic。実機で確かめるまで確定できないため選べるようにしてある。
enum WriteCharSelection: String {
    case auto
    case write1
    case write2
}

/// Notify 購読の対象。Android は 1 本しか購読していないため、揃えられるようにする。
enum NotifyCharSelection: String {
    case all
    case notify1
    case notify2
    case notify3
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
    /// handshake の送信先。auto は WRITE_CHAR_1 を試し、応答がなければ WRITE_CHAR_2 へ切り替える。
    var writeChar: WriteCharSelection = .auto
    /// handshake の応答待ちタイムアウト秒。
    var responseTimeout: Double = 3
    /// 購読対象の Notify Characteristic。
    var notifyChar: NotifyCharSelection = .all
    /// 購読完了から handshake 開始までの待ち時間（秒）。Android のタイミングを再現するため。
    var handshakeDelay: Double = 0
    /// 実行する handshake ステップ。nil なら既定の全ステップ。
    var steps: [String]?

    static let usage = """
    bc768-probe - TANITA BC-768 / macOS BLE Pairing 検証 CLI

    USAGE:
      bc768-probe <command> [options]

    COMMANDS:
      scan       BC-768 候補を探索して広告情報を表示する
      probe      scan → connect → discover → subscribe → wait を実行する
      handshake  probe に続けて、HCI ログで確認済みのハンドシェイクを送る

    OPTIONS:
      --debug             DEBUG ログを有効にする
      --config <path>     UUID 設定ファイル (.env 形式) のパス
      --no-filter         Service UUID フィルタなしで scan する
      --timeout <sec>     scan のタイムアウト秒 (既定 20 / 0 で無制限)
      --no-subscribe      Notify 購読を行わない (Pairing 検証 Case A)
      --read-all          readable な Characteristic を read する (Write は行わない)
      --id <uuid>         scan を省略して指定 Peripheral 識別子へ直接接続する
      --wait <sec>        接続後の待機秒数 (既定 0 = Ctrl+C まで待機)
      --write-char <sel>  handshake の送信先 (auto | write1 | write2、既定 auto)
      --response-timeout <sec>
                          handshake の応答待ちタイムアウト (既定 3)
      --notify-char <sel> 購読する Notify (all | notify1 | notify2 | notify3、既定 all)
      --handshake-delay <sec>
                          購読完了から handshake 開始までの待ち (既定 0)
      --steps <a,b,...>   実行する handshake ステップを絞る
                          (identify,session,device-info,read-data,finish)
      -h, --help          このヘルプを表示する

    ENVIRONMENT:
      BC768_SERVICE_UUID / BC768_WRITE_CHAR_1 / BC768_WRITE_CHAR_2 /
      BC768_NOTIFY_CHAR_1 / BC768_NOTIFY_CHAR_2 / BC768_NOTIFY_CHAR_3
      handshake ではさらに BC768_CLIENT_ID / BC768_CMD_0010_PAYLOAD が必要
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
            case "--write-char":
                let value = try nextValue(for: arg)
                guard let parsed = WriteCharSelection(rawValue: value) else {
                    throw CLIError.invalidValue(option: arg, value: value)
                }
                options.writeChar = parsed
            case "--response-timeout":
                let value = try nextValue(for: arg)
                guard let parsed = Double(value), parsed > 0 else {
                    throw CLIError.invalidValue(option: arg, value: value)
                }
                options.responseTimeout = parsed
            case "--notify-char":
                let value = try nextValue(for: arg)
                guard let parsed = NotifyCharSelection(rawValue: value) else {
                    throw CLIError.invalidValue(option: arg, value: value)
                }
                options.notifyChar = parsed
            case "--handshake-delay":
                let value = try nextValue(for: arg)
                guard let parsed = Double(value), parsed >= 0 else {
                    throw CLIError.invalidValue(option: arg, value: value)
                }
                options.handshakeDelay = parsed
            case "--steps":
                let value = try nextValue(for: arg)
                let labels = value.split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) }
                guard !labels.isEmpty, labels.allSatisfy({ HandshakeStep.knownLabels.contains($0) }) else {
                    throw CLIError.invalidValue(option: arg, value: value)
                }
                options.steps = labels
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
