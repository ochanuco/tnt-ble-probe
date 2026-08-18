import BC768Protocol
import CoreBluetooth
import Foundation

/// ハンドシェイクの 1 ステップ。送る内容はすべて Android HCI キャプチャで観測済みのもので、
/// 推測した payload は含まない。詳細は docs/protocol.md を参照。
struct HandshakeStep {
    let label: String
    let message: BC768Message
    /// 期待する応答コマンド。
    let expected: UInt16

    static func sequence(with handshake: HandshakeConfig) -> [HandshakeStep] {
        [
            HandshakeStep(
                label: "identify",
                message: BC768Message(command: 0x0003, payload: Data(handshake.clientID.utf8)),
                expected: 0x8003
            ),
            HandshakeStep(
                label: "session",
                message: BC768Message(command: 0x0010, payload: handshake.sessionPayload),
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
            HandshakeStep(
                label: "finish",
                message: BC768Message(command: 0x0001, payload: Data([0x00])),
                expected: 0x8001
            ),
        ]
    }
}

extension BC768Client {
    /// Android と同じ 20 バイト固定でフラグメント化する。
    /// BC-768 が大きいフラグメントを受け付けるかは未検証のため、MTU が広がっても広げない。
    static let fragmentSize = 20
    /// フラグメント間の送信間隔。Android の実測は 5〜7ms。
    static let fragmentInterval: DispatchTimeInterval = .milliseconds(15)
}
