import WorkmodeDomain

// LayoutQueryTests 拆成兩個檔之後，這幾份設定與取值工具兩邊都要用。
//
// 三份設定各自釘一種形狀：goodJSON 是單地點單 profile、l2JSON 有兩個 profile 與
// 備援比對、sharedJSON 把 windows 放在最外層當共用總表。名字沿用
// tests/test_workmode.sh 的常數名，好對回去。

let noTrees = obj([("trees", .object([]))])

// tests/test_workmode.sh:74-81 的 GOOD_JSON。
let goodJSON = obj([
    ("office", obj([("desc", .string("A+B")),
                    ("displays", obj([("main", .string("AAAA-MAIN")),
                                      ("second", .string("AAAA-CHAT"))])),
                    ("exile", .array([.string("main")])),
                    ("windows", .array([])),
                    ("profiles", obj([("開發", noTrees)]))])),
    ("home", obj([("desc", .string("C+D")),
                  ("displays", obj([("main", .string("BBBB-MAIN")),
                                    ("second", .string("BBBB-CHAT"))])),
                  ("exile", .array([.string("main")])),
                  ("windows", .array([])),
                  ("profiles", obj([("開發", noTrees)]))])),
])

// tests/test_workmode.sh:100-130 的 L2_JSON。「會議」覆寫 windows 與 exile，
// 「開發」兩者都不寫——「取代」與「沿用」兩條路徑各有覆蓋。
let l2JSON = obj([
    ("home", obj([
        ("desc", .string("C+D")),
        ("displays", obj([("main", .string("BBBB-MAIN")),
                          ("second", .string("BBBB-CHAT"))])),
        ("exile", .array([.string("main")])),
        ("windows", .array([
            rule("A", "app", "AA"),
            rule("B", "app", "BB"),
            rule("C", "url-contains", "cc.example.com", fallback: ("title-regex", "甲|乙")),
            rule("M", "app", "MM"),
        ])),
        ("default", .string("開發")),
        ("profiles", obj([
            ("開發", noTrees),
            ("會議", obj([("exile", .array([.string("main"), .string("second")])),
                        ("windows", .array([rule("M", "app", "MM")])),
                        ("trees", .object([]))])),
        ])),
    ])),
])

// tests/test_workmode.sh:147-167 的 SHARED_JSON：最外層的 windows 是共用總表。
let sharedJSON = obj([
    ("windows", .array([
        rule("S1", "app", "S1A"),
        rule("S2", "url-contains", "s2.example.com", fallback: ("title-regex", "丙|丁")),
    ])),
    ("home", obj([
        ("desc", .string("C+D")),
        ("displays", obj([("main", .string("BBBB-MAIN"))])),
        ("exile", .array([.string("main")])),
        ("windows", .array([rule("L1", "app", "L1A")])),
        ("default", .string("開發")),
        ("profiles", obj([
            ("開發", noTrees),
            ("會議", obj([("windows", .array([rule("M", "app", "MM")])),
                        ("trees", .object([]))])),
        ])),
    ])),
])

/// 對照 bash 的 `jq -c 'del(.home.windows)'`（tests/test_workmode.sh:169）——
/// 從 sharedJSON 現算而不是另抄一份，抄一份就會與它漂移。
func deletingHomeWindows(_ config: JSONValue) -> JSONValue {
    guard case let .object(top) = config else { return config }
    return .object(top.map { member in
        guard member.key == "home", case let .object(home) = member.value else { return member }
        return JSONMember(key: "home", value: .object(home.filter { $0.key != "windows" }))
    })
}

let noLocalJSON = deletingHomeWindows(sharedJSON)

/// 收集器。走訪是 streaming 的（bash 那側 jq 邊算邊印，錯誤發生前印出來的行留在
/// stdout 上），所以 API 是 callback；要整份結果的測試自己收。
func collectRules(_ location: String, _ profile: String,
                  _ config: JSONValue) throws -> [WindowRule]
{
    var out: [WindowRule] = []
    try LayoutQuery.windowRules(location: location, profile: profile, in: config) { out.append($0) }
    return out
}

func labels(_ location: String, _ profile: String,
            _ config: JSONValue) throws -> [JSONValue]
{
    try collectRules(location, profile, config).map(\.label)
}
