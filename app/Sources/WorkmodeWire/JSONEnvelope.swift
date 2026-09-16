import Foundation

/// `--json` 的固定封套。給 AI 操作與我們自己的測試用。
///
/// 用 .sortedKeys：封套要鍵序穩定才好做逐位元組斷言。
/// **layout.json 的寫入器不可以用它**——那邊要保留來源順序（windows 的順序決定
/// 誰先認領視窗、profiles 的第一個是 fallback）。兩個方向相反的需求，
/// 不要為了 DRY 合併成一個序列化器。
///
/// .withoutEscapingSlashes 讓 URL 不被寫成 http:\/\/，與 jq 的預設一致。
public enum JSONEnvelope {
    public static let schema = 1

    public static func success(command: String, data: [String: Any]) throws -> String {
        try line(["schema": schema, "ok": true, "command": command, "data": data])
    }

    public static func failure(command: String, kind: String, message: String) throws -> String {
        try line(["schema": schema, "ok": false, "command": command,
                  "error": ["kind": kind, "message": message]])
    }

    /// 「檢查跑完了，結果是好是壞」的形狀：`ok` 報的是**檢查結果**，不是命令有沒有
    /// 執行成功，所以 ok 為 false 時 data 照樣在——validate 的問題清單正是呼叫端
    /// 要的東西，把它塞進 error.message 只會逼它再 parse 一次字串。
    ///
    /// 與 `failure(command:kind:message:)` 是兩回事：那個代表命令根本沒跑起來
    /// （輸入不是 JSON），沒有結果可以報，所以那邊沒有 data 是對的。
    public static func verdict(command: String, succeeded: Bool,
                               data: [String: Any]) throws -> String
    {
        // JSON 的鍵仍然是 "ok"：那是對外的 schema，改了就是改輸出格式。
        try line(["schema": schema, "ok": succeeded, "command": command, "data": data])
    }

    private static func line(_ object: [String: Any]) throws -> String {
        let data = try JSONSerialization.data(
            withJSONObject: object,
            options: [.sortedKeys, .withoutEscapingSlashes]
        )
        return String(decoding: data, as: UTF8.self)
    }
}
