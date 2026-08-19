import BC768BLE
import Foundation

enum Command: String {
    case scan
    case probe
    case handshake
    case measure
    case sync
    case decode
    case discover
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
    /// 接続後の待機秒数。未指定なら probe は Ctrl+C まで待機し、
    /// handshake / measure / sync は手順が完走した時点で終了する。
    var waitSeconds: Double?
    /// handshake の送信先。auto は WRITE_CHAR_1 を試し、応答がなければ WRITE_CHAR_2 へ切り替える。
    var writeChar: BC768WriteCharSelection = .auto
    /// handshake の応答待ちタイムアウト秒。
    var responseTimeout: Double = 3
    /// 購読対象の Notify Characteristic。
    var notifyChar: BC768NotifyCharSelection = .all
    /// 購読完了から handshake 開始までの待ち時間（秒）。Android のタイミングを再現するため。
    var handshakeDelay: Double = 0
    /// 実行する handshake ステップ。nil なら既定の全ステップ。
    var steps: [String]?
    /// decode コマンドに渡された hex 文字列。
    var hexArguments: [String] = []
    /// decode で payload として解釈するときのコマンド番号。
    var decodeCommand: UInt16?
    /// 測定結果を JSON で標準出力へ出す（ログは標準エラーへ回す）。
    var json = false
    /// JSON を整形して出す。
    var jsonPretty = false
    /// JSON を追記するファイル（JSON Lines）。
    var outputPath: String?
    /// 新規の測定結果のときだけ JSON を出す。
    var onlyNew = false
    /// discover で接続対象を名前で絞る（部分一致）。
    var nameFilter: String?
    /// discover の結果を設定ファイルへ書き出す。
    var saveConfig = false
    /// sync で、日時付きのレコードが返る限り 0x3010 を繰り返す。
    var drain = false

    static let usage = """
    bc768-probe - TANITA BC-768 / macOS BLE Pairing 検証 CLI

    USAGE:
      bc768-probe <command> [options]

    COMMANDS:
      scan       BC-768 候補を探索して広告情報を表示する
      probe      scan → connect → discover → subscribe → wait を実行する
      handshake  probe に続けて、HCI ログで確認済みのハンドシェイクを送る
      measure    handshake に続けて測定を開始し、結果を受け取る
      sync       測定は開始せず、BC-768 が保持しているデータの有無を確認して取得する
      decode     受信済みの hex を TLV として解釈する (BLE を使わない)
      discover   UUID 設定なしで端末を探し、GATT の構成から UUID を割り出す

    OPTIONS:
      --debug             DEBUG ログを有効にする
      --config <path>     UUID 設定ファイル (.env 形式) のパス
      --no-filter         Service UUID フィルタなしで scan する
      --timeout <sec>     scan のタイムアウト秒 (既定 20 / 0 で無制限)
      --no-subscribe      Notify 購読を行わない (Pairing 検証 Case A)
      --read-all          readable な Characteristic を read する (Write は行わない)
      --id <uuid>         scan を省略して指定 Peripheral 識別子へ直接接続する
      --wait <sec>        接続後の待機秒数。0 で Ctrl+C まで待機し続ける
                          (未指定なら probe は Ctrl+C まで待機、
                           handshake/measure/sync は完走した時点で終了)
      --write-char <sel>  handshake の送信先 (auto | write1 | write2、既定 auto)
      --response-timeout <sec>
                          handshake の応答待ちタイムアウト (既定 3)
      --notify-char <sel> 購読する Notify (all | notify1 | notify2 | notify3、既定 all)
      --handshake-delay <sec>
                          購読完了から handshake 開始までの待ち (既定 0)
      --steps <a,b,...>   実行する handshake ステップを絞る
                          (identify,session,device-info,read-data,finish)
      --json              測定結果を JSON で標準出力へ出す (ログは標準エラーへ)
      --pretty            JSON を整形して出す
      --out <path>        JSON を指定ファイルへ 1 行ずつ追記する (JSON Lines)
      --only-new          新規の測定結果 (日時があり送信対象) のときだけ JSON を出す
      --name <text>       discover で接続する端末を名前で絞る (部分一致、例: TNT)
      --save              discover の結果を設定ファイルへ書き出す
      --drain             sync で、日時付きのレコードが返る限り取り続ける
      --command <hex>     decode で hex を payload として扱うときのコマンド番号
                          (例: --command B010。省略時はメッセージ全体として解釈)
      -h, --help          このヘルプを表示する

    ENVIRONMENT:
      BC768_SERVICE_UUID / BC768_WRITE_CHAR_1 / BC768_WRITE_CHAR_2 /
      BC768_NOTIFY_CHAR_1 / BC768_NOTIFY_CHAR_2 / BC768_NOTIFY_CHAR_3
      handshake ではさらに BC768_CLIENT_ID / BC768_CMD_0010_PAYLOAD が必要
      (未設定なら ./.env → ~/.config/bc768-probe/env を参照する)
    """
}

extension Options {
    /// BLE セッション層へ渡す設定へ変換する。
    var sessionOptions: BC768SessionOptions {
        let mode: BC768SessionMode
        switch command {
        case .scan: mode = .scan
        case .probe: mode = .probe
        case .handshake: mode = .handshake
        case .measure: mode = .measure
        case .sync: mode = .sync
        case .decode, .discover: mode = .probe   // これらは BC768Session を使わない
        }
        var result = BC768SessionOptions(mode: mode)
        result.noFilter = noFilter
        result.scanTimeout = scanTimeout
        result.noSubscribe = noSubscribe
        result.readAll = readAll
        result.peripheralID = peripheralID
        result.waitSeconds = waitSeconds
        result.writeChar = writeChar
        result.responseTimeout = responseTimeout
        result.notifyChar = notifyChar
        result.handshakeDelay = handshakeDelay
        result.steps = steps
        result.verbose = debug
        result.drain = drain
        return result
    }
}

enum CLIError: Error, CustomStringConvertible {
    case unknownArgument(String)
    case missingValue(String)
    case invalidValue(option: String, value: String)
    case missingCommand

    var description: String {
        switch self {
        case let .unknownArgument(arg): return "不明な引数: \(arg)"
        case let .missingValue(option): return "\(option) には値が必要です"
        case let .invalidValue(option, value): return "\(option) の値が不正です: \(value)"
        case .missingCommand:
            return "コマンドを指定してください: scan / probe / handshake / measure / sync / decode"
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
                guard let parsed = BC768WriteCharSelection(rawValue: value) else {
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
                guard let parsed = BC768NotifyCharSelection(rawValue: value) else {
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
            case "--json":
                options.json = true
            case "--pretty":
                options.jsonPretty = true
            case "--only-new":
                options.onlyNew = true
            case "--name":
                options.nameFilter = try nextValue(for: arg)
            case "--save":
                options.saveConfig = true
            case "--drain":
                options.drain = true
            case "--out":
                options.outputPath = try nextValue(for: arg)
            case "--command":
                let value = try nextValue(for: arg)
                guard let parsed = UInt16(value.replacingOccurrences(of: "0x", with: ""), radix: 16) else {
                    throw CLIError.invalidValue(option: arg, value: value)
                }
                options.decodeCommand = parsed
            case "--id":
                let value = try nextValue(for: arg)
                guard let parsed = UUID(uuidString: value) else {
                    throw CLIError.invalidValue(option: arg, value: value)
                }
                options.peripheralID = parsed
            default:
                guard !arg.hasPrefix("-") else { throw CLIError.unknownArgument(arg) }
                if !sawCommand, let command = Command(rawValue: arg) {
                    options.command = command
                    sawCommand = true
                } else if options.command == .decode {
                    options.hexArguments.append(arg)
                } else {
                    throw CLIError.unknownArgument(arg)
                }
            }
            index += 1
        }
        // 既定のコマンドは設けない。5 つあるので暗黙に選ばれると分かりにくい。
        guard sawCommand else { throw CLIError.missingCommand }
        return options
    }
}
