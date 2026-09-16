import WorkmodeDomain
import WorkmodeEditorModel
import WorkmodeWire

/// 刻意做出鑑別力：
/// - `main` 的第一個 child 是**帶 ratio 的葉**、第二個是**內部分割**
///   → C1 的可拖與不可拖兩邊都到得了。
/// - 葉上有一個 `note` 自訂鍵 → 定點編輯有沒有保住不認得的鍵看得出來。
/// - `ratio` 寫成 `0.750` → 字面值有沒有被重印看得出來（`0.75` 就是重印了）。
/// - 樹裡引用**數字 label `7`** → C3 的字串／數字之分看得出來。
/// - `second` 有 display 但沒有 tree → 「拖到空的一格」到得了。
/// - `third` 的**第一個 child 是分割節點** → C1 的「這條線存不住 ratio」到得了；
///   它同時沒有 display，所以 `canvasRoles` 的第二段也到得了。
///
/// 樹住在 `spaceTrees.<角色>.S-1`（2026-08-30 之前是 `trees.<角色>`）：編輯器只編
/// 那一半，`trees` 是 `workmode` 那條路徑套的、編輯器碰不到的。
/// **`trees` 仍然留一份**——`LayoutValidator` 對缺它的 profile 報「缺 trees」，
/// 而 `theResultStillValidates` 那條要求整份檔過得了 ⌘S 的第一道閘門。
/// - `會議` 自己有 `windows` → C4 的取代語意看得出來。
let fixtureText = """
{
  "windows": [
    { "label": "甲", "match": ["app", "Ghostty"] },
    { "label": 7, "match": ["app", "Zed"] }
  ],
  "office": {
    "desc": "辦公室",
    "displays": { "main": "UUID-1", "second": "UUID-2" },
    "windows": [ { "label": "乙", "match": ["app", "Mail"] } ],
    "profiles": {
      "開發": {
        "trees": { "main": { "window": "甲" } },
        "spaceTrees": {
          "main": {
            "S-1": {
              "axis": "vertical",
              "children": [
                { "window": "甲", "ratio": 0.750, "note": "自訂鍵" },
                { "axis": "horizontal",
                  "children": [ { "window": 7 }, { "window": "乙" } ] }
              ]
            }
          },
          "third": {
            "S-1": {
              "axis": "vertical",
              "children": [
                { "axis": "horizontal",
                  "children": [ { "window": "甲" }, { "window": "乙" } ] },
                { "window": 7 }
              ]
            }
          }
        }
      },
      "會議": {
        "windows": [ { "label": "丙", "match": ["app", "Zoom"] } ],
        "trees": {},
        "spaceTrees": {}
      }
    }
  }
}
"""

func fixtureDocument() throws -> LayoutDocument {
    try LayoutDocument(root: JSONParser.parse(fixtureText))
}

/// 斷言比的是**整份重新序列化的文字**，不是計數。計數擋不住「保持大小不變」的突變
/// ——phase 2a 四個錯誤預測裡最陰險的那一種。
func text(of document: LayoutDocument) -> String {
    JSONWriter.format(document.root)
}

/// 第二份：`axis` 是認不得的值。這一份**故意過不了 validate**，所以不能併進上面那份
/// （`theResultStillValidates` 會跟著紅）。只有翻軸向那組測試用它。
///
/// 兩個 leaf 的 label 都是「甲」，重複的是 **label 不是樹的節點**——validate 只查
/// 樹引用的 label 在不在生效清單裡，不查同一個 label 有沒有被畫兩次(實測)。
let brokenAxisText = #"""
{
  "windows": [ { "label": "甲", "match": ["app", "Ghostty"] } ],
  "office": {
    "desc": "辦公室",
    "displays": { "main": "UUID-1" },
    "profiles": {
      "開發": {
        "spaceTrees": {
          "main": { "S-1": { "axis": "diagonal",
                             "children": [ { "window": "甲" }, { "window": "甲" } ] } }
        }
      }
    }
  }
}
"""#

func brokenAxisDocument() throws -> LayoutDocument {
    try LayoutDocument(root: JSONParser.parse(brokenAxisText))
}
