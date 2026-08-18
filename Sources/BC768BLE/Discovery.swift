import BC768Protocol
import CoreBluetooth
import Foundation

/// scan で見つかった端末。
public struct BC768DiscoveredPeripheral: Identifiable {
    public let id: UUID
    /// 接続後に読める Device Name（BC-768 では "BC-768  "）。
    public let name: String?
    /// 広告に載っている Local Name（BC-768 では "TNT_BW"）。
    public let localName: String?
    public let rssi: Int
    public let advertisedServices: [CBUUID]

    public var displayName: String { name ?? localName ?? id.uuidString }
}

public struct BC768DiscoveredCharacteristic {
    public let uuid: CBUUID
    public let properties: CBCharacteristicProperties
}

public struct BC768DiscoveredService {
    public let uuid: CBUUID
    public let characteristics: [BC768DiscoveredCharacteristic]
}

/// Discovery の結果から組み立てた UUID の割り当て。
///
/// BC-768 は独自 Service を 1 つだけ持ち、その配下が
/// writeWithoutResponse × 2 と notify × 3 という構成になっている。
/// この形に一致すれば、UUID を事前に知らなくても論理名を割り当てられる。
public struct BC768Layout {
    public let service: CBUUID
    /// UUID 昇順。先頭が WRITE_CHAR_1。
    public let writeChars: [CBUUID]
    /// UUID 昇順。先頭が NOTIFY_CHAR_1。
    public let notifyChars: [CBUUID]

    public static let expectedWriteCount = 2
    public static let expectedNotifyCount = 3

    /// BC-768 の構成に一致する Service を探す。
    public static func match(services: [BC768DiscoveredService]) -> BC768Layout? {
        for service in services {
            let writes = service.characteristics
                .filter { $0.properties.contains(.writeWithoutResponse) || $0.properties.contains(.write) }
                .map(\.uuid)
                .sorted { $0.uuidString < $1.uuidString }
            let notifies = service.characteristics
                .filter { $0.properties.contains(.notify) || $0.properties.contains(.indicate) }
                .map(\.uuid)
                .sorted { $0.uuidString < $1.uuidString }

            guard writes.count == expectedWriteCount,
                  notifies.count == expectedNotifyCount,
                  service.characteristics.count == expectedWriteCount + expectedNotifyCount else { continue }
            return BC768Layout(service: service.uuid, writeChars: writes, notifyChars: notifies)
        }
        return nil
    }

    /// 設定ファイル（.env 形式）の中身を組み立てる。クライアント識別子は別途必要。
    public func envFileContents(clientID: String?) -> String {
        var lines = [
            "# bc768-probe の設定。Discovery で自動取得した UUID。",
            "BC768_SERVICE_UUID=\(service.uuidString)",
        ]
        for (index, uuid) in writeChars.enumerated() {
            lines.append("BC768_WRITE_CHAR_\(index + 1)=\(uuid.uuidString)")
        }
        for (index, uuid) in notifyChars.enumerated() {
            lines.append("BC768_NOTIFY_CHAR_\(index + 1)=\(uuid.uuidString)")
        }
        lines.append("")
        lines.append("# Health Planet が使っているクライアント識別子。")
        lines.append("# BC-768 に登録済みの値でないと 0x0003 が拒否される。")
        lines.append("BC768_CLIENT_ID=\(clientID ?? "")")
        return lines.joined(separator: "\n") + "\n"
    }

    public func configuration(clientID: String?) -> BC768Configuration {
        BC768Configuration(
            service: NamedUUID(logicalName: "SERVICE_UUID", uuid: service),
            writeChars: writeChars.enumerated().map { NamedUUID(logicalName: "WRITE_CHAR_\($0.offset + 1)", uuid: $0.element) },
            notifyChars: notifyChars.enumerated().map { NamedUUID(logicalName: "NOTIFY_CHAR_\($0.offset + 1)", uuid: $0.element) },
            clientID: clientID
        )
    }
}

public enum BC768DiscoveryEvent {
    case log(tag: String, fields: [(String, String?)], level: BC768LogLevel)
    case message(String, BC768LogLevel)
    /// scan で新しい端末を見つけた。
    case peripheral(BC768DiscoveredPeripheral)
    /// 接続して Service / Characteristic を列挙し終えた。
    case inventory(peripheral: BC768DiscoveredPeripheral, services: [BC768DiscoveredService], layout: BC768Layout?)
    case completed(BC768Completion)
}

/// UUID を一切知らない状態から、端末を探して GATT の構成を調べる。
/// 既存の `BC768Session` は設定済み UUID が前提なので、その手前を受け持つ。
public final class BC768DiscoverySession: NSObject {
    /// 名前による絞り込み（部分一致、大文字小文字を無視）。nil ならすべて。
    private let nameFilter: String?
    private let scanTimeout: Double
    /// 接続して中身まで調べるか。false なら scan だけ。
    private let inspects: Bool
    private let queue: DispatchQueue
    private let onEvent: (BC768DiscoveryEvent) -> Void

    private var central: CBCentralManager!
    private var seen: [UUID: BC768DiscoveredPeripheral] = [:]
    private var target: CBPeripheral?
    private var pendingServices = 0
    private var collected: [BC768DiscoveredService] = []
    private var scanTimeoutItem: DispatchWorkItem?
    private var isTerminating = false

    public init(
        nameFilter: String? = nil,
        scanTimeout: Double = 20,
        inspects: Bool = true,
        queue: DispatchQueue = DispatchQueue(label: "com.ochanuco.bc768.discovery"),
        onEvent: @escaping (BC768DiscoveryEvent) -> Void
    ) {
        self.nameFilter = nameFilter
        self.scanTimeout = scanTimeout
        self.inspects = inspects
        self.queue = queue
        self.onEvent = onEvent
        super.init()
    }

    public func start() {
        queue.async { [weak self] in
            guard let self, self.central == nil else { return }
            self.central = CBCentralManager(delegate: self, queue: self.queue)
        }
    }

    public func cancel() { finish(.cancelled) }

    private func finish(_ completion: BC768Completion) {
        queue.async { [weak self] in
            guard let self, !self.isTerminating else { return }
            self.isTerminating = true
            if let target = self.target, target.state == .connected || target.state == .connecting {
                self.central?.cancelPeripheralConnection(target)
            }
            if self.central?.isScanning == true { self.central?.stopScan() }
            self.queue.asyncAfter(deadline: .now() + 0.3) {
                self.onEvent(.completed(completion))
            }
        }
    }

    private func log(_ tag: String, _ fields: [(String, String?)], level: BC768LogLevel = .info) {
        onEvent(.log(tag: tag, fields: fields, level: level))
    }
}

extension BC768DiscoverySession: CBCentralManagerDelegate {
    public func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn:
            // Service UUID を知らないのでフィルタはかけない。
            log("DISCOVER_SCAN_START", [
                ("filter", nameFilter),
                ("timeout", String(format: "%.0f", scanTimeout)),
            ])
            central.scanForPeripherals(withServices: nil, options: [
                CBCentralManagerScanOptionAllowDuplicatesKey: false
            ])
            guard scanTimeout > 0 else { return }
            let item = DispatchWorkItem { [weak self] in
                guard let self, !self.isTerminating, self.target == nil else { return }
                self.log("DISCOVER_SCAN_TIMEOUT", [("found", String(self.seen.count))])
                self.finish(self.seen.isEmpty ? .failed("端末が見つかりませんでした") : .finished)
            }
            scanTimeoutItem = item
            queue.asyncAfter(deadline: .now() + scanTimeout, execute: item)
        case .unauthorized:
            onEvent(.message("Bluetooth の使用が許可されていません。", .error))
            finish(.failed("Bluetooth の使用が許可されていません"))
        case .poweredOff:
            onEvent(.message("Bluetooth がオフです。", .error))
            finish(.failed("Bluetooth がオフです"))
        case .unsupported:
            finish(.failed("この Mac は BLE をサポートしていません"))
        default:
            break
        }
    }

    public func centralManager(
        _ central: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi RSSI: NSNumber
    ) {
        let localName = advertisementData[CBAdvertisementDataLocalNameKey] as? String
        let services = (advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID]) ?? []
        let found = BC768DiscoveredPeripheral(
            id: peripheral.identifier,
            name: peripheral.name,
            localName: localName,
            rssi: RSSI.intValue,
            advertisedServices: services
        )
        guard seen[peripheral.identifier] == nil else { return }
        seen[peripheral.identifier] = found

        if let nameFilter {
            let haystack = [found.name, found.localName].compactMap { $0 }.joined(separator: " ")
            guard haystack.range(of: nameFilter, options: .caseInsensitive) != nil else { return }
        }

        log("DISCOVER_PERIPHERAL", [
            ("name", found.name),
            ("localName", found.localName),
            ("id", found.id.uuidString),
            ("rssi", String(found.rssi)),
            ("services", services.map(\.uuidString).joined(separator: ",")),
        ])
        onEvent(.peripheral(found))

        guard inspects, target == nil else { return }
        scanTimeoutItem?.cancel()
        central.stopScan()
        target = peripheral
        peripheral.delegate = self
        log("DISCOVER_CONNECTING", [("id", found.id.uuidString)])
        central.connect(peripheral, options: nil)
    }

    public func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        log("DISCOVER_CONNECTED", [("id", peripheral.identifier.uuidString)])
        peripheral.discoverServices(nil)
    }

    public func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        finish(.failed("接続に失敗しました: \(describeError(error) ?? "不明")"))
    }

    public func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        guard !isTerminating else { return }
        finish(collected.isEmpty ? .failed("調べ終える前に切断されました") : .finished)
    }
}

extension BC768DiscoverySession: CBPeripheralDelegate {
    public func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        let services = peripheral.services ?? []
        guard !services.isEmpty else {
            finish(.failed("Service が見つかりませんでした"))
            return
        }
        pendingServices = services.count
        for service in services {
            peripheral.discoverCharacteristics(nil, for: service)
        }
    }

    public func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        let characteristics = (service.characteristics ?? []).map {
            BC768DiscoveredCharacteristic(uuid: $0.uuid, properties: $0.properties)
        }
        collected.append(BC768DiscoveredService(uuid: service.uuid, characteristics: characteristics))
        log("DISCOVER_SERVICE", [
            ("uuid", service.uuid.uuidString),
            ("characteristics", characteristics.map { "\($0.uuid.uuidString)(\($0.properties.description))" }.joined(separator: " ")),
        ])

        pendingServices -= 1
        guard pendingServices <= 0, let found = seen[peripheral.identifier] else { return }
        let layout = BC768Layout.match(services: collected)
        onEvent(.inventory(peripheral: found, services: collected, layout: layout))
        finish(.finished)
    }
}
