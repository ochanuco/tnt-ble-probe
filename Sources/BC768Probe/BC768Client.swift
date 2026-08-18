import CoreBluetooth
import Foundation

/// CoreBluetooth 固有の処理をここへ閉じ込め、将来 Go へ移植しやすい粒度に留める。
/// プロトコルを推測した自動処理は行わない。既定動作は Scan / Connect / Discover / Subscribe / Log まで。
final class BC768Client: NSObject {
    private let config: Config
    private let options: Options
    private let queue: DispatchQueue
    private var central: CBCentralManager!

    private var target: CBPeripheral?
    /// 発見済み Characteristic（SERVICE_UUID 配下のみ）。
    private var discovered: [CBUUID: CBCharacteristic] = [:]
    private var subscribedCount = 0
    private var scanTimeoutItem: DispatchWorkItem?
    private var isTerminating = false
    private var seenPeripherals: Set<UUID> = []
    private var pendingDescriptorDiscovery = 0

    init(config: Config, options: Options, queue: DispatchQueue) {
        self.config = config
        self.options = options
        self.queue = queue
        super.init()
        self.central = CBCentralManager(delegate: self, queue: queue)
    }

    // MARK: - lifecycle

    /// Ctrl+C / 待機終了時のクリーンアップ。Notify 解除 → disconnect → central cleanup。
    func shutdown(exitCode: Int32) {
        queue.async { [weak self] in
            guard let self, !self.isTerminating else { return }
            self.isTerminating = true
            Log.event("SHUTDOWN", [("reason", exitCode == 0 ? "requested" : "error")])

            if let peripheral = self.target {
                // 既に切断済みなら CCCD 書き込みは無意味なので行わない。
                for named in self.config.notifyChars where peripheral.state == .connected {
                    if let characteristic = self.discovered[named.uuid], characteristic.isNotifying {
                        Log.event("UNSUBSCRIBE", [
                            ("logical", named.logicalName),
                            ("uuid", named.uuid.uuidString),
                        ])
                        peripheral.setNotifyValue(false, for: characteristic)
                    }
                }
                if peripheral.state == .connected || peripheral.state == .connecting {
                    Log.event("DISCONNECTING", [("id", peripheral.identifier.uuidString)])
                    self.central.cancelPeripheralConnection(peripheral)
                }
            }
            if self.central.isScanning {
                self.central.stopScan()
            }
            // disconnect 完了コールバックを少し待ってから終了する。
            self.queue.asyncAfter(deadline: .now() + 0.7) {
                Log.info("bye")
                exit(exitCode)
            }
        }
    }

    // MARK: - scan

    private func startScan() {
        let services: [CBUUID]? = options.noFilter ? nil : [config.service.uuid]
        Log.event("SCAN_START", [
            ("mode", options.noFilter ? "no-filter" : "service-filter"),
            ("service", options.noFilter ? nil : config.service.uuid.uuidString),
            ("timeout", options.scanTimeout == 0 ? "none" : String(format: "%.0f", options.scanTimeout)),
        ])
        central.scanForPeripherals(withServices: services, options: [
            CBCentralManagerScanOptionAllowDuplicatesKey: false
        ])

        guard options.scanTimeout > 0 else { return }
        let item = DispatchWorkItem { [weak self] in
            guard let self, !self.isTerminating else { return }
            guard self.target == nil else { return }
            self.central.stopScan()
            Log.event("SCAN_TIMEOUT", [("found", String(self.seenPeripherals.count))])
            if self.options.command == .scan {
                self.shutdown(exitCode: self.seenPeripherals.isEmpty ? 1 : 0)
            } else {
                Log.error("対象 Peripheral を発見できませんでした。--no-filter や --id を検討してください。")
                self.shutdown(exitCode: 1)
            }
        }
        scanTimeoutItem = item
        queue.asyncAfter(deadline: .now() + options.scanTimeout, execute: item)
    }

    /// 既に macOS 側で接続済み（bonding 済みで自動接続されている等）の Peripheral を拾う。
    private func resolveAlreadyKnownPeripheral() -> CBPeripheral? {
        if let id = options.peripheralID {
            let peripherals = central.retrievePeripherals(withIdentifiers: [id])
            guard let peripheral = peripherals.first else {
                Log.error("指定された Peripheral 識別子が見つかりません: \(id.uuidString)")
                shutdown(exitCode: 1)
                return nil
            }
            Log.event("RETRIEVED", [
                ("source", "identifier"),
                ("id", peripheral.identifier.uuidString),
                ("name", peripheral.name),
                ("state", String(describing: peripheral.state.rawValue)),
            ])
            return peripheral
        }
        let connected = central.retrieveConnectedPeripherals(withServices: [config.service.uuid])
        if let peripheral = connected.first {
            Log.event("RETRIEVED", [
                ("source", "already-connected"),
                ("id", peripheral.identifier.uuidString),
                ("name", peripheral.name),
            ])
            return peripheral
        }
        return nil
    }

    // MARK: - connect

    private func connect(_ peripheral: CBPeripheral) {
        scanTimeoutItem?.cancel()
        if central.isScanning { central.stopScan() }
        target = peripheral
        peripheral.delegate = self
        Log.event("CONNECTING", [
            ("id", peripheral.identifier.uuidString),
            ("name", peripheral.name),
        ])
        central.connect(peripheral, options: nil)
    }
}

// MARK: - CBCentralManagerDelegate

extension BC768Client: CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        let stateName: String
        switch central.state {
        case .poweredOn: stateName = "poweredOn"
        case .poweredOff: stateName = "poweredOff"
        case .unauthorized: stateName = "unauthorized"
        case .unsupported: stateName = "unsupported"
        case .resetting: stateName = "resetting"
        case .unknown: stateName = "unknown"
        @unknown default: stateName = "unknown(\(central.state.rawValue))"
        }
        Log.event("CENTRAL_STATE", [("state", stateName)])

        switch central.state {
        case .poweredOn:
            if options.command == .probe, let known = resolveAlreadyKnownPeripheral() {
                connect(known)
            } else if options.peripheralID != nil, options.command == .scan {
                Log.error("--id は probe コマンドでのみ使用できます")
                shutdown(exitCode: 2)
            } else {
                startScan()
            }
        case .poweredOff:
            Log.error("Bluetooth がオフです。システム設定で有効にしてください。")
            shutdown(exitCode: 1)
        case .unauthorized:
            Log.error("Bluetooth の使用が許可されていません。システム設定 > プライバシーとセキュリティ > Bluetooth で、実行中のターミナルアプリを許可してください。")
            shutdown(exitCode: 1)
        case .unsupported:
            Log.error("この Mac は BLE をサポートしていません。")
            shutdown(exitCode: 1)
        case .resetting, .unknown:
            break
        @unknown default:
            break
        }
    }

    func centralManager(
        _ central: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi RSSI: NSNumber
    ) {
        let advertisedServices = (advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID]) ?? []
        let overflowServices = (advertisementData[CBAdvertisementDataOverflowServiceUUIDsKey] as? [CBUUID]) ?? []
        let manufacturerData = advertisementData[CBAdvertisementDataManufacturerDataKey] as? Data
        let serviceData = advertisementData[CBAdvertisementDataServiceDataKey] as? [CBUUID: Data]
        let isNew = seenPeripherals.insert(peripheral.identifier).inserted

        Log.event("SCAN", [
            ("name", peripheral.name ?? advertisementData[CBAdvertisementDataLocalNameKey] as? String),
            ("id", peripheral.identifier.uuidString),
            ("rssi", RSSI.stringValue),
            ("services", advertisedServices.map(\.uuidString).joined(separator: ",")),
            ("overflowServices", overflowServices.isEmpty ? nil : overflowServices.map(\.uuidString).joined(separator: ",")),
            ("manufacturerData", manufacturerData?.hexString),
            ("serviceData", serviceData?.map { "\($0.key.uuidString):\($0.value.hexString)" }.joined(separator: ",")),
            ("connectable", (advertisementData[CBAdvertisementDataIsConnectable] as? NSNumber)?.stringValue),
            ("txPower", (advertisementData[CBAdvertisementDataTxPowerLevelKey] as? NSNumber)?.stringValue),
            ("matchesServiceUUID", advertisedServices.contains(config.service.uuid) ? "true" : "false"),
        ], level: isNew ? .info : .debug)

        guard options.command == .probe, target == nil else { return }
        // 名前ではなく Service UUID で識別する。
        // --no-filter 時に Service UUID を広告しない機体は、--id 指定で接続する運用とする。
        let matches = advertisedServices.contains(config.service.uuid)
            || overflowServices.contains(config.service.uuid)
            || (!options.noFilter)
        guard matches else { return }
        connect(peripheral)
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        Log.event("CONNECTED", [
            ("id", peripheral.identifier.uuidString),
            ("name", peripheral.name),
        ])
        Log.event("DISCOVER_SERVICES", [("filter", "none (all services)")])
        peripheral.discoverServices(nil)
    }

    func centralManager(
        _ central: CBCentralManager,
        didFailToConnect peripheral: CBPeripheral,
        error: Error?
    ) {
        Log.event("FAILED", [
            ("id", peripheral.identifier.uuidString),
            ("error", describeError(error)),
        ], level: .error)
        shutdown(exitCode: 1)
    }

    func centralManager(
        _ central: CBCentralManager,
        didDisconnectPeripheral peripheral: CBPeripheral,
        error: Error?
    ) {
        Log.event("DISCONNECTED", [
            ("id", peripheral.identifier.uuidString),
            ("error", describeError(error)),
            ("hint", disconnectHint(for: error)),
        ])
        guard !isTerminating else { return }
        Log.info("Peripheral から切断されました。再接続は行いません（Bonding 検証はコマンドを再実行して確認してください）。")
        shutdown(exitCode: error == nil ? 0 : 1)
    }
}

// MARK: - CBPeripheralDelegate

extension BC768Client: CBPeripheralDelegate {
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        if let error {
            Log.event("SERVICE_DISCOVERY_ERROR", [("error", describeError(error))], level: .error)
            shutdown(exitCode: 1)
            return
        }
        let services = peripheral.services ?? []
        Log.event("SERVICES", [("count", String(services.count))])
        for service in services {
            Log.event("SERVICE", [
                ("uuid", service.uuidString),
                ("logical", config.logicalName(for: service.uuid)),
                ("isPrimary", service.isPrimary ? "true" : "false"),
            ])
        }

        guard let targetService = services.first(where: { $0.uuid == config.service.uuid }) else {
            Log.error("SERVICE_UUID に一致する Service が見つかりませんでした。")
            shutdown(exitCode: 1)
            return
        }
        Log.event("DISCOVER_CHARACTERISTICS", [
            ("service", targetService.uuidString),
            ("logical", config.service.logicalName),
            ("filter", "none (all characteristics)"),
        ])
        peripheral.discoverCharacteristics(nil, for: targetService)

        if Log.level >= .debug {
            for service in services where service.uuid != config.service.uuid {
                peripheral.discoverCharacteristics(nil, for: service)
            }
        }
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didDiscoverCharacteristicsFor service: CBService,
        error: Error?
    ) {
        if let error {
            Log.event("CHARACTERISTIC_DISCOVERY_ERROR", [
                ("service", service.uuidString),
                ("error", describeError(error)),
            ], level: .error)
            if service.uuid == config.service.uuid { shutdown(exitCode: 1) }
            return
        }

        let characteristics = service.characteristics ?? []
        let isTargetService = service.uuid == config.service.uuid
        for characteristic in characteristics {
            if isTargetService { discovered[characteristic.uuid] = characteristic }
            Log.event("CHARACTERISTIC", [
                ("service", service.uuidString),
                ("uuid", characteristic.uuidString),
                ("logical", config.logicalName(for: characteristic.uuid)),
                ("properties", characteristic.properties.description),
                ("isNotifying", characteristic.isNotifying ? "true" : "false"),
            ], level: isTargetService ? .info : .debug)
            pendingDescriptorDiscovery += 1
            peripheral.discoverDescriptors(for: characteristic)
        }

        guard isTargetService else { return }
        verifyConfiguredCharacteristics()
        if options.noSubscribe {
            Log.info("--no-subscribe が指定されているため Notify 購読を行いません（Pairing 検証 Case A）。")
        } else {
            subscribeNotifications(on: peripheral)
        }
        if options.readAll {
            readReadableCharacteristics(on: peripheral)
        }
        announceWaiting()
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didDiscoverDescriptorsFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        pendingDescriptorDiscovery = max(0, pendingDescriptorDiscovery - 1)
        let descriptors = characteristic.descriptors ?? []
        Log.event("DESCRIPTORS", [
            ("uuid", characteristic.uuidString),
            ("logical", config.logicalName(for: characteristic.uuid)),
            ("count", String(descriptors.count)),
            ("uuids", descriptors.map(\.uuidString).joined(separator: ",")),
            ("error", describeError(error)),
        ], level: .debug)
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didUpdateNotificationStateFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        Log.event("NOTIFY_STATE", [
            ("uuid", characteristic.uuidString),
            ("logical", config.logicalName(for: characteristic.uuid)),
            ("enabled", characteristic.isNotifying ? "true" : "false"),
            ("error", describeError(error)),
        ], level: error == nil ? .info : .error)

        if error == nil, characteristic.isNotifying {
            subscribedCount += 1
            if subscribedCount == config.notifyChars.count {
                Log.info("Phase 2: Notify 購読が \(subscribedCount) 件すべて有効になりました。")
                Log.info("macOS の Pairing ダイアログが表示された場合は、そのまま操作してください（CLI は待機し続けます）。")
            }
        }
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didUpdateValueFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        if let error {
            Log.event("READ_ERROR", [
                ("uuid", characteristic.uuidString),
                ("logical", config.logicalName(for: characteristic.uuid)),
                ("error", describeError(error)),
            ], level: .error)
            return
        }
        let data = characteristic.value ?? Data()
        // payload は加工せず hex を正として記録する。
        Log.event("NOTIFY", [
            ("uuid", characteristic.uuidString),
            ("logical", config.logicalName(for: characteristic.uuid)),
            ("length", String(data.count)),
            ("hex", data.hexString),
        ])
        Log.event("NOTIFY_DETAIL", [
            ("uuid", characteristic.uuidString),
            ("dec", data.decimalBytes),
            ("ascii", data.asciiPreview),
        ], level: .debug)
    }
}

// MARK: - phase helpers

private extension BC768Client {
    /// 設定された Characteristic UUID が実際に存在し、期待する Property を持つか検証する。
    func verifyConfiguredCharacteristics() {
        var missing: [String] = []
        var mismatched: [String] = []

        func check(_ named: NamedUUID, expected: CBCharacteristicProperties, expectedLabel: String) {
            guard let characteristic = discovered[named.uuid] else {
                missing.append(named.logicalName)
                return
            }
            if characteristic.properties.intersection(expected).isEmpty {
                mismatched.append("\(named.logicalName)(expected=\(expectedLabel) actual=\(characteristic.properties.description))")
            }
        }

        for named in config.writeChars {
            check(named, expected: [.write, .writeWithoutResponse], expectedLabel: "write/writeWithoutResponse")
        }
        for named in config.notifyChars {
            check(named, expected: [.notify, .indicate], expectedLabel: "notify/indicate")
        }

        Log.event("VERIFY", [
            ("configured", String(config.allCharacteristics.count)),
            ("found", String(config.allCharacteristics.count - missing.count)),
            ("missing", missing.isEmpty ? nil : missing.joined(separator: ",")),
            ("propertyMismatch", mismatched.isEmpty ? nil : mismatched.joined(separator: ",")),
        ], level: missing.isEmpty ? .info : .error)

        if missing.isEmpty {
            Log.info("Phase 1: SERVICE_UUID と設定済み 5 Characteristic をすべて発見しました。")
        } else {
            Log.error("Phase 1 未達: \(missing.joined(separator: ",")) が見つかりません。")
        }
    }

    func subscribeNotifications(on peripheral: CBPeripheral) {
        for named in config.notifyChars {
            guard let characteristic = discovered[named.uuid] else {
                Log.event("SUBSCRIBE_SKIP", [
                    ("logical", named.logicalName),
                    ("uuid", named.uuid.uuidString),
                    ("reason", "characteristic not found"),
                ], level: .error)
                continue
            }
            Log.event("SUBSCRIBE", [
                ("logical", named.logicalName),
                ("uuid", named.uuid.uuidString),
                ("requested", "true"),
            ])
            peripheral.setNotifyValue(true, for: characteristic)
        }
    }

    /// Pairing 誘発の観測用。read は副作用を持たないため既定 off のオプトインで実行する。
    /// Write は仕様どおり一切行わない。
    func readReadableCharacteristics(on peripheral: CBPeripheral) {
        for (uuid, characteristic) in discovered where characteristic.properties.contains(.read) {
            Log.event("READ_REQUEST", [
                ("uuid", uuid.uuidString),
                ("logical", config.logicalName(for: uuid)),
            ])
            peripheral.readValue(for: characteristic)
        }
    }

    /// 切断理由から、次に試すべきことの手がかりを出す（判断材料であり自動処理はしない）。
    func disconnectHint(for error: Error?) -> String? {
        guard let error = error as NSError?, error.domain == CBErrorDomain else { return nil }
        switch CBError.Code(rawValue: error.code) {
        case .connectionTimeout:
            return "Peripheral 側から一定時間後に切断された可能性が高い。BC-768 の設定/通信ボタンを約3秒長押しして Pairing 待機状態にしてから再試行する。"
        case .peripheralDisconnected:
            return "Peripheral 側の明示的な切断。BC-768 の待機状態が終了した可能性がある。"
        case .encryptionTimedOut:
            return "暗号化（Pairing/Bonding）がタイムアウトした。macOS の Bluetooth 環境設定から既存のペアリング情報を削除して再試行する。"
        default:
            return nil
        }
    }

    func announceWaiting() {
        if options.waitSeconds > 0 {
            Log.info("待機します（\(Int(options.waitSeconds)) 秒）。Ctrl+C でいつでも終了できます。")
            queue.asyncAfter(deadline: .now() + options.waitSeconds) { [weak self] in
                Log.info("待機時間が経過しました。")
                self?.shutdown(exitCode: 0)
            }
        } else {
            Log.info("待機中。Notify を受信するとログに出力します。終了は Ctrl+C。")
        }
    }
}

private extension CBAttribute {
    var uuidString: String { uuid.uuidString }
}
