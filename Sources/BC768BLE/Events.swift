import BC768Protocol
import Foundation

public enum BC768LogLevel: Int, Comparable, Sendable {
    case error = 0
    case info = 1
    case debug = 2

    public static func < (lhs: BC768LogLevel, rhs: BC768LogLevel) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// セッションの進み具合。GUI はこれを見て表示を切り替える。
public enum BC768Phase: Sendable {
    case scanning
    case connecting
    case discovering
    case subscribing
    /// ハンドシェイクの各ステップ（identify / session / measure など）。
    case handshaking(step: String)
    /// 測定の開始を要求した。人が体組成計へ乗るのを待っている。
    case waitingForMeasurement
    case completed
}

/// セッションの終了理由。
public enum BC768Completion: Sendable {
    case finished
    /// 対象が見つからなかった、接続に失敗した、応答がない等。
    case failed(String)
    /// 呼び出し側から停止した。
    case cancelled
}

/// BLE セッションから流れてくる出来事。
/// CLI はこれをそのままログへ、GUI は phase と record を使う。
public enum BC768Event {
    /// `[TAG] key=value` 形式の構造化ログ。
    case log(tag: String, fields: [(String, String?)], level: BC768LogLevel)
    /// 自由記述のメッセージ。
    case message(String, BC768LogLevel)
    /// 進み具合。
    case phase(BC768Phase)
    /// 測定結果を受け取った。
    case record(BC768MeasurementRecord)
    /// セッション終了。これ以降イベントは流れない。
    case completed(BC768Completion)
}
