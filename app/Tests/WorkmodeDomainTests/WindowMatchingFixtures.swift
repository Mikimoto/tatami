import WorkmodeDomain

// WindowMatchingTests 拆成兩個檔之後，主語料與那兩支呼叫縮寫兩邊都要用。
// dumpSlash／dumpDrifted／dumpMeta／dump4／idmap 只有 find_windows 那組用得到，
// 留在原檔。

/// test_workmode.sh:53-59。第一筆刻意是不命中的視窗：否則「取第一個命中」這條
/// 斷言分不出「正確比對」與「永遠回傳第一筆」。
let dump = [
    "170\thttps://example.com\t無關視窗",
    "161\thttps://github.com/example-org/libexample/issues/409\t示範議題標題二",
    "161\thttps://github.com/example-org\texample-org",
    "162\thttps://chat.google.com/app/chat/CHATROOM0002\tDP 專案乙組 - Chat",
    "162\thttps://github.com/example-org/libexample/issues/377\t示範議題標題 EXAMPLE_STREAM",
    "163\thttps://github.com/example-org/libexample/pull/496\t示範 PR 標題",
].joined(separator: "\n")

func found(_ kind: String, _ value: String, _ text: String) throws -> [String]? {
    try WindowMatching.findWindows(kind: kind, value: value, dump: text)
}

/// bash 那側是 `find_windows … | tr '\n' ' '`，所以每個 id 後面都有一個空白。
func joined(_ kind: String, _ value: String, _ text: String) throws -> String {
    guard let ids = try found(kind, value, text) else { return "" }
    return ids.map { $0 + " " }.joined()
}
