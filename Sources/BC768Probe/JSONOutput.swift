import BC768Protocol
import Foundation

/// 測定結果を JSON として書き出す。
/// 標準出力（`--json`）と追記ファイル（`--out`）の両方に対応し、どちらも指定できる。
enum JSONOutput {
    static func emit(_ record: BC768MeasurementRecord, options: Options) {
        guard options.json || options.outputPath != nil else { return }
        if options.onlyNew, !record.isNewMeasurement {
            Log.info("新規の測定結果ではないため JSON は出力しません（--only-new）。")
            return
        }

        let line: String
        do {
            line = try record.jsonLine()
        } catch {
            Log.error("JSON へ変換できませんでした: \(error)")
            return
        }

        if options.json {
            let text: String
            if options.jsonPretty, let pretty = try? record.prettyJSON() {
                text = pretty
            } else {
                text = line
            }
            FileHandle.standardOutput.write(Data((text + "\n").utf8))
        }

        if let path = options.outputPath {
            append(line, to: (path as NSString).expandingTildeInPath)
        }
    }

    /// JSON Lines として 1 行追記する。ファイルが無ければ作る。
    private static func append(_ line: String, to path: String) {
        let data = Data((line + "\n").utf8)
        let manager = FileManager.default
        if !manager.fileExists(atPath: path) {
            let directory = (path as NSString).deletingLastPathComponent
            if !directory.isEmpty, !manager.fileExists(atPath: directory) {
                try? manager.createDirectory(atPath: directory, withIntermediateDirectories: true)
            }
            guard manager.createFile(atPath: path, contents: data) else {
                Log.error("ファイルを作成できませんでした: \(path)")
                return
            }
            Log.info("JSON を書き出しました: \(path)")
            return
        }
        guard let handle = FileHandle(forWritingAtPath: path) else {
            Log.error("ファイルを開けませんでした: \(path)")
            return
        }
        defer { try? handle.close() }
        do {
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
            Log.info("JSON を追記しました: \(path)")
        } catch {
            Log.error("ファイルへ書き込めませんでした: \(path) (\(error))")
        }
    }
}
