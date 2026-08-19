import BC768Protocol
import CoreBluetooth
import Foundation

/// 論理名付きの UUID。実値は設定から与えられ、ログには論理名を出す。
public struct NamedUUID {
    public let logicalName: String
    public let uuid: CBUUID

    public init(logicalName: String, uuid: CBUUID) {
        self.logicalName = logicalName
        self.uuid = uuid
    }
}

/// 接続に必要な UUID とハンドシェイク用の値。
public struct BC768Configuration {
    public let service: NamedUUID
    public let writeChars: [NamedUUID]
    public let notifyChars: [NamedUUID]
    /// 0x0003 で送るクライアント識別子。handshake 系のモードで必要。
    public let clientID: String?
    /// 0x0010 の payload。nil なら実行時の現在時刻から組み立てる。
    public let sessionPayload: Data?

    public init(
        service: NamedUUID,
        writeChars: [NamedUUID] = [],
        notifyChars: [NamedUUID] = [],
        clientID: String? = nil,
        sessionPayload: Data? = nil
    ) {
        self.service = service
        self.writeChars = writeChars
        self.notifyChars = notifyChars
        self.clientID = clientID
        self.sessionPayload = sessionPayload
    }

    public var allCharacteristics: [NamedUUID] { writeChars + notifyChars }

    /// 実 UUID から論理名を引く（ログ表示用）。
    public func logicalName(for uuid: CBUUID) -> String? {
        if uuid == service.uuid { return service.logicalName }
        return allCharacteristics.first { $0.uuid == uuid }?.logicalName
    }
}

public enum BC768SessionMode {
    /// 広告を表示するだけ。接続しない。
    case scan
    /// 接続して Discovery と Notify 購読まで。
    case probe
    /// ハンドシェイクを送る（測定はしない）。
    case handshake
    /// 測定まで通す。
    case measure
    /// 測定は開始せず、保持されているデータを取得する。
    case sync
}

/// handshake の送信先 Characteristic。実機で確かめるまで確定できないため選べるようにしてある。
public enum BC768WriteCharSelection: String {
    case auto
    case write1
    case write2
}

/// Notify 購読の対象。Android は 1 本しか購読していないため、揃えられるようにする。
public enum BC768NotifyCharSelection: String {
    case all
    case notify1
    case notify2
    case notify3
}

public struct BC768SessionOptions {
    public var mode: BC768SessionMode
    /// Service UUID フィルタなしで scan する。
    public var noFilter = false
    /// scan のタイムアウト秒。0 で無制限。
    public var scanTimeout: Double = 20
    /// Notify 購読を行わない（Pairing 検証 Case A）。
    public var noSubscribe = false
    /// readable な Characteristic を read する（Write は行わない）。
    public var readAll = false
    /// scan を省略して既知の Peripheral 識別子へ直接接続する。
    public var peripheralID: UUID?
    /// 接続後の待機秒数。未指定なら probe は待ち続け、それ以外は完走時点で終了する。
    public var waitSeconds: Double?
    public var writeChar: BC768WriteCharSelection = .auto
    /// handshake の応答待ちタイムアウト秒。
    public var responseTimeout: Double = 3
    public var notifyChar: BC768NotifyCharSelection = .all
    /// 購読完了から handshake 開始までの待ち時間（秒）。
    public var handshakeDelay: Double = 0
    /// 実行する handshake ステップ。nil ならモードごとの既定。
    public var steps: [String]?
    /// 詳細な観測を行う（SERVICE_UUID 以外の Characteristic も探索する）。
    public var verbose = false
    /// 0x3010 を、日時付きのレコードが返る限り繰り返す。
    /// BC-768 が複数件を保持しているかを確かめるために使う。
    public var drain = false
    /// drain の上限（取り過ぎないための歯止め）。
    public var drainLimit = 32

    public init(mode: BC768SessionMode) {
        self.mode = mode
    }
}
