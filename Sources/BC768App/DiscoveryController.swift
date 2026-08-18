import BC768BLE
import BC768Protocol
import CoreBluetooth
import Foundation

/// 端末を探して GATT の構成を調べ、設定として保存する。
/// CLI の `discover` と同じ `BC768DiscoverySession` / `ConfigWriter` を使う。
@MainActor
final class DiscoveryController: ObservableObject {
    @Published private(set) var peripherals: [BC768DiscoveredPeripheral] = []
    @Published private(set) var isBusy = false
    @Published private(set) var statusText = "「探す」を押すと、周りの BLE 端末を探します。"
    @Published private(set) var errorText: String?
    @Published private(set) var layout: BC768Layout?
    @Published private(set) var inspectedServices: [BC768DiscoveredService] = []
    /// 保存するクライアント識別子。既存の設定があれば初期値に入る。
    @Published var clientID: String = ConfigWriter.existingClientID() ?? ""
    @Published private(set) var savedPath: String?

    private var session: BC768DiscoverySession?

    var configPath: String { ConfigLoader.userConfigPath }

    /// 周りの端末を一覧する。接続はしない。
    func scan() {
        guard !isBusy else { return }
        peripherals = []
        layout = nil
        inspectedServices = []
        errorText = nil
        savedPath = nil
        isBusy = true
        statusText = "探しています。BC-768 のボタンを押してください（広告を出していないと見つかりません）。"

        session = BC768DiscoverySession(scanTimeout: 30, inspects: false) { [weak self] event in
            Task { @MainActor in self?.handle(event) }
        }
        session?.start()
    }

    /// 選んだ端末へ接続し、Service と Characteristic を調べる。
    func inspect(_ peripheral: BC768DiscoveredPeripheral) {
        guard !isBusy else { return }
        layout = nil
        inspectedServices = []
        errorText = nil
        savedPath = nil
        isBusy = true
        statusText = "\(peripheral.displayName) を調べています。"

        session = BC768DiscoverySession(targetID: peripheral.id, scanTimeout: 30) { [weak self] event in
            Task { @MainActor in self?.handle(event) }
        }
        session?.start()
    }

    func cancel() {
        session?.cancel()
        statusText = "止めました。"
    }

    /// 調べた結果を設定ファイルへ書き出す。
    func save() {
        guard let layout else { return }
        let trimmed = clientID.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            try ConfigWriter.save(layout: layout, clientID: trimmed.isEmpty ? nil : trimmed, to: configPath)
            savedPath = configPath
            errorText = trimmed.isEmpty
                ? "UUID は保存しましたが、クライアント識別子が空です。このままでは通信できません。"
                : nil
            statusText = "保存しました。"
        } catch {
            errorText = "\(error)"
        }
    }

    private func handle(_ event: BC768DiscoveryEvent) {
        switch event {
        case .log, .message:
            break       // 設定画面では出さない（本体側のログに出る）
        case let .peripheral(peripheral):
            guard !peripherals.contains(where: { $0.id == peripheral.id }) else { return }
            peripherals.append(peripheral)
            peripherals.sort { $0.rssi > $1.rssi }
        case let .inventory(_, services, layout):
            inspectedServices = services
            self.layout = layout
            if layout == nil {
                errorText = "BC-768 の構成（Service 1 つ・write 2 本・notify 3 本）に一致しませんでした。別の端末を選んでください。"
            }
        case let .completed(completion):
            isBusy = false
            session = nil
            switch completion {
            case .finished:
                if layout != nil {
                    statusText = "構成が分かりました。識別子を入れて保存してください。"
                } else if !peripherals.isEmpty {
                    statusText = "\(peripherals.count) 台見つかりました。BC-768 を選んで「調べる」を押してください。"
                } else {
                    statusText = "見つかりませんでした。本体のボタンを押してからもう一度試してください。"
                }
            case .cancelled:
                statusText = "止めました。"
            case let .failed(reason):
                statusText = "失敗しました。"
                errorText = reason
            }
        }
    }
}
