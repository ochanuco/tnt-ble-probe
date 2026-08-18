import BC768BLE
import BC768Protocol
import Foundation

/// BLE セッションを 1 本だけ走らせ、進み具合と結果を UI へ渡す。
@MainActor
final class SessionController: ObservableObject {
    @Published private(set) var isRunning = false
    @Published private(set) var statusText = "待機中"
    @Published private(set) var errorText: String?
    /// 直近のログ。多くなりすぎないよう頭から捨てる。
    @Published private(set) var logLines: [String] = []
    /// 直前に取り込んだ結果の要約。
    @Published private(set) var lastResultText: String?

    private var session: BC768Session?
    private let queue = DispatchQueue(label: "com.ochanuco.bc768-app.ble")
    private static let maxLogLines = 300

    func start(mode: BC768SessionMode, store: MeasurementStore) {
        guard !isRunning else { return }
        errorText = nil
        lastResultText = nil
        logLines = []

        let configuration: BC768Configuration
        do {
            configuration = try ConfigLoader.load(
                explicitPath: nil,
                requireCharacteristics: true,
                requireHandshake: true,
                onLog: { [weak self] text in
                    Task { @MainActor in self?.appendLog(text) }
                }
            )
        } catch {
            errorText = "\(error)"
            statusText = "設定が読めません"
            return
        }

        var options = BC768SessionOptions(mode: mode)
        options.scanTimeout = 180        // 本体のボタンを押すまで待てるように長めにとる
        options.responseTimeout = 5

        isRunning = true
        statusText = mode == .measure ? "BC-768 の入力モードを押してください" : "BC-768 の電源を押してください"

        let session = BC768Session(configuration: configuration, options: options, queue: queue) { [weak self] event in
            Task { @MainActor in self?.handle(event, store: store) }
        }
        self.session = session
        session.start()
    }

    func cancel() {
        session?.cancel()
        statusText = "停止しています"
    }

    private func handle(_ event: BC768Event, store: MeasurementStore) {
        switch event {
        case let .log(tag, fields, level):
            guard level != .debug else { return }
            let body = fields.compactMap { key, value in value.map { "\(key)=\($0)" } }.joined(separator: " ")
            appendLog("[\(tag)] \(body)")
        case let .message(text, level):
            guard !text.isEmpty else { return }
            appendLog(level == .error ? "エラー: \(text)" : text)
        case let .phase(phase):
            statusText = Self.describe(phase)
        case let .record(record):
            let added = store.append(record)
            lastResultText = Self.describe(record, added: added)
        case let .completed(completion):
            isRunning = false
            session = nil
            switch completion {
            case .finished:
                statusText = "完了"
            case .cancelled:
                statusText = "停止しました"
            case let .failed(reason):
                statusText = "失敗"
                errorText = reason
            }
        }
    }

    private func appendLog(_ line: String) {
        logLines.append(line)
        if logLines.count > Self.maxLogLines {
            logLines.removeFirst(logLines.count - Self.maxLogLines)
        }
    }

    private static func describe(_ phase: BC768Phase) -> String {
        switch phase {
        case .scanning: return "BC-768 を探しています（本体のボタンを押してください）"
        case .connecting: return "接続しています"
        case .discovering: return "サービスを調べています"
        case .subscribing: return "通知を購読しています"
        case let .handshaking(step): return "やり取り中: \(step)"
        case .waitingForMeasurement: return "体組成計に乗ってください"
        case .completed: return "やり取りが完了しました"
        }
    }

    private static func describe(_ record: BC768MeasurementRecord, added: Bool) -> String {
        var parts: [String] = []
        if let weight = record.weightKg { parts.append(String(format: "体重 %.2f kg", weight)) }
        if let fat = record.bodyFatPercent { parts.append(String(format: "体脂肪率 %.1f %%", fat)) }
        let summary = parts.isEmpty ? "測定結果を受け取りました" : parts.joined(separator: " / ")

        if !record.hasTimestamp {
            return summary + "（測定日時が付いていません。BC-768 に残っていた値か、接続外で測ったものです）"
        }
        return added ? summary + "（保存しました）" : summary + "（既に保存済みのため追加しませんでした）"
    }
}
