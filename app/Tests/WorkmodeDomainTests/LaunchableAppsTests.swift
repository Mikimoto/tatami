import Testing
import WorkmodeDomain

// `--launch` 要開哪幾個 app。這支是純函式，所以每條的鑑別值都寫得出來：
// 同一份設定 ＋ 不同的 label 清單，回傳的陣列必須不同。

/// 一條規則。`fallback` 與 `launch` 給 nil 就整個鍵不出現（設定檔的常態）。
private func lauRule(_ label: String, _ kind: String, _ value: String,
                     fallback: (String, String)? = nil,
                     launch: String? = nil) -> JSONValue
{
    var members = [
        JSONMember(key: "label", value: .string(label)),
        JSONMember(key: "match", value: .array([.string(kind), .string(value)])),
    ]
    if let fallback {
        members.append(JSONMember(
            key: "fallback", value: .array([.string(fallback.0), .string(fallback.1)])
        ))
    }
    if let launch {
        members.append(JSONMember(key: "launch", value: .string(launch)))
    }
    return .object(members)
}

/// 只有共用層 `windows` 的一份設定：`home` 底下一個 `開發`，規則全在最外層。
private func lauConfig(_ rules: [JSONValue]) -> JSONValue {
    .object([
        JSONMember(key: "windows", value: .array(rules)),
        JSONMember(key: "home", value: .object([
            JSONMember(key: "profiles", value: .object([
                JSONMember(key: "開發", value: .object([
                    JSONMember(key: "trees", value: .object([])),
                ])),
            ])),
        ])),
    ])
}

private func lauNamed(_ labels: [String], _ rules: [JSONValue]) -> [String] {
    LaunchableApps.named(labels: labels.map { JSONValue.string($0) },
                         location: "home", profile: "開發", in: lauConfig(rules))
}

/// `match` 是 `app` → 收進清單。
///
/// 鑑別值：`["Ghostty"]`。一個把 `matchValue` 與 `label` 搞混的實作回 `["Code"]`。
@Test func anAppMatchContributesItsApplicationName() {
    #expect(lauNamed(["Code"], [lauRule("Code", "app", "Ghostty")]) == ["Ghostty"])
}

/// `match` 是 url 類、`fallback` 是 `app` → 也收進清單。
///
/// 鑑別值：`["Safari"]` 對 `[]`。只看 `matchKind` 的實作回空陣列，而症狀是
/// 「這個視窗有時候開得起來、有時候不會」——規則配得到 match 時它已經在跑。
@Test func anAppFallbackContributesToo() {
    let rules = [lauRule("Docs", "url-exact", "https://x/", fallback: ("app", "Safari"))]
    #expect(lauNamed(["Docs"], rules) == ["Safari"])
}

/// 四種 match kind 裡只有 `app` 帶得出名字，其餘三種一律跳過（已知缺口）。
///
/// 鑑別值：`[]`。把 `matchValue` 無條件收進去的實作回
/// `["https://x/", "^Zed$"]`——那兩個字串餵給 `open -a` 只會失敗。
@Test func urlAndTitleRulesWithoutAnAppFallbackContributeNothing() {
    let rules = [
        lauRule("Docs", "url-exact", "https://x/"),
        lauRule("Editor", "title-regex", "^Zed$"),
    ]
    #expect(lauNamed(["Docs", "Editor"], rules).isEmpty)
}

/// 不在這一輪 label 清單裡的規則不算。
///
/// 鑑別值：`["Ghostty"]` 對 `["Ghostty", "Chat"]`。整份設定的規則都開起來的實作
/// 會在「只排一個 space」的時候把使用者所有的 app 都叫醒。
@Test func aRuleOutsideThisRoundsLabelsIsSkipped() {
    let rules = [lauRule("Code", "app", "Ghostty"), lauRule("Chat", "app", "Chat")]
    #expect(lauNamed(["Code"], rules) == ["Ghostty"])
}

/// 同一個 app 被多條規則引用只出現一次，而且留在**第一次**出現的位置。
///
/// 鑑別值：`["Ghostty", "Safari"]`。沒去重的實作回三個元素（`AppPresence.ensure`
/// 會對同一個 app 問兩次、可能等兩次逾時）；用 `Set` 直接回傳的實作順序不穩定，
/// 這條會間歇性紅。
@Test func theSameApplicationAppearsOnceAtItsFirstPosition() {
    let rules = [
        lauRule("Code", "app", "Ghostty"),
        lauRule("Docs", "app", "Safari"),
        lauRule("Term", "app", "Ghostty"),
    ]
    #expect(lauNamed(["Code", "Docs", "Term"], rules) == ["Ghostty", "Safari"])
}

// MARK: - launch 欄位

/// url 類規則寫了 `launch` → 那個 app 進清單。
///
/// **這是這個欄位存在的唯一理由**：`chat.google.com` 裡沒有任何東西可以餵給
/// `open -a`。鑑別值 `["Safari"]`——不讀 `launch` 的實作回 `[]`。
@Test func aUrlRuleWithALaunchFieldContributesThatApplication() {
    #expect(lauNamed(["Chat"], [
        lauRule("Chat", "url-contains", "chat.google.com", launch: "Safari"),
    ]) == ["Safari"])
}

/// `launch` 贏過 `match` 推出來的名字。
///
/// 鑑別值 `["Messages"]`：推出來的贏會回 `["訊息"]`，兩個都收會回
/// `["Messages", "訊息"]`（或反序）。三種實作三個不同的答案。
@Test func anExplicitLaunchWinsOverTheMatchValue() {
    #expect(lauNamed(["訊息"], [
        lauRule("訊息", "app", "訊息", launch: "Messages"),
    ]) == ["Messages"])
}

/// 空的 `launch` 與沒寫一樣：往下推 `match`。
///
/// 鑑別值 `["Ghostty"]`——把空字串當成明講的實作回 `[]`，而那會讓一個打錯的
/// `"launch": ""` 靜默關掉這條規則的自動啟動。
@Test func anEmptyLaunchFallsBackToTheMatchValue() {
    #expect(lauNamed(["Code"], [
        lauRule("Code", "app", "Ghostty", launch: ""),
    ]) == ["Ghostty"])
}

/// `launch` 不是字串（打成陣列）→ 忽略它，往下推。
///
/// 設定檔是人手改的，而 `validate` 對這個欄位什麼都不查。
@Test func aNonStringLaunchIsIgnored() {
    let rule = JSONValue.object([
        JSONMember(key: "label", value: .string("Code")),
        JSONMember(key: "match", value: .array([.string("app"), .string("Ghostty")])),
        JSONMember(key: "launch", value: .array([.string("Safari")])),
    ])
    #expect(lauNamed(["Code"], [rule]) == ["Ghostty"])
}

/// 兩條規則的 `launch` 是同一個 app → 只出現一次，位置是第一次。
@Test func twoRulesLaunchingTheSameApplicationYieldItOnce() {
    #expect(lauNamed(["Chat", "Tube"], [
        lauRule("Chat", "url-contains", "chat.google.com", launch: "Safari"),
        lauRule("Tube", "url-contains", "www.youtube.com", launch: "Safari"),
    ]) == ["Safari"])
}
