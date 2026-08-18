import BC768Protocol
import Foundation

/// 測定結果を JSON Lines として貯める。CLI の `--out` と同じ形式なので、
/// 同じファイルを指せば CLI で貯めたものもそのまま読める。
@MainActor
final class MeasurementStore: ObservableObject {
    /// 表に並べる 1 行。
    struct Entry: Identifiable {
        let id = UUID()
        let record: BC768MeasurementRecord

        var measuredAt: Date? { Self.parse(record.measuredAt) }
        var retrievedAt: Date? { Self.parse(record.retrievedAt) }
        /// 測定日時が無いレコードは取得日時で並べる。
        var sortKey: Date { measuredAt ?? retrievedAt ?? .distantPast }

        private static func parse(_ text: String?) -> Date? {
            guard let text else { return nil }
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime]
            return formatter.date(from: text)
        }
    }

    @Published private(set) var entries: [Entry] = []
    @Published private(set) var loadError: String?

    let fileURL: URL

    init(fileURL: URL? = nil) {
        self.fileURL = fileURL ?? Self.defaultFileURL()
        load()
    }

    static func defaultFileURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
        return base.appendingPathComponent("bc768-probe/records.jsonl")
    }

    func load() {
        entries = []
        loadError = nil
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        do {
            let text = try String(contentsOf: fileURL, encoding: .utf8)
            let decoder = JSONDecoder()
            var loaded: [Entry] = []
            for line in text.split(separator: "\n") where !line.isEmpty {
                guard let record = try? decoder.decode(BC768MeasurementRecord.self, from: Data(line.utf8)) else {
                    continue        // 壊れた行は読み飛ばす（他の行を失わない）
                }
                loaded.append(Entry(record: record))
            }
            entries = loaded.sorted { $0.sortKey > $1.sortKey }
        } catch {
            loadError = "読み込めませんでした: \(error.localizedDescription)"
        }
    }

    /// 1 件追記する。同じ測定日時のレコードが既にあれば何もしない。
    @discardableResult
    func append(_ record: BC768MeasurementRecord) -> Bool {
        if let measuredAt = record.measuredAt,
           entries.contains(where: { $0.record.measuredAt == measuredAt }) {
            return false
        }
        do {
            let line = try record.jsonLine() + "\n"
            let directory = fileURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            if let handle = try? FileHandle(forWritingTo: fileURL) {
                defer { try? handle.close() }
                try handle.seekToEnd()
                try handle.write(contentsOf: Data(line.utf8))
            } else {
                try Data(line.utf8).write(to: fileURL)
            }
            entries.insert(Entry(record: record), at: 0)
            entries.sort { $0.sortKey > $1.sortKey }
            return true
        } catch {
            loadError = "書き込めませんでした: \(error.localizedDescription)"
            return false
        }
    }

    /// スプレッドシートへ貼れる形にする。
    func csv() -> String {
        var lines = ["measured_at,retrieved_at,weight_kg,body_fat_percent,muscle_mass_kg,bone_mass_kg,bmi,body_water_kg,basal_metabolism_kcal,metabolic_age,visceral_fat_level"]
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        for entry in entries.sorted(by: { $0.sortKey < $1.sortKey }) {
            let record = entry.record
            let columns: [String] = [
                record.measuredAt ?? "",
                record.retrievedAt,
                format(record.weightKg), format(record.bodyFatPercent),
                format(record.muscleMassKg), format(record.boneMassKg), format(record.bmi),
                format(record.bodyWaterKg), format(record.basalMetabolismKcal),
                format(record.estimated.metabolicAgeYears), format(record.estimated.visceralFatLevel),
            ]
            lines.append(columns.joined(separator: ","))
        }
        return lines.joined(separator: "\n") + "\n"
    }

    private func format(_ value: Double?) -> String {
        guard let value else { return "" }
        return value == value.rounded() ? String(Int(value)) : String(value)
    }
}
