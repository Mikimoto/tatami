import WorkmodeCore

// `LayoutProblem` 是 `LayoutLoadFailure.invalid` 的欄位。
import WorkmodeDomain
import WorkmodeWire

/// `tatami --space --json` 與 `--probe --json` 的**最後一行**。
///
/// 這兩個命令的 `--json` 是兩層：事件流（`JSONEventRenderer`，一行一句話，那就是它的
/// schema）加上收尾的一行封套。分兩層而不是只印封套，因為套一次版面要跑好幾秒而 bash
/// 是邊做邊印的（Reporter.swift 理由 3），把整段收集起來只為了塞進一個 data 欄位會把
/// 那個性質丟掉；而只有事件流的話，消費端無法分辨「跑完了」與「中途被砍掉」。
///
/// 住在 Adapters 而不是 CLI：CLI 是 executable target，放那裡就沒有任何測試看得到它，
/// 而 `--json` **沒有差分基準**（bash 沒有這個表面），所以它的成功與失敗兩條路各需要
/// 一條 schema 斷言——那是這個型別存在的唯一理由。
public enum ApplyEnvelope {
    /// `--space` 與 `--probe` 的封套。三條早退各有自己的 kind。
    ///
    /// `.invalid` 的問題清單只進 message（用換行接起來，與 `tatami validate` 預設
    /// 模式的排列相同）而不是 data：`failure` 的形狀刻意沒有 data（見 JSONEnvelope 的
    /// doc），而要結構化的問題清單的人有 `tatami validate --json`，那支的 verdict
    /// 就是為此存在的。
    ///
    /// 2026-09-07 之前這裡是兩支：`SpaceLayout.Outcome` 逐個翻成
    /// `ApplyLayout.Outcome` 再交給另一支。那個轉接存在的理由是「訊息與 kind 抄兩份
    /// 會讓兩條路徑的 JSON 消費端看到不一樣的 kind」——而 `ApplyLayout` 退役之後
    /// 只剩一個 Outcome，那個理由自己消失了。
    public static func line(command: String, outcome: SpaceLayout.Outcome) -> String {
        switch outcome {
        case let .completed(location, profile):
            return (try? JSONEnvelope.success(
                command: command,
                data: ["location": location, "profile": profile]
            )) ?? fallback
        case let .layoutUnavailable(failure):
            let (kind, message) = describe(failure)
            return (try? JSONEnvelope.failure(command: command, kind: kind,
                                              message: message)) ?? fallback
        case .locationUnrecognized:
            return (try? JSONEnvelope.failure(
                command: command, kind: "location_unrecognized",
                // 接得上的螢幕清單已經在事件流裡（`connectedDisplayListed`），
                // 這裡不重複一份。
                message: "認不出這是哪個地點"
            )) ?? fallback
        case .profileUnresolved:
            return (try? JSONEnvelope.failure(
                command: command, kind: "profile_unresolved",
                // 哪個名字不對、有哪些可選，都在 `profileNotInLocation` 事件裡。
                message: "指定的 profile 不在這個地點底下"
            )) ?? fallback
        }
    }

    private static func describe(_ failure: LayoutLoadFailure) -> (String, String) {
        switch failure {
        case let .missing(path): ("layout_missing", "找不到設定檔：\(path)")
        case let .unreadable(path): ("layout_unreadable", "讀不到設定檔：\(path)")
        case let .unparsable(path): ("layout_invalid_json",
                                     "設定檔不是合法 JSON：\(path)")
        case let .invalid(problems):
            ("layout_invalid", problems.map(\.text).joined(separator: "\n"))
        }
    }

    /// 上面那些字典只由這個檔案產生（全是 String），序列化不可能失敗；真的失敗時
    /// 吐一個看得出來壞了的東西，而不是無聲印一個空行。
    private static let fallback = #"{"ok":false,"schema":1,"error":{"kind":"unrenderable"}}"#
}
