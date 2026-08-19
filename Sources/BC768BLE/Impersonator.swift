import BC768Protocol
import CoreBluetooth
import Foundation

/// BC-768 のふりをして広告し、Health Planet が送ってくるメッセージを読む。
///
/// 狙いは 2 つ。
///
/// 1. `0x0003` の payload に平文で乗っている**クライアント識別子**を読み取る
/// 2. 機器登録のときに何をやり取りしているかを観測する
///
/// **BC-768 へは一切書き込まない。** 通信相手は Android アプリだけで、本体には触れない。
/// 返す応答も HCI キャプチャで観測済みのものに限る（`--reply` 指定時のみ）。
public final class BC768Impersonator: NSObject {
    /// 広告に載せる Local Name。実機は `TNT_BW`。
    public static let defaultLocalName = "TNT_BW"

    private let config: BC768Configuration
    private let options: BC768ImpersonatorOptions
    private let queue: DispatchQueue
    private let onEvent: @Sendable (BC768Event) -> Void

    private var manager: CBPeripheralManager?
    private var writeCharacteristics: [CBUUID: CBMutableCharacteristic] = [:]
    private var notifyCharacteristics: [CBUUID: CBMutableCharacteristic] = [:]
    /// セントラルが購読した Notify Characteristic。応答はここへ流す。
    private var subscribedNotify: CBUUID?
    private var reassembler = BC768Reassembler()
    private var nextSeq: UInt8 = 0x02
    private var didComplete = false
    /// 見つけたクライアント識別子。2 度目以降は出し直さない。
    private var capturedClientID: String?

    public init(
        configuration: BC768Configuration,
        options: BC768ImpersonatorOptions = BC768ImpersonatorOptions(),
        queue: DispatchQueue,
        onEvent: @escaping @Sendable (BC768Event) -> Void
    ) {
        config = configuration
        self.options = options
        self.queue = queue
        self.onEvent = onEvent
    }

    public func start() {
        manager = CBPeripheralManager(delegate: self, queue: queue)
    }

    public func cancel() {
        queue.async { [weak self] in
            guard let self else { return }
            manager?.stopAdvertising()
            finish(.cancelled)
        }
    }

    // MARK: - ログ

    private func emit(_ event: BC768Event) { onEvent(event) }
    private func logEvent(_ tag: String, _ fields: [(String, String?)], level: BC768LogLevel = .info) {
        emit(.log(tag: tag, fields: fields, level: level))
    }
    private func logInfo(_ text: String) { emit(.message(text, .info)) }
    private func logError(_ text: String) { emit(.message(text, .error)) }

    private func finish(_ completion: BC768Completion) {
        guard !didComplete else { return }
        didComplete = true
        emit(.completed(completion))
    }
}

// MARK: - 設定

public struct BC768ImpersonatorOptions {
    /// 広告に載せる Local Name。
    public var localName: String = BC768Impersonator.defaultLocalName
    /// 観測済みの応答を返してやり取りを先へ進める。
    /// off なら受信するだけで、識別子を読んだ時点で相手は止まる。
    public var reply = false
    /// クライアント識別子を読み取ったら終了する。
    public var stopAtClientID = true

    public init() {}
}

// MARK: - CBPeripheralManagerDelegate

extension BC768Impersonator: CBPeripheralManagerDelegate {
    public func peripheralManagerDidUpdateState(_ peripheral: CBPeripheralManager) {
        logEvent("PERIPHERAL_STATE", [("state", String(describing: peripheral.state))])
        switch peripheral.state {
        case .poweredOn:
            publishService(on: peripheral)
        case .unauthorized:
            logError("Bluetooth の使用が許可されていません。システム設定で許可してください。")
            finish(.failed("Bluetooth が許可されていません"))
        case .unsupported:
            logError("この Mac は Peripheral として動作できません。")
            finish(.failed("Peripheral 非対応"))
        case .poweredOff:
            logError("Bluetooth が切れています。")
        default:
            break
        }
    }

    private func publishService(on peripheral: CBPeripheralManager) {
        // 実機と同じ構成にする。write × 2 と notify × 3。
        // CCCD は CoreBluetooth が notify 用に自動で付けるので、こちらでは作らない。
        var characteristics: [CBMutableCharacteristic] = []
        for named in config.writeChars {
            let characteristic = CBMutableCharacteristic(
                type: named.uuid,
                properties: [.write, .writeWithoutResponse],
                value: nil,
                permissions: [.writeable]
            )
            writeCharacteristics[named.uuid] = characteristic
            characteristics.append(characteristic)
        }
        for named in config.notifyChars {
            let characteristic = CBMutableCharacteristic(
                type: named.uuid,
                properties: [.notify],
                value: nil,
                permissions: [.readable]
            )
            notifyCharacteristics[named.uuid] = characteristic
            characteristics.append(characteristic)
        }

        let service = CBMutableService(type: config.service.uuid, primary: true)
        service.characteristics = characteristics
        peripheral.add(service)
    }

    public func peripheralManager(_ peripheral: CBPeripheralManager, didAdd service: CBService, error: Error?) {
        if let error {
            logError("Service を公開できませんでした: \(error.localizedDescription)")
            finish(.failed(error.localizedDescription))
            return
        }
        logEvent("SERVICE_PUBLISHED", [
            ("uuid", service.uuid.uuidString),
            ("characteristics", String(service.characteristics?.count ?? 0)),
        ])
        peripheral.startAdvertising([
            CBAdvertisementDataLocalNameKey: options.localName,
            CBAdvertisementDataServiceUUIDsKey: [config.service.uuid],
        ])
    }

    public func peripheralManagerDidStartAdvertising(_ peripheral: CBPeripheralManager, error: Error?) {
        if let error {
            logError("広告を開始できませんでした: \(error.localizedDescription)")
            finish(.failed(error.localizedDescription))
            return
        }
        logEvent("ADVERTISING", [
            ("localName", options.localName),
            ("service", config.service.uuid.uuidString),
        ])
        logInfo("BC-768 のふりをして広告しています。Health Planet から接続してください。")
        logInfo("本体の BC-768 は電源を切っておくこと。両方が広告していると、どちらに繋がるか分かりません。")
    }

    public func peripheralManager(
        _ peripheral: CBPeripheralManager,
        central: CBCentral,
        didSubscribeTo characteristic: CBCharacteristic
    ) {
        if subscribedNotify == nil { subscribedNotify = characteristic.uuid }
        logInfo("セントラルが接続して購読しました。ここまで来れば相手はこちらを BC-768 と見なしています。")
        logEvent("SUBSCRIBED", [
            ("central", central.identifier.uuidString),
            ("uuid", characteristic.uuid.uuidString),
            ("logical", config.logicalName(for: characteristic.uuid)),
            ("maxUpdateLength", String(central.maximumUpdateValueLength)),
        ])
    }

    public func peripheralManager(
        _ peripheral: CBPeripheralManager,
        central: CBCentral,
        didUnsubscribeFrom characteristic: CBCharacteristic
    ) {
        logEvent("UNSUBSCRIBED", [("uuid", characteristic.uuid.uuidString)])
    }

    /// Read が来たら少なくとも接続はできている。何も返さないと相手はエラーを受け取るので応答する。
    /// CBPeripheralManager には接続そのものを知る手段がないため、接触の有無を測る数少ない手がかり。
    public func peripheralManager(_ peripheral: CBPeripheralManager, didReceiveRead request: CBATTRequest) {
        logEvent("RX_READ", [
            ("central", request.central.identifier.uuidString),
            ("uuid", request.characteristic.uuid.uuidString),
            ("logical", config.logicalName(for: request.characteristic.uuid)),
            ("offset", String(request.offset)),
        ])
        request.value = Data()
        peripheral.respond(to: request, withResult: .success)
    }

    public func peripheralManager(_ peripheral: CBPeripheralManager, didReceiveWrite requests: [CBATTRequest]) {
        for request in requests {
            let value = request.value ?? Data()
            logEvent("RX_FRAGMENT", [
                ("uuid", request.characteristic.uuid.uuidString),
                ("logical", config.logicalName(for: request.characteristic.uuid)),
                ("length", String(value.count)),
                ("hex", value.hexString),
            ], level: .debug)
            guard let assembled = reassembler.append(value) else { continue }
            guard let (message, checksumValid) = BC768Message.decode(assembled) else {
                logEvent("RX_MESSAGE_INVALID", [("raw", assembled.hexString)], level: .error)
                continue
            }
            handle(message, checksumValid: checksumValid, on: peripheral)
        }
        // Write Request で来た分だけ応答する。Write Without Response には応答しない。
        if let first = requests.first {
            peripheral.respond(to: first, withResult: .success)
        }
    }
}

// MARK: - 受信したメッセージの扱い

private extension BC768Impersonator {
    func handle(_ message: BC768Message, checksumValid: Bool, on peripheral: CBPeripheralManager) {
        let ascii = String(decoding: message.payload, as: UTF8.self)
        logEvent("RX_MESSAGE", [
            ("command", String(format: "0x%04X", message.command)),
            ("length", String(message.payload.count)),
            ("checksum", checksumValid ? "ok" : "INVALID"),
            ("payload", message.payload.hexString),
            ("ascii", message.payload.asciiPreview),
        ], level: checksumValid ? .info : .error)

        if message.command == 0x0003 {
            captureClientID(ascii)
        }

        guard options.reply else { return }
        guard let response = cannedResponse(for: message.command) else {
            logInfo(String(format: "0x%04X への応答は用意していません。ここで止まります。", message.command))
            return
        }
        send(response, on: peripheral)
    }

    func captureClientID(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard capturedClientID != trimmed else { return }
        capturedClientID = trimmed
        logEvent("CLIENT_ID", [("value", trimmed), ("length", String(trimmed.count))])
        logInfo("")
        logInfo("クライアント識別子を受け取りました:")
        logInfo("  BC768_CLIENT_ID=\(trimmed)")
        logInfo("")
        if options.stopAtClientID, !options.reply {
            finish(.finished)
        }
    }

    /// HCI キャプチャで観測済みの応答だけを返す。
    /// デバイス情報（`0x8020`）とユーザー設定（`0x9000` / `0x9002`）は
    /// 個体ごとの値なので用意していない。識別子を読むだけならここまでで足りる。
    func cannedResponse(for command: UInt16) -> BC768Message? {
        let ok = Data([0x00, 0x00])
        switch command {
        case 0x0003: return BC768Message(command: 0x8003, payload: ok)
        case 0x0010: return BC768Message(command: 0x8010, payload: ok)
        case 0x3000: return BC768Message(command: 0xB000, payload: ok)
        case 0x0001: return BC768Message(command: 0x8001, payload: ok)
        default: return nil
        }
    }

    func send(_ message: BC768Message, on peripheral: CBPeripheralManager) {
        guard let uuid = subscribedNotify, let characteristic = notifyCharacteristics[uuid] else {
            logError("購読されている Notify Characteristic がないため応答を送れません。")
            return
        }
        let encoded = message.encoded()
        let seq: UInt8
        if encoded.count > BC768Session.fragmentSize - BC768Fragment.headerSize {
            seq = nextSeq
            nextSeq = nextSeq &+ 1
        } else {
            seq = 0x00
        }
        let fragments = BC768Fragment.split(encoded, seq: seq, maxPayload: BC768Session.fragmentSize)
        logEvent("TX_MESSAGE", [
            ("command", String(format: "0x%04X", message.command)),
            ("fragments", String(fragments.count)),
            ("hex", encoded.hexString),
        ])
        for fragment in fragments {
            peripheral.updateValue(fragment, for: characteristic, onSubscribedCentrals: nil)
        }
    }
}
