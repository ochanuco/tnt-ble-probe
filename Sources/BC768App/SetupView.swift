import AppKit
import BC768BLE
import SwiftUI

/// 「探す → 調べる → 登録」の画面。UUID は事前に知らなくてよい。
struct SetupView: View {
    @StateObject private var controller = DiscoveryController()
    @Environment(\.dismiss) private var dismiss
    /// 保存が終わったら本体側へ知らせる。
    var onSaved: () -> Void

    @State private var selection: UUID?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            HSplitView {
                peripheralList
                resultPane
            }
            Divider()
            footer
        }
        .frame(minWidth: 720, minHeight: 460)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("BC-768 を登録する").font(.title3).bold()
            Text(controller.statusText).font(.callout).foregroundStyle(.secondary)
            if let error = controller.errorText {
                Text(error).font(.callout).foregroundStyle(.red).textSelection(.enabled)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
    }

    private var peripheralList: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Button("探す") { controller.scan() }
                    .disabled(controller.isBusy)
                if controller.isBusy {
                    ProgressView().controlSize(.small)
                    Button("止める") { controller.cancel() }
                }
            }
            List(controller.peripherals, selection: $selection) { peripheral in
                VStack(alignment: .leading, spacing: 2) {
                    Text(peripheral.displayName)
                    HStack(spacing: 8) {
                        Text("RSSI \(peripheral.rssi)")
                        if let localName = peripheral.localName, localName != peripheral.name {
                            Text(localName)
                        }
                        if !peripheral.advertisedServices.isEmpty {
                            Text("\(peripheral.advertisedServices.count) service")
                        }
                    }
                    .font(.caption).foregroundStyle(.secondary)
                }
                .tag(peripheral.id)
            }
            Button("選んだ端末を調べる") {
                guard let selection,
                      let peripheral = controller.peripherals.first(where: { $0.id == selection }) else { return }
                controller.inspect(peripheral)
            }
            .disabled(selection == nil || controller.isBusy)
        }
        .padding(12)
        .frame(minWidth: 280)
    }

    private var resultPane: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if let layout = controller.layout {
                    Text("見つかった構成").font(.headline)
                    Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
                        row("SERVICE_UUID", layout.service.uuidString)
                        ForEach(Array(layout.writeChars.enumerated()), id: \.offset) { index, uuid in
                            row("WRITE_CHAR_\(index + 1)", uuid.uuidString)
                        }
                        ForEach(Array(layout.notifyChars.enumerated()), id: \.offset) { index, uuid in
                            row("NOTIFY_CHAR_\(index + 1)", uuid.uuidString)
                        }
                    }

                    Divider()

                    VStack(alignment: .leading, spacing: 6) {
                        Text("クライアント識別子").font(.headline)
                        Text("上の UUID とは別物です。Health Planet が使っている 36 文字の識別子を入れてください。BC-768 に登録済みの値でないと拒否されます。")
                            .font(.caption).foregroundStyle(.secondary)
                        TextField("00000000-0000-0000-0000-000000000000", text: $controller.clientID)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(.body, design: .monospaced))
                        if let issue = controller.clientIDIssue {
                            Label(issue, systemImage: "exclamationmark.triangle.fill")
                                .font(.caption)
                                .foregroundStyle(.orange)
                        }
                    }
                } else if !controller.inspectedServices.isEmpty {
                    Text("調べた結果").font(.headline)
                    ForEach(Array(controller.inspectedServices.enumerated()), id: \.offset) { _, service in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(service.uuid.uuidString).font(.system(.caption, design: .monospaced))
                            ForEach(Array(service.characteristics.enumerated()), id: \.offset) { _, characteristic in
                                Text("  \(characteristic.uuid.uuidString) [\(characteristic.properties.description)]")
                                    .font(.system(.caption2, design: .monospaced))
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                } else {
                    Text("「探す」で端末を一覧し、BC-768 を選んで「調べる」を押してください。UUID は自動で割り出します。")
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
        }
    }

    @ViewBuilder
    private func row(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label).font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
            Text(value).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
        }
    }

    private var footer: some View {
        HStack {
            Text(controller.savedPath.map { "保存先: \($0)" } ?? controller.configPath)
                .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            Spacer()
            Button("閉じる") { dismiss() }
            Button("保存") {
                controller.save()
                if controller.savedPath != nil {
                    onSaved()
                }
            }
            .keyboardShortcut(.defaultAction)
            .disabled(controller.layout == nil || controller.isBusy || controller.clientIDIssue != nil)
        }
        .padding(12)
    }
}
