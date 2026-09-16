import WorkmodeDomain
import WorkmodeEditorModel
import WorkmodeWire

/// 刻意做出鑑別力：
/// - **兩個**地點 → 「拒絕刪掉最後一個地點」到得了（刪 home 後再刪 office）。
/// - `office` 有**兩個** profile ＋ 一個 `default` → 改名要順手改 `default`、
///   刪 `default` 指著的那個要被拒，兩條都到得了。
/// - `home` 只有**一個** profile → 「拒絕刪掉最後一個 profile」到得了。
/// - `office.displays` 有 `main` 與 `second` → 刪 `second` 可以、刪 `main` 要被拒。
/// - 鍵序是 `desc, default, displays, profiles`，而 `開發` 排在 `會議` **前面**
///   → 改名有沒有保住位置看得出來（接到尾端的實作在這裡紅）。
let settingsText = #"""
{
  "windows": [ { "label": "甲", "match": ["app", "Ghostty"] } ],
  "office": {
    "desc": "辦公室",
    "default": "開發",
    "displays": { "main": "UUID-1", "second": "UUID-2" },
    "profiles": {
      "開發": { "trees": { "main": { "window": "甲" } } },
      "會議": { "trees": {} }
    }
  },
  "home": {
    "desc": "家",
    "displays": { "main": "UUID-3" },
    "profiles": { "唯一": { "trees": {} } }
  }
}
"""#

func settingsDocument() throws -> LayoutDocument {
    try LayoutDocument(root: JSONParser.parse(settingsText))
}

/// 斷言比的是**整份重新序列化的文字**，不是計數——計數擋不住「保持大小不變」的突變。
func settingsText(of document: LayoutDocument) -> String {
    JSONWriter.format(document.root)
}
