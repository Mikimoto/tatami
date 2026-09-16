import WorkmodeDomain
import WorkmodeEditorModel
import WorkmodeWire

/// 掃除專用的 fixture。**不共用 `TreeEditFixture`**：那份被 `TreeEditTests` 用
/// 索引取 palette（`paletteLabels(...)[2]`），往 `windows` 加一條就會讓那些索引錯位。
///
/// 每個元素都是為了鑑別力放進去的：
/// - 共用層三條、`office` 地點層一條、`office/會議` **自己有 `windows`**
///   → 三種 scope 的刪除都到得了，而取代語意（會議不受共用層影響）看得出來。
/// - `office/會議` 自己那份 `windows` 裡**也有一條「共用甲」**，樹裡也用了它
///   → `profilesLosing` 的**後半**（「編輯後還生效嗎」）才有輸入踩得到。
///     少了這一項，前半的 `had` 自己就把 `會議` 排除掉了，於是把
///     `if had, !has` 改成 `if had` 是**全綠**的（2026-08-26 實測）。
/// - 共用層有一條 **`"label": 7`（數字）** 而樹裡也寫數字 `7`
///   → 改名時「用 jq `==` 找舊值、用字串寫新值」兩件事都看得出來。
/// - `office/開發.trees.main` 是 `[帶 ratio 與 note 的葉, 內部分割]`
///   → 塌一層時「父節點的鍵一起丟」與「沒被碰到的兄弟原樣保留」兩邊都到得了；
///     `ratio` 寫成 `0.750` 讓字面值有沒有被重印看得出來。
/// - `office/開發.trees.second` 是**單一根葉**
///   → 「整棵被掃空 → 刪掉那個鍵」到得了。
/// - `只在分頁` 這條規則**只**被 `spaceTrees` 引用，`trees` 裡一次都沒有
///   → 少掃 `spaceTrees` 的實作會露餡。少了這一項，掃 `trees` 那半就足以讓測試全綠。
/// - 有第二個地點 `home`
///   → 「只掃受影響的 profile」與「全檔掃同名 label」分得出來。
///
/// **已實測**（2026-08-26）：`workmode validate` 對這份輸入 rc=0 且零輸出。
///
/// 整份共有 **8** 個窗格：`office/開發` 的 main 三個、second 一個、分頁一個；
/// `office/會議` 兩個；`home/開發` 一個。
let sweepFixtureText = """
{
  "windows": [
    { "label": "共用甲", "match": ["app", "Ghostty"] },
    { "label": 7, "match": ["app", "Zed"] },
    { "label": "只在分頁", "match": ["app", "Notes"] }
  ],
  "office": {
    "desc": "辦公室",
    "displays": { "main": "UUID-1", "second": "UUID-2" },
    "windows": [ { "label": "地點乙", "match": ["app", "Mail"] } ],
    "profiles": {
      "開發": {
        "trees": {
          "main": {
            "axis": "vertical",
            "children": [
              { "window": "共用甲", "ratio": 0.750, "note": "自訂鍵" },
              { "axis": "horizontal",
                "children": [ { "window": 7 }, { "window": "地點乙" } ] }
            ]
          },
          "second": { "window": "地點乙" }
        },
        "spaceTrees": {
          "second": { "SPACE-1": { "window": "只在分頁" } }
        }
      },
      "會議": {
        "windows": [
          { "label": "專屬丙", "match": ["app", "Zoom"] },
          { "label": "共用甲", "match": ["app", "會議用"] }
        ],
        "trees": {
          "main": {
            "axis": "vertical",
            "children": [ { "window": "專屬丙" }, { "window": "共用甲" } ]
          }
        }
      }
    }
  },
  "home": {
    "desc": "家裡",
    "displays": { "main": "UUID-3" },
    "profiles": {
      "開發": { "trees": { "main": { "window": "共用甲" } } }
    }
  }
}
"""

func sweepDocument() throws -> LayoutDocument {
    try LayoutDocument(root: JSONParser.parse(sweepFixtureText))
}

/// 整份重新序列化的文字。斷言比它而不是比計數——計數擋不住「保持大小不變」的突變。
func sweepText(of document: LayoutDocument) -> String {
    JSONWriter.format(document.root)
}

/// 某一棵樹的節點。`space` 是 nil 就是 `trees.<角色>`。
func sweepNode(_ document: LayoutDocument, location: String = "office",
               profile: String = "開發", role: String, space: String? = nil,
               slots: [Int] = []) -> JSONValue?
{
    JSONPath.get(document.root,
                 SweptPane(location: location, profile: profile, role: role,
                           space: space, slots: slots).steps)
}

/// 整份文件裡每一個 `{"window": …}` 的值，`trees` 與 `spaceTrees` 都算。
///
/// **不能用刪前的 slot 路徑去驗「它不見了」。** 塌一層之後同一條路徑會解到活下來的
/// 那個兄弟——實測（2026-08-26）：`office/開發` 的 `main` slots `[0]` 是「共用甲」，
/// 刪掉它之後 `main` 塌成內層那個分割，同一條路徑解到 `{"window": 7}`，非 nil。
/// 要問的不是「那個位置空了嗎」而是「還有沒有人引用它」。
///
/// `location` 與 `profile` 給了就只看那一個。掃除是**按 profile** 精準做的，
/// 所以「這個 label 不見了」只在受影響的那些 profile 裡成立——自己有 `windows`
/// 的 profile 會留著它自己那一份，那是對的（`aProfileWithItsOwnWindowsIsNotSwept`）。
func sweepWindowValues(_ document: LayoutDocument,
                       location: String? = nil,
                       profile: String? = nil) -> [JSONValue]
{
    var out: [JSONValue] = []
    func walk(_ node: JSONValue) {
        guard case let .object(members) = node else { return }
        if let window = members.first(where: { $0.key == "window" })?.value {
            out.append(window)
        }
        if case let .array(children)? =
            members.first(where: { $0.key == "children" })?.value
        {
            children.forEach(walk)
        }
    }
    for loc in document.locations where location == nil || location == loc {
        for prof in document.profiles(in: loc) where profile == nil || profile == prof {
            let base = document.root[loc]?["profiles"]?[prof]
            if case let .object(trees)? = base?["trees"] {
                trees.forEach { walk($0.value) }
            }
            if case let .object(roles)? = base?["spaceTrees"] {
                for role in roles {
                    if case let .object(spaces) = role.value {
                        spaces.forEach { walk($0.value) }
                    }
                }
            }
        }
    }
    return out
}

/// 樹裡同時有**數字 `7`** 與**字串 `"7"`** 兩個窗格，而規則只有數字那一條。
///
/// 這份文件**刻意過不了 validate**（`{"window": "7"}` 不在生效清單裡），所以不能併進
/// 上面那份。它存在的理由是 `labelEquals` 那道判準：把它換成
/// `JQPrint.interpolate(a) == JQPrint.interpolate(b)`，這兩個窗格會被當成同一個
/// ——而在上面那份 fixture 上那個突變是**全綠**的（2026-08-26 實測），因為那裡沒有
/// 任何一對「印起來相同、jq `==` 不同」的值。
///
/// 編輯器本來就會在不合法的文件上工作（那正是 ⌘S 那道閘門存在的理由），
/// 所以這不是虛構的輸入。
let numericLabelFixtureText = """
{
  "windows": [ { "label": 7, "match": ["app", "Zed"] } ],
  "home": {
    "desc": "家",
    "displays": { "main": "UUID-1" },
    "profiles": {
      "開發": {
        "trees": {
          "main": {
            "axis": "vertical",
            "children": [ { "window": 7 }, { "window": "7" } ]
          }
        }
      }
    }
  }
}
"""

func numericLabelDocument() throws -> LayoutDocument {
    try LayoutDocument(root: JSONParser.parse(numericLabelFixtureText))
}
