import Testing
import WorkmodeDomain
import WorkmodeEditorModel
import WorkmodeWire

/// 每個集合的來源順序都刻意與位元組排序相反（`office` 在 `home` 前、`開發` 在
/// `會議` 前、`main` 在 `external` 前、`Ghostty` 在 `Chat` 前、樹獨有的角色
/// `投影` 在 `second` 前），否則「投影偷偷排序了」這個突變會全綠。
///
/// `筆電` 沒有 `displays`：`LayoutValidator` 仍把它當地點並報它缺欄位，
/// 所以投影也必須列出它，否則使用者看不到那個要修的東西。
///
/// `windows` 三層都有：最外層兩條、`office` 與 `home` 各一條、`office ▸ 開發`
/// 一條。使用者現在那份檔實測就是「最外層 4 條 ＋ office 1 條 ＋ home 1 條」，
/// 只讀最外層會漏掉三分之一。
///
/// `home ▸ 開發` 的 `spaceTrees` 有兩個 `home.displays` 沒有的角色（`投影`／`second`）：
/// 那是 `workmode --space` 會直接跳過的角色（螢幕沒接上），
/// 而 `validate` 對它一聲不吭——編輯器不畫的話沒有任何地方看得到它。
private let sample = """
{"windows":[{"label":"Ghostty","match":["app","Ghostty"]},\
{"label":"Chat","match":["url-contains","chat.google.com"],\
"fallback":["title-regex","甲|乙"]}],\
"office":{"desc":"辦公室","displays":{"main":"AAA","external":"BBB",\
"投影機":7,"備用":null},\
"windows":[{"label":"郵件","match":["app","Mail"]}],\
"profiles":{"開發":{"windows":[{"label":"Aa專屬","match":["app","P"]}],\
"trees":{"main":{"window":"Ghostty"},\
"external":{"window":"Chat"}}},"會議":{"trees":{}}}},\
"home":{"desc":"家","displays":{"main":"CCC"},\
"windows":[{"label":"Safari","match":["app","Safari"]}],\
"profiles":{"開發":{"trees":{"main":{"window":"Chat"}},\
"spaceTrees":{"投影":{"S-1":{"window":"Ghostty"}},\
"second":{"S-1":{"window":"Chat"}}}}}},\
"筆電":{"desc":"筆電"}}
"""

private func document() throws -> LayoutDocument {
    try LayoutDocument(root: JSONParser.parse(sample))
}

/// 地點的順序照來源，不排序：側欄的順序要與檔案一致，否則使用者對不起來。
@Test func listsLocationsInSourceOrder() throws {
    #expect(try document().locations == ["office", "home", "筆電"])
}

/// `windows` 是最外層的鍵但不是地點。判準是「不是那個保留字」，
/// 與 `LayoutValidator.swift:21` 及 `LayoutQuery.reservedKey` 一致。
@Test func theWindowsKeyIsNotALocation() throws {
    #expect(try !document().locations.contains("windows"))
}

/// 用「有沒有 displays」分辨地點會讓這條紅：validator 對 `筆電` 報
/// 「缺 desc／displays.main」，投影卻整個不畫它，兩邊講的話會不一樣。
@Test func aLocationWithoutDisplaysIsStillALocation() throws {
    let doc = try document()
    #expect(doc.locations.contains("筆電"))
    #expect(doc.displayRoles(in: "筆電") == [])
}

@Test func listsProfilesAndRoles() throws {
    let doc = try document()
    #expect(doc.profiles(in: "office") == ["開發", "會議"])
    #expect(doc.roles(location: "office", profile: "開發") == ["main", "external"])
    #expect(doc.profiles(in: "沒這個地點") == [])
    #expect(doc.roles(location: "office", profile: "沒這個 profile") == [])
}

@Test func readsTheTreeForARole() throws {
    let doc = try document()
    #expect(doc.tree(location: "office", profile: "開發", role: "main")
        == .window(label: "Ghostty", ratio: nil))
    #expect(doc.tree(location: "office", profile: "開發", role: "external")
        == .window(label: "Chat", ratio: nil))
    // 不存在的路徑回 .empty，不是 nil——UI 畫得出「未指定」就好，不必處理兩種空。
    #expect(doc.tree(location: "office", profile: "開發", role: "沒這個角色")
        == .empty)
}

@Test func readsTheDisplayRoles() throws {
    let doc = try document()
    #expect(doc.displayRoles(in: "office") == ["main", "external", "投影機", "備用"])
    #expect(doc.displayUUID(location: "office", role: "external") == "BBB")
    #expect(doc.displayUUID(location: "office", role: "沒這個角色") == nil)
    // 非字串的 uuid 印出來而不是當成沒定義：nil 會讓那一列從畫面上消失，
    // 而它正是使用者要修的東西。`null` 才是「沒定義」——`LayoutQuery.locationDisplay`
    // 的 `// empty` 假值只有 null 與 false，這裡照它。
    #expect(doc.displayUUID(location: "office", role: "投影機") == "7")
    #expect(doc.displayUUID(location: "office", role: "備用") == nil)
}

/// 有 display 沒 tree 的角色照樣要列（畫成「未指定」），順序照 `displays` 的來源
/// 鍵序——`office` 那四個刻意不是排序的，偷偷排序會轉紅。
@Test func listsEveryDisplayRoleEvenWithoutATree() throws {
    #expect(try document().canvasRoles(location: "office", profile: "會議") == [
        CanvasRole(role: "main", hasDisplay: true),
        CanvasRole(role: "external", hasDisplay: true),
        CanvasRole(role: "投影機", hasDisplay: true),
        CanvasRole(role: "備用", hasDisplay: true),
    ])
}

/// **有 spaceTree 沒 display 的角色也要列，接在後面。** `workmode --space` 走到它
/// 只會說一句「螢幕沒接上」然後跳過，而 `validate` 對它一聲不吭——只照 `displayRoles`
/// 畫的話那兩棵樹在編輯器裡完全不存在，使用者沒有任何地方看得到要修的東西。
///
/// **2026-08-30 之前第二段讀的是 `trees`**：那半現在編輯器碰不到（分頁只編
/// `spaceTrees`），列出來也沒有東西可以編。
///
/// `投影` 寫在 `second` 前面而位元組序相反，所以第二段偷偷排序也會轉紅。
@Test func listsSpaceTreeRolesThatHaveNoDisplay() throws {
    #expect(try document().canvasRoles(location: "home", profile: "開發") == [
        CanvasRole(role: "main", hasDisplay: true),
        CanvasRole(role: "投影", hasDisplay: false),
        CanvasRole(role: "second", hasDisplay: false),
    ])
}

/// 兩邊都有的角色只出現一次，而且算「有螢幕」。
@Test func aRoleWithBothATreeAndADisplayIsListedOnce() throws {
    #expect(try document().canvasRoles(location: "office", profile: "開發") == [
        CanvasRole(role: "main", hasDisplay: true),
        CanvasRole(role: "external", hasDisplay: true),
        CanvasRole(role: "投影機", hasDisplay: true),
        CanvasRole(role: "備用", hasDisplay: true),
    ])
}

/// fallback 是選配的，兩種形狀在 layout.json 裡都合法。
///
/// 三層都要列，而且順序是「共用 →（每個地點：它自己的 → 它每個 profile 的）」。
/// 只讀最外層的話，寫在地點層與 profile 層的規則在編輯器裡完全看不到——而畫布上
/// 那格顯示的 label 正是從那些層來的。順序也是斷言的一部分：`sample` 的 label
/// 刻意不是排序的（`Ghostty` 在 `Chat` 前、`Aa專屬` 排最前面卻寫在第四），
/// 所以偷偷 `.sorted` 會轉紅。
///
/// 索引也是斷言的一部分，而且**這張表是唯一釘得住它的**：後三條都是各自那一層的
/// 第 0 條而扁平位置分別是 2、3、4，所以「索引改成扁平清單裡的位置」這個突變
/// 只有在這裡轉紅（`layered` 那份 fixture 的兩條規則一條在最前、另一條的層被
/// `filter` 濾掉，兩種算法給的值相同）。
@Test func listsRulesFromAllThreeLayersInSourceOrder() throws {
    #expect(try document().allRules == [
        ScopedRule(scope: .shared, index: 0,
                   row: RuleRow(label: "Ghostty", matchKind: "app", matchValue: "Ghostty",
                                fallbackKind: nil, fallbackValue: nil)),
        ScopedRule(scope: .shared, index: 1,
                   row: RuleRow(label: "Chat", matchKind: "url-contains",
                                matchValue: "chat.google.com",
                                fallbackKind: "title-regex", fallbackValue: "甲|乙")),
        ScopedRule(scope: .location("office"), index: 0,
                   row: RuleRow(label: "郵件", matchKind: "app", matchValue: "Mail",
                                fallbackKind: nil, fallbackValue: nil)),
        ScopedRule(scope: .profile(location: "office", profile: "開發"), index: 0,
                   row: RuleRow(label: "Aa專屬", matchKind: "app", matchValue: "P",
                                fallbackKind: nil, fallbackValue: nil)),
        ScopedRule(scope: .location("home"), index: 0,
                   row: RuleRow(label: "Safari", matchKind: "app", matchValue: "Safari",
                                fallbackKind: nil, fallbackValue: nil)),
    ])
}

/// UI 只在真的有 profile 層規則時才提示「取代不是疊加」，判準就是這一支。
/// 寫錯成 `.location` 的話畫面上零訊號——`WorkmodeEditorUI` 沒有測試驗得到。
@Test func onlyProfileScopeCountsAsProfileScoped() {
    #expect(RuleScope.profile(location: "office", profile: "開發").isProfileScoped)
    #expect(!RuleScope.location("office").isProfileScoped)
    #expect(!RuleScope.shared.isProfileScoped)
}

/// 畸形的規則不能從表格裡消失。`__diff validate` 實測：**物件**與 null 的 entry 還會
/// 被算進 label 清單（兩筆缺 label 的物件報「label 重複（）」rc=1），但混進一筆
/// **純量** entry（下面的 `"糟糕"`）整份設定就 rc=0 零輸出，連別處不相關的違規也被吞掉
/// （`jqMapLabel` 對純量回 nil、串流中止，`LayoutValidatorJQ.swift:104-106`）。
/// 因此這張表是使用者唯一看得到那一列的地方。值照 `JQPrint.interpolate` 印，與
/// validator 的訊息用同一支，兩邊的文字才會一致。
///
/// 第三筆的 `"fallback":7` 釘住「看鍵存不存在、不看形狀」：改成看形狀（`case .array`）
/// 它會變回兩個 nil，那一列在表格上與「本來就沒有 fallback」再也分不出來。
@Test func keepsMalformedRulesVisible() throws {
    let root = try JSONParser.parse(
        #"{"windows":[{"label":7,"match":"app"},"糟糕",{"label":"X","fallback":7}]}"#
    )
    #expect(LayoutDocument(root: root).allRules == [
        ScopedRule(scope: .shared, index: 0,
                   row: RuleRow(label: "7", matchKind: "null", matchValue: "null",
                                fallbackKind: nil, fallbackValue: nil)),
        ScopedRule(scope: .shared, index: 1,
                   row: RuleRow(label: "null", matchKind: "null", matchValue: "null",
                                fallbackKind: nil, fallbackValue: nil)),
        ScopedRule(scope: .shared, index: 2,
                   row: RuleRow(label: "X", matchKind: "null", matchValue: "null",
                                fallbackKind: "null", fallbackValue: "null")),
    ])
}

/// 六種 `windows` 各一個 profile。來源順序刻意不是位元組序——UTF-8 排出來是
/// 「否 壞 有 空 缺 零」，`office` 也排在 `home` 前（位元組序相反），所以
/// 「偷偷排序」與「只回 profile 層」兩種突變都會轉紅。地點層自己寫一個空陣列：
/// profile 層才有東西可以蓋掉，而那一列本身就是「宣告了卻零列」的第三個樣本。
///
/// 每種的行為都是拿**這一份設定**跑 `__diff windows_for office <profile>` 量的
/// （2026-08-19）：`缺`／`零`／`否` 都印一行共用規則（沿用前面幾層）、`空` 零行、
/// `有` 印那條專屬的，而 `壞` 是 rc=5 的硬錯——同一份設定 `__diff validate` 回 rc=0。
///
/// `cafe` 是**第三個地點，存在的理由只有一個**：讓 `.location` 這種 scope 也有真的
/// 規則。少了它，這份 fixture 只有 `.shared` 與 `.profile` 兩種帶得出列
/// （`office` 是空陣列、`home` 連鍵都沒有），而
/// `everyRuleIsAddressableByItsScopePathAndIndex` 要三種 scope 都走得到才算驗過
/// `windowsPath`。**不改 `office` 的 `[]` 去湊**：那一列是
/// `onlyProfileLayersReplaceEverythingWithNothing` 唯一的地點層樣本——它證明的
/// 正是「地點層的空陣列不算取代」，換掉那條測試就沒有反例可用。兩條規則而不是一條，`.location` 的層內索引才有 0 與 1 兩個值。
/// 順序照舊與位元組序相反（`甲店` 寫在 `乙店` 前，而 UTF-8 是 `乙`＜`甲`；
/// `cafe` 排在最後而位元組序它最小）。
private let layered = """
{"windows":[{"label":"共用","match":["app","A"]}],\
"office":{"desc":"辦","windows":[],"profiles":{\
"缺":{"trees":{}},\
"空":{"windows":[],"trees":{}},\
"零":{"windows":null,"trees":{}},\
"否":{"windows":false,"trees":{}},\
"壞":{"windows":7,"trees":{}},\
"有":{"windows":[{"label":"專屬","match":["app","P"]}],"trees":{}}}},\
"home":{"desc":"家"},\
"cafe":{"desc":"咖啡店","windows":[{"label":"甲店","match":["app","C"]},\
{"label":"乙店","match":["app","D"]}]}}
"""

/// `declaresRules` 照 jq 的 `//` 判真假，不是照「鍵在不在」：`null` 與 `false` 與
/// 缺鍵同一條路（實測三者的 `windows_for` 輸出逐字相同），把它們算成「有宣告」
/// 會讓一份完全正常的設定被指控「宣告了卻看不到」。
@Test func declaresRulesFollowsJQTruthinessNotKeyPresence() throws {
    let doc = try LayoutDocument(root: JSONParser.parse(layered))
    let byScope = doc.ruleLayers.reduce(into: [String: RuleLayer]()) {
        if case let .profile(_, profile) = $1.scope {
            $0[profile] = $1
        }
    }
    #expect(byScope["缺"]?.declaresRules == false)
    #expect(byScope["零"]?.declaresRules == false)
    #expect(byScope["否"]?.declaresRules == false)
    #expect(byScope["空"]?.declaresRules == true)
    #expect(byScope["壞"]?.declaresRules == true)
    #expect(byScope["有"]?.declaresRules == true)
}

/// 每個地點與每個 profile 都有一列，順序與 `allRules` 的分層順序相同——只回
/// profile 層（或偷偷排序）就會轉紅。`ruleCount` 是那一層在表格上的列數：
/// 空陣列與非陣列都是 0，那正是「有宣告但看不到」。
@Test func countsEveryLayerInSourceOrder() throws {
    #expect(try LayoutDocument(root: JSONParser.parse(layered)).ruleLayers == [
        RuleLayer(scope: .shared, declaresRules: true, ruleCount: 1,
                  declaresArray: true),
        RuleLayer(scope: .location("office"), declaresRules: true, ruleCount: 0,
                  declaresArray: true),
        RuleLayer(scope: .profile(location: "office", profile: "缺"),
                  declaresRules: false, ruleCount: 0, declaresArray: false),
        RuleLayer(scope: .profile(location: "office", profile: "空"),
                  declaresRules: true, ruleCount: 0, declaresArray: true),
        RuleLayer(scope: .profile(location: "office", profile: "零"),
                  declaresRules: false, ruleCount: 0, declaresArray: false),
        RuleLayer(scope: .profile(location: "office", profile: "否"),
                  declaresRules: false, ruleCount: 0, declaresArray: false),
        RuleLayer(scope: .profile(location: "office", profile: "壞"),
                  declaresRules: true, ruleCount: 0, declaresArray: false),
        RuleLayer(scope: .profile(location: "office", profile: "有"),
                  declaresRules: true, ruleCount: 1, declaresArray: true),
        RuleLayer(scope: .location("home"), declaresRules: false, ruleCount: 0,
                  declaresArray: false),
        RuleLayer(scope: .location("cafe"), declaresRules: true, ruleCount: 2,
                  declaresArray: true),
    ])
}

/// **只有 profile 層的空陣列會取代。** 共用層與地點層之間永遠是疊加
/// （`ScopedRule.swift` 檔頭的實測），所以 `office` 那個空陣列什麼都沒做——
/// 它出現在這份清單裡就是那句假警示的成因（2026-08-29 拿使用者真的設定實測，
/// 六條共用規則全部生效而畫面說被取代了）。
@Test func onlyProfileLayersReplaceEverythingWithNothing() throws {
    let doc = try LayoutDocument(root: JSONParser.parse(layered))
    #expect(doc.profileLayersReplacingWithNothing.map(\.scope) == [
        .profile(location: "office", profile: "空"),
    ])
}

/// 非陣列與層無關：`windows_for` 對它是 rc=5 的硬錯，任何一層寫了都會讓套用失敗。
@Test func aNonArrayBreaksApplyingNoMatterWhichLayer() throws {
    let doc = try LayoutDocument(root: JSONParser.parse(layered))
    #expect(doc.layersWithNonArrayRules.map(\.scope) == [
        .profile(location: "office", profile: "壞"),
    ])
}

/// 索引是**它在自己那一層的**位置，不是在 allRules 這個扁平清單裡的位置——
/// 編輯要拿它去組 `[.key(地點), .key("windows"), .index(N)]` 這種路徑。
///
/// **後面兩組才是有牙齒的那兩組，第一組單獨存在等於沒驗。** 共用層那條是整份
/// `allRules` 的第一條，所以「層內索引」與「扁平位置」給它的值都是 0；`office`
/// 是空陣列，兩種算法都給空清單。把索引改成累加的扁平計數器時，只有
/// `cafe`（層內 0、1 vs 扁平 2、3）與 `有`（層內 0 vs 扁平 1）分得出來。
/// 2026-08-19 實測：只有前兩組時那個突變全綠。
@Test func eachRuleKnowsItsIndexWithinItsOwnLayer() throws {
    let doc = try LayoutDocument(root: JSONParser.parse(layered))
    let shared = doc.allRules.filter { $0.scope == .shared }
    #expect(shared.map(\.index) == Array(0 ..< shared.count))

    let office = doc.allRules.filter { $0.scope == .location("office") }
    #expect(office.map(\.index) == Array(0 ..< office.count))

    let cafe = doc.allRules.filter { $0.scope == .location("cafe") }
    #expect(cafe.map(\.index) == Array(0 ..< cafe.count))

    let owned = doc.allRules.filter {
        $0.scope == .profile(location: "office", profile: "有")
    }
    #expect(owned.map(\.index) == Array(0 ..< owned.count))
}

/// `scope.windowsPath + [.index(index)]` 要真的指到產生那一列的那個 entry。
///
/// **這是 `windowsPath` 唯一的守衛**，而下一個 task 整個靠它定位每一條規則。
///
/// `.profile` 那個 case 少一段 `.key("profiles")` 的話，路徑變成
/// `office ▸ 有 ▸ windows`——**不是**另一層真實存在的陣列，而是一條不存在的路徑，
/// 所以這條是靠下面那個 `Issue.record` 轉紅的（2026-08-20 重跑該突變，訊息是
/// `專屬 的路徑取不到東西：[…key("office"), key("有"), key("windows"), index(0)]`）。
/// 原本這裡寫「會變成 `office ▸ windows`、靜默打在別人身上」，那是假的：要打到別層
/// 得同時少掉 `.key(profile)`。**兩種失敗都得擋**，而它們靠不同的斷言——指到別層時
/// `JSONPath.get` 拿得到值，只有下面比 `label` 那句分得出來。
///
/// 寫成性質而不是逐一列舉三種 scope：fixture 一改就自動涵蓋新的層。
/// 比對 `label` 而不是只驗非 nil——指錯到另一條合法規則同樣是非 nil。
/// `row.label` 走過 `JQPrint.interpolate`，所以這裡用同一支再算一次才比得起來
/// （fixture 的 label 都是字串，但用同一支就不必替畸形 entry 開例外）。
@Test func everyRuleIsAddressableByItsScopePathAndIndex() throws {
    let doc = try LayoutDocument(root: JSONParser.parse(layered))
    // 三種 scope 都要有規則，否則這條性質會靜默漏掉某一種而看起來照樣綠。
    #expect(doc.allRules.contains { $0.scope == .shared })
    #expect(doc.allRules.contains { $0.scope == .location("cafe") })
    #expect(doc.allRules.contains { $0.scope.isProfileScoped })

    for rule in doc.allRules {
        let path = rule.scope.windowsPath + [JSONPath.Step.index(rule.index)]
        guard let entry = JSONPath.get(doc.root, path) else {
            Issue.record("\(rule.row.label) 的路徑取不到東西：\(path)")
            continue
        }
        #expect(JQPrint.interpolate(entry["label"] ?? .null) == rule.row.label)
    }
}

/// 拿索引組出來的路徑要真的指到那一條。
@Test func theIndexAddressesTheRuleItCameFrom() throws {
    let doc = try LayoutDocument(root: JSONParser.parse(layered))
    guard let first = doc.allRules.first(where: { $0.scope == .shared }) else {
        Issue.record("fixture 應該有共用層規則"); return
    }
    // 名字不叫 `at`：swiftlint 的 identifier_name 要求至少 3 個字元。
    let found = JSONPath.get(doc.root, [.key("windows"), .index(first.index), .key("label")])
    #expect(found != nil)
}

/// UI 那行「取代不是疊加」的條件。**空陣列也算**——它照樣取代，而它在 `allRules`
/// 裡一列都沒有，所以拿 `allRules` 判會漏掉正好最需要提示的那一種。
@Test func profileLayersThatDeclareRulesAreDetectedIncludingEmptyOnes() throws {
    #expect(try LayoutDocument(root: JSONParser.parse(layered))
        .anyProfileLayerDeclaresRules)
    // 只有空陣列的那一個 profile：`allRules` 裡沒有它的列，`ruleLayers` 有。
    let onlyEmpty = """
    {"windows":[{"label":"共用","match":["app","A"]}],\
    "office":{"desc":"辦","profiles":{"空":{"windows":[]}}}}
    """
    let doc = try LayoutDocument(root: JSONParser.parse(onlyEmpty))
    #expect(!doc.allRules.contains { $0.scope.isProfileScoped })
    #expect(doc.anyProfileLayerDeclaresRules)
    // 反面：沒有任何 profile 宣告時不得為真，否則那行提示永遠出現。
    let none = """
    {"windows":[{"label":"共用","match":["app","A"]}],\
    "office":{"desc":"辦","profiles":{"缺":{"trees":{}},"零":{"windows":null}}}}
    """
    #expect(try !LayoutDocument(root: JSONParser.parse(none))
        .anyProfileLayerDeclaresRules)
}
