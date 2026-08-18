import AppKit
import BC768BLE
import BC768Protocol
import SwiftUI

struct ContentView: View {
    @ObservedObject var store: MeasurementStore
    @ObservedObject var controller: SessionController
    @State private var showsLog = false

    var body: some View {
        VStack(spacing: 0) {
            actions
            Divider()
            status
            Divider()
            table
            if showsLog {
                Divider()
                log
            }
            Divider()
            footer
        }
        .frame(minWidth: 780, minHeight: 480)
    }

    // MARK: - 操作

    private var actions: some View {
        HStack(spacing: 12) {
            Button {
                controller.start(mode: .measure, store: store)
            } label: {
                Label("入力", systemImage: "figure.stand")
            }
            .help("BC-768 で測定して結果を取り込みます。本体の「入力モード」を押してください")

            Button {
                controller.start(mode: .sync, store: store)
            } label: {
                Label("確認", systemImage: "arrow.down.circle")
            }
            .help("測定は行わず、BC-768 が保持しているデータを確認して取り込みます")

            Button {
                exportCSV()
            } label: {
                Label("送信", systemImage: "square.and.arrow.up")
            }
            .help("CSV として書き出します（スプレッドシートへ貼り付ける用）")
            .disabled(store.entries.isEmpty)

            Spacer()

            if controller.isRunning {
                ProgressView().controlSize(.small)
                Button("中止") { controller.cancel() }
            }
        }
        .disabled(controller.isRunning && !controller.isRunning)
        .padding(12)
    }

    // MARK: - 状態

    private var status: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(controller.statusText)
                .font(.headline)
            if let result = controller.lastResultText {
                Text(result).font(.subheadline).foregroundStyle(.secondary)
            }
            if let error = controller.errorText {
                Text(error).font(.subheadline).foregroundStyle(.red).textSelection(.enabled)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    // MARK: - 表

    private var table: some View {
        Table(store.entries) {
            TableColumn("測定日時") { entry in
                if let date = entry.measuredAt {
                    Text(date, format: .dateTime.year().month().day().hour().minute())
                } else {
                    Text("日時なし").foregroundStyle(.secondary)
                }
            }
            TableColumn("体重") { Text(format($0.record.weightKg, unit: "kg", digits: 2)) }
            TableColumn("体脂肪率") { Text(format($0.record.bodyFatPercent, unit: "%", digits: 1)) }
            TableColumn("筋肉量") { Text(format($0.record.muscleMassKg, unit: "kg", digits: 2)) }
            TableColumn("推定骨量") { Text(format($0.record.boneMassKg, unit: "kg", digits: 2)) }
            TableColumn("BMI") { Text(format($0.record.bmi, unit: "", digits: 1)) }
            TableColumn("基礎代謝*") { Text(format($0.record.estimated.basalMetabolismKcal, unit: "kcal", digits: 0)) }
            TableColumn("体内年齢*") { Text(format($0.record.estimated.metabolicAgeYears, unit: "歳", digits: 0)) }
        }
    }

    // MARK: - ログ

    private var log: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(controller.logLines.enumerated()), id: \.offset) { index, line in
                        Text(line)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                            .id(index)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
            }
            .frame(height: 160)
            .onChange(of: controller.logLines.count) { count in
                proxy.scrollTo(count - 1, anchor: .bottom)
            }
        }
    }

    private var footer: some View {
        HStack {
            Text("\(store.entries.count) 件")
                .font(.caption).foregroundStyle(.secondary)
            Text("* は推定値")
                .font(.caption).foregroundStyle(.secondary)
            Spacer()
            Button(showsLog ? "ログを隠す" : "ログを表示") { showsLog.toggle() }
                .buttonStyle(.link)
            Button("保存先を開く") {
                NSWorkspace.shared.activateFileViewerSelecting([store.fileURL])
            }
            .buttonStyle(.link)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private func format(_ value: Double?, unit: String, digits: Int) -> String {
        guard let value else { return "—" }
        let text = String(format: "%.\(digits)f", value)
        return unit.isEmpty ? text : "\(text) \(unit)"
    }

    private func exportCSV() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "bc768.csv"
        panel.allowedContentTypes = [.commaSeparatedText]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? Data(store.csv().utf8).write(to: url)
    }
}
