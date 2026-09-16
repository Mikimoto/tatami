import WorkmodeDomain

// resolve_profile 與 merge_profile 拆成兩個檔之後，兩邊都要這份設定，所以搬到這裡。
//
// 名字帶 profile 前綴是刻意的：LayoutQueryTests 另有一份同樣譯自 test_workmode.sh
// L2_JSON 的 fixture，但那份的 trees 是空的，兩者不能互換。撞名的話會挑到哪一個
// 完全看檔案，而測試會照樣通過。

let profileL2JSON = obj([
    ("home", obj([
        ("desc", .string("C+D")),
        ("displays", obj([("main", .string("BBBB-MAIN")),
                          ("second", .string("BBBB-CHAT"))])),
        ("exile", .array([.string("main")])),
        ("windows", .array([
            rule("A", "app", "AA"),
            rule("B", "app", "BB"),
            obj([("label", .string("C")),
                 ("match", .array([.string("url-contains"), .string("cc.example.com")])),
                 ("fallback", .array([.string("title-regex"), .string("甲|乙")]))]),
            rule("M", "app", "MM"),
        ])),
        ("default", .string("開發")),
        ("profiles", obj([
            ("開發", obj([("trees", obj([
                ("main", obj([("axis", .string("vertical")),
                              ("children", .array([obj([("window", .string("A"))]),
                                                   obj([("window", .string("B"))])]))])),
                ("second", obj([("window", .string("C")), ("ratio", .number("0.75"))])),
            ]))])),
            ("會議", obj([
                ("exile", .array([.string("main"), .string("second")])),
                ("windows", .array([rule("M", "app", "MM")])),
                ("trees", obj([("main", obj([("window", .string("M"))]))])),
            ])),
        ])),
    ])),
])

// L2_JSON 去掉 `home.default`，對應 tests/test_workmode.sh:214 的 NO_DEFAULT_JSON。
