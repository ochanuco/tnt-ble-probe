import BC768Protocol
import CoreBluetooth
import Foundation

/// ハンドシェイクの 1 ステップ。送る内容はすべて Android HCI キャプチャで観測済みのもので、
/// 推測した payload は含まない。詳細は docs/protocol.md を参照。
public struct HandshakeStep {
    let label: String
    let message: BC768Message
    /// 期待する応答コマンド。
    let expected: UInt16
    /// このステップ固有の応答待ち秒数。nil なら共通設定を使う。
    let timeout: Double?

    init(label: String, message: BC768Message, expected: UInt16, timeout: Double? = nil) {
        self.label = label
        self.message = message
        self.expected = expected
        self.timeout = timeout
    }

    public static let knownLabels = [
        "identify", "session", "device-info", "read-data",
        "measure", "complete", "result", "finish",
    ]

    /// 既定のハンドシェイク（測定は行わない）。
    public static let defaultLabels = ["identify", "session", "device-info", "read-data", "finish"]
    /// 測定は開始せず、BC-768 が保持しているデータの有無を確認して取得する流れ。
    public static let syncLabels = [
        "identify", "session", "device-info", "read-data",
        "complete", "result", "finish",
    ]
    /// 測定まで通す一連の流れ。HCI キャプチャで測定に成功したセッションと同じ順序。
    public static let measureLabels = [
        "identify", "session", "device-info", "read-data",
        "measure", "complete", "result", "finish",
    ]

    static func sequence(with handshake: BC768Configuration, labels: [String]?, now: Date = Date()) -> [HandshakeStep] {
        let all = allSteps(with: handshake, now: now)
        let wanted = labels ?? defaultLabels
        return wanted.compactMap { label in all.first { $0.label == label } }
    }

    private static func allSteps(with handshake: BC768Configuration, now: Date) -> [HandshakeStep] {
        // 0x0010 は日時設定。既定では現在時刻から組み立てる（固定値を送ると古い日時になる）。
        let sessionPayload = handshake.sessionPayload ?? BC768DateTime.encode(now) ?? Data()
        return [
            HandshakeStep(
                label: "identify",
                message: BC768Message(command: 0x0003, payload: Data((handshake.clientID ?? "").utf8)),
                expected: 0x8003
            ),
            HandshakeStep(
                label: "session",
                message: BC768Message(command: 0x0010, payload: sessionPayload),
                expected: 0x8010
            ),
            HandshakeStep(
                label: "device-info",
                message: BC768Message(command: 0x0020, payload: Data([0x00])),
                expected: 0x8020
            ),
            HandshakeStep(
                label: "read-data",
                message: BC768Message(command: 0x1000, payload: Data([0x00])),
                expected: 0x9000
            ),
            // 測定の開始。Android では応答まで 9〜12 秒かかっていた（この間に体組成計へ乗る）。
            HandshakeStep(
                label: "measure",
                message: BC768Message(command: 0x2010, payload: Data([0x00])),
                expected: 0xA010,
                timeout: 120
            ),
            HandshakeStep(
                label: "complete",
                message: BC768Message(command: 0x3000, payload: Data([0x00])),
                expected: 0xB000
            ),
            // 測定結果の取得。payload は観測値どおり 0x01。
            HandshakeStep(
                label: "result",
                message: BC768Message(command: 0x3010, payload: Data([0x01])),
                expected: 0xB010
            ),
            HandshakeStep(
                label: "finish",
                message: BC768Message(command: 0x0001, payload: Data([0x00])),
                expected: 0x8001
            ),
        ]
    }
}

extension BC768Session {
    /// Android と同じ 20 バイト固定でフラグメント化する。
    /// BC-768 が大きいフラグメントを受け付けるかは未検証のため、MTU が広がっても広げない。
    static let fragmentSize = 20
    /// フラグメント間の送信間隔。Android の実測は 5〜7ms。
    static let fragmentInterval: DispatchTimeInterval = .milliseconds(15)
}
