import Testing
import WorkmodeDomain

private func rule(_ label: String, _ kind: String, _ value: String) -> JSONValue {
    .object([JSONMember(key: "label", value: .string(label)),
             JSONMember(key: "match", value: .array([.string(kind), .string(value)]))])
}

private func labels(_ array: JSONValue) -> [String] {
    guard case let .array(rows) = array else { return [] }
    return rows.map { row -> String in
        guard case let .string(name)? = row["label"] else { return "?" }
        return name
    }
}

/// 一份設定：共用層、地點層、profile 層各給一串 label（空陣列＝有那個鍵但沒規則，
/// nil ＝連鍵都沒有）。三層各自存不存在，正是 `place` 唯一在判斷的東西。
private func layout(shared: [String]?, local: [String]?, inProfile: [String]?) -> JSONValue {
    func windows(_ labels: [String]) -> JSONMember {
        JSONMember(key: "windows", value: .array(labels.map { rule($0, "app", $0) }))
    }
    var profile: [JSONMember] = []
    if let inProfile {
        profile.append(windows(inProfile))
    }
    var location = [JSONMember(key: "profiles", value: .object([
        JSONMember(key: "開發", value: .object(profile)),
    ]))]
    if let local {
        location.append(windows(local))
    }
    var root: [JSONMember] = []
    if let shared {
        root.append(windows(shared))
    }
    root.append(JSONMember(key: "home", value: .object(location)))
    return .object(root)
}

private func placedLabels(_ config: JSONValue, at path: [String]) -> [String]? {
    guard case let .array(rows)? = JSONPath.get(config, path.map { .key($0) }) else {
        return nil
    }
    return labels(.array(rows))
}

private func place(_ new: JSONValue, forApp app: String,
                   in config: JSONValue) -> RulePlacement.Placement
{
    RulePlacement.place(new, forApp: app, location: "home", profile: "開發", in: config)
}

/// 共用層排在地點層前面（`shared + local`），所以共用層那條 catch-all 要先贏
/// ——贏了它就同時贏了地點層那條。
@Test func theSharedLayerIsTriedBeforeTheLocationOne() {
    let config = layout(shared: ["Code", "Safari"], local: ["Tower"], inProfile: nil)
    let done = place(rule("Meet", "url-contains", "meet.google.com"),
                     forApp: "Safari", in: config)
    #expect(done.placed)
    #expect(placedLabels(done.config, at: ["windows"]) == ["Code", "Meet", "Safari"])
    #expect(placedLabels(done.config, at: ["home", "windows"]) == ["Tower"])
}

/// 共用層沒有那個 app 的 catch-all、地點層有 → 插進地點層。
/// 少了這一條，「只試共用層」與正確的實作分不出來。
@Test func aCatchAllThatOnlyExistsInTheLocationLayerIsStillBeaten() {
    let config = layout(shared: ["Code"], local: ["Safari"], inProfile: nil)
    let done = place(rule("Meet", "url-contains", "meet.google.com"),
                     forApp: "Safari", in: config)
    #expect(done.placed)
    #expect(placedLabels(done.config, at: ["windows"]) == ["Code"])
    #expect(placedLabels(done.config, at: ["home", "windows"]) == ["Meet", "Safari"])
}

/// **profile 自己有 `windows` 時它整塊取代前兩層**（`LayoutQuery.swift:115`），
/// 所以那時只有它插得進去。
///
/// 這一條是這一支存在的理由：插進共用層會回 `placed: true`（叫呼叫端別再接一次），
/// 而那條規則落在一份**沒有人讀**的陣列裡——規則就這樣消失了，
/// 而畫面上與成功完全相同。fixture 因此在共用層也放一條同 app 的 catch-all：
/// 少了它，「無條件插共用層」在這條測試上也會通過。
@Test func aProfileWithItsOwnWindowsIsTheOnlyPlaceThatCounts() {
    let config = layout(shared: ["Safari"], local: ["Tower"], inProfile: ["Code", "Safari"])
    let done = place(rule("Meet", "url-contains", "meet.google.com"),
                     forApp: "Safari", in: config)
    #expect(done.placed)
    #expect(placedLabels(done.config, at: ["home", "profiles", "開發", "windows"])
        == ["Code", "Meet", "Safari"])
    #expect(placedLabels(done.config, at: ["windows"]) == ["Safari"])
    #expect(placedLabels(done.config, at: ["home", "windows"]) == ["Tower"])
}

/// profile 有 `windows` 但那一份裡沒有這個 app 的 catch-all → **不准回頭去插共用層**。
/// 共用層對這個 profile 一個字都不算數，插進去就是把規則丟掉。
@Test func aProfileWithoutThatCatchAllDoesNotFallBackToTheSharedLayer() {
    let config = layout(shared: ["Safari"], local: nil, inProfile: ["Code"])
    let done = place(rule("Meet", "url-contains", "meet.google.com"),
                     forApp: "Safari", in: config)
    #expect(!done.placed)
    #expect(done.config == config)
}

/// 哪一層都沒有那個 app 的 catch-all → 整份設定原封不動，交回呼叫端接到落點尾端。
/// 沒有 catch-all 就沒有東西會先搶走那個視窗，接尾端是對的。
@Test func withNoCatchAllAnywhereTheConfigIsLeftAlone() {
    let config = layout(shared: ["Code"], local: ["Tower"], inProfile: nil)
    let done = place(rule("Meet", "url-contains", "meet.google.com"),
                     forApp: "Safari", in: config)
    #expect(!done.placed)
    #expect(done.config == config)
}

/// 有 catch-all → 插在它**前面**。生效規則是 `shared + local` 且先到先得，
/// 接在後面的話那條新規則永遠搶不到視窗。
@Test func aNewRuleGoesInFrontOfTheCatchAllItMustBeat() {
    let shared = JSONValue.array([rule("Office-Chat", "url-contains", "chat.google.com"),
                                  rule("Safari", "app", "Safari")])
    let placed = RulePlacement.insert(rule("Meet", "url-contains", "meet.google.com"),
                                      forApp: "Safari", into: shared)
    #expect(labels(placed.rules) == ["Office-Chat", "Meet", "Safari"])
    #expect(placed.wentBeforeCatchAll)
}

/// **對照組**：沒有 catch-all 就不動共用層，交回呼叫端接到地點層尾端。
/// 少了它，「一律插在最前面」與正確的實作分不出來。
@Test func withoutACatchAllTheSharedListIsLeftAlone() {
    let shared = JSONValue.array([rule("Office-Chat", "url-contains", "chat.google.com")])
    let placed = RulePlacement.insert(rule("Tower", "app", "Tower"),
                                      forApp: "Tower", into: shared)
    #expect(labels(placed.rules) == ["Office-Chat"])
    #expect(!placed.wentBeforeCatchAll)
}

/// 只認**同一個 app** 的 catch-all。別的 app 的那條不算。
@Test func onlyTheCatchAllForTheSameAppCounts() {
    let shared = JSONValue.array([rule("Tower", "app", "Tower"),
                                  rule("Safari", "app", "Safari")])
    let placed = RulePlacement.insert(rule("Meet", "url-contains", "meet.google.com"),
                                      forApp: "Safari", into: shared)
    #expect(labels(placed.rules) == ["Tower", "Meet", "Safari"])
}

/// 共用層不是陣列（使用者打錯）→ 什麼都不動，交回呼叫端。
@Test func aSharedListThatIsNotAnArrayIsLeftAlone() {
    let placed = RulePlacement.insert(rule("Meet", "url-contains", "x"),
                                      forApp: "Safari", into: .string("糟糕"))
    #expect(!placed.wentBeforeCatchAll)
}

/// `windows` 裡的**純量** entry 是真實會出現的輸入（`CLAUDE.md` 記過
/// `["糟糕"]`，`LayoutValidator` 對它 rc=0 零輸出），所以它必須既不當成
/// catch-all、也不讓這一支炸掉。
///
/// 沒有這一條的話 `isCatchAll` 裡那個「不是物件就回 false」的分支沒有輸入踩得到。
@Test func aScalarEntryIsNotMistakenForACatchAll() {
    let shared = JSONValue.array([.string("糟糕"), rule("Safari", "app", "Safari")])
    let placed = RulePlacement.insert(rule("Meet", "url-contains", "meet.google.com"),
                                      forApp: "Safari", into: shared)
    #expect(labels(placed.rules) == ["?", "Meet", "Safari"])
    #expect(placed.wentBeforeCatchAll)
}
