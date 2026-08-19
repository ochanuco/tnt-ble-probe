import AppKit
import BC768BLE
import BC768Protocol
import SwiftUI

struct ContentView: View {
    @ObservedObject var store: MeasurementStore
    @ObservedObject var controller: SessionController
    @State private var showsLog = false
    @State private var showsSetup = false

    var body: some View {
        VStack(spacing: 0) {
            if let hint = controller.configurationHint {
                configurationBanner(hint)
                Divider()
            }
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
        .frame(minWidth: 1120, minHeight: 480)
        .onAppear { controller.checkConfiguration() }
        .sheet(isPresented: $showsSetup) {
            SetupView { controller.checkConfiguration() }
        }
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
            .disabled(controller.isRunning || controller.configurationHint != nil)

            Button {
                controller.start(mode: .sync, store: store)
            } label: {
                Label("確認", systemImage: "arrow.down.circle")
            }
            .help("測定は行わず、BC-768 が保持しているデータを確認して取り込みます")
            .disabled(controller.isRunning || controller.configurationHint != nil)

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
        .padding(12)
    }

    private func configurationBanner(_ hint: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 6) {
                Text(hint).font(.callout).textSelection(.enabled)
                HStack {
                    Button("BC-768 を登録する") { showsSetup = true }
                        .buttonStyle(.borderedProminent)
                    Button("置き場所を開く") {
                        let directory = (controller.configPath as NSString).deletingLastPathComponent
                        try? FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
                        NSWorkspace.shared.open(URL(fileURLWithPath: directory))
                    }
                    Button("再確認") { controller.checkConfiguration() }
                }
            }
            Spacer()
        }
        .padding(12)
        .background(Color.orange.opacity(0.12))
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
        // TableColumnBuilder は 1 段で 10 列までしか組めないので、2 つに分けて渡す。
        // 各列は下限だけ決めて ideal を持たせない。余った幅は Table が配分するので横スクロールにならない。
        Table(store.entries) {
            bodyColumns
            scoreColumns
        }
    }

    @TableColumnBuilder<MeasurementStore.Entry, Never>
    private var bodyColumns: some TableColumnContent<MeasurementStore.Entry, Never> {
        // 日時は他より長い。既定幅では見切れるので下限を決めておく。
        TableColumn("測定日時") { entry in
            if let date = entry.measuredAt {
                Text(date, format: .dateTime.year().month().day().hour().minute())
                    .monospacedDigit()
            } else {
                Text("日時なし").foregroundStyle(.secondary)
            }
        }
        .width(min: 150)
        TableColumn("体重") { Text(format($0.record.weightKg, unit: "kg", digits: 2)) }
            .width(min: 74)
        TableColumn("体脂肪率") { Text(format($0.record.bodyFatPercent, unit: "%", digits: 1)) }
            .width(min: 70)
        TableColumn("筋肉量") { Text(format($0.record.muscleMassKg, unit: "kg", digits: 2)) }
            .width(min: 74)
        // 6024 を筋肉スコアと読んでいるが、アプリ表示との答え合わせは済んでいない。
        TableColumn("筋肉スコア†") { Text(format($0.record.muscleScore, unit: "", digits: 0)) }
            .width(min: 80)
        TableColumn("推定骨量") { Text(format($0.record.boneMassKg, unit: "kg", digits: 2)) }
            .width(min: 74)
    }

    @TableColumnBuilder<MeasurementStore.Entry, Never>
    private var scoreColumns: some TableColumnContent<MeasurementStore.Entry, Never> {
        TableColumn("BMI") { Text(format($0.record.bmi, unit: "", digits: 1)) }
            .width(min: 46)
        TableColumn("内臓脂肪Lv") { Text(format($0.record.visceralFatLevel, unit: "", digits: 1)) }
            .width(min: 76)
        TableColumn("体水分量") { Text(format($0.record.bodyWaterKg, unit: "kg", digits: 1)) }
            .width(min: 74)
        // BC-768 は体水分「率」を返さない。体重で割った計算値だと分かる列名にしておく。
        TableColumn("体水分率*") { Text(format($0.bodyWaterPercent, unit: "%", digits: 1)) }
            .width(min: 76)
        TableColumn("基礎代謝") { Text(format($0.record.basalMetabolismKcal, unit: "kcal", digits: 0)) }
            .width(min: 80)
        TableColumn("体内年齢") { Text(format($0.record.metabolicAgeYears, unit: "歳", digits: 0)) }
            .width(min: 66)
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
            Text("* 体水分量 ÷ 体重 の計算値 / † タグの対応が未確定")
                .font(.caption).foregroundStyle(.secondary)
            Spacer()
            Button("設定") { showsSetup = true }
                .buttonStyle(.link)
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
