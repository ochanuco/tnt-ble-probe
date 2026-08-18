import Foundation

/// BC-768 の日時表現。`0x0010`（日時設定）や各応答の payload に現れる。
///
///     6a 32 <days : 2 bytes BE>       2000-01-01 起点の日数
///     6a 33 <half : 3 bytes BE>       当日 00:00 からの経過秒 × 2（0.5 秒単位）
///
/// Android HCI キャプチャの 6 サンプルすべてで、送信時刻と秒単位まで一致することを確認済み。
public enum BC768DateTime {
    public static let dayTag: [UInt8] = [0x6A, 0x32]
    public static let timeTag: [UInt8] = [0x6A, 0x33]
    /// 日数の起点。
    public static let epoch = DateComponents(year: 2000, month: 1, day: 1)

    /// `0x0010` の payload（9 バイト）を組み立てる。
    /// BC-768 はローカル時刻を期待するため、`calendar` のタイムゾーンで日付と時刻を切り出す。
    public static func encode(_ date: Date, calendar: Calendar = .current) -> Data? {
        guard let epochDate = calendar.date(from: epoch) else { return nil }
        let startOfDay = calendar.startOfDay(for: date)
        guard let days = calendar.dateComponents([.day], from: epochDate, to: startOfDay).day,
              days >= 0, days <= 0xFFFF else { return nil }
        let halfSeconds = Int((date.timeIntervalSince(startOfDay) * 2).rounded(.down))
        guard halfSeconds >= 0, halfSeconds <= 0xFFFFFF else { return nil }

        var payload = Data(dayTag)
        payload.append(UInt8(days >> 8))
        payload.append(UInt8(days & 0xFF))
        payload.append(contentsOf: timeTag)
        payload.append(UInt8((halfSeconds >> 16) & 0xFF))
        payload.append(UInt8((halfSeconds >> 8) & 0xFF))
        payload.append(UInt8(halfSeconds & 0xFF))
        return payload
    }

    /// 日数と 0.5 秒カウントから Date を作る。
    public static func date(days: Int, halfSeconds: Int, calendar: Calendar = .current) -> Date? {
        guard let epochDate = calendar.date(from: epoch),
              let startOfDay = calendar.date(byAdding: .day, value: days, to: epochDate) else { return nil }
        return startOfDay.addingTimeInterval(Double(halfSeconds) / 2)
    }

    /// TLV フィールドから測定日時を復元する。日付・時刻がともに 0 なら nil
    /// （BC-768 は時計を持たないため、接続外で測定されたレコードは日時を持たない）。
    public static func date(from fields: [BC768TLVField], calendar: Calendar = .current) -> Date? {
        guard BC768Record.hasTimestamp(fields) else { return nil }
        let days = Int(fields.first { $0.tag == 0x6A32 }?.unsignedValue ?? 0)
        let halfSeconds = Int(fields.first { $0.tag == 0x6A33 }?.unsignedValue ?? 0)
        return date(days: days, halfSeconds: halfSeconds, calendar: calendar)
    }

    /// 9 バイト payload を日付・時刻へ戻す（ログ表示と検証用）。
    public static func decode(_ payload: Data, calendar: Calendar = .current) -> Date? {
        guard payload.count >= 9 else { return nil }
        let base = payload.startIndex
        guard Array(payload[base..<(base + 2)]) == dayTag,
              Array(payload[(base + 4)..<(base + 6)]) == timeTag,
              let epochDate = calendar.date(from: epoch) else { return nil }
        let days = Int(payload[base + 2]) << 8 | Int(payload[base + 3])
        let halfSeconds = Int(payload[base + 6]) << 16 | Int(payload[base + 7]) << 8 | Int(payload[base + 8])
        guard let startOfDay = calendar.date(byAdding: .day, value: days, to: epochDate) else { return nil }
        return startOfDay.addingTimeInterval(Double(halfSeconds) / 2)
    }
}
