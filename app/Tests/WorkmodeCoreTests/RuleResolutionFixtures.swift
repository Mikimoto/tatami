import WorkmodeCore
import WorkmodeDomain

// RuleResolutionTests 的 fixture。windowDetail 是外移時改的名：MeasurementsTests
// 與 SaveLayoutTests 各有一個不同形狀的 window，而 Swift 的 private 頂層宣告會與
// internal 的同名宣告直接衝突。

/// `yabai -m query --windows` 的最小形狀：只有 `.app` 與 `.id`。
func windowList(_ pairs: [(app: String, id: String)]) -> JSONValue {
    .array(pairs.map {
        .object([JSONMember(key: "app", value: .string($0.app)),
                 JSONMember(key: "id", value: .number($0.id))])
    })
}

/// frame 的四個值傳的是**字面值**，因為 jq 1.8 逐字保留沒被運算過的數字，
/// 而用到這個 fixture 的斷言要驗的正是那些形狀（`2.50` 不可以變成 `2.5`）。
struct Frame {
    let width: String
    let height: String
    let originX: String
    let originY: String
}

/// `yabai -m query --windows --windowDetail <id>` 的形狀。
func windowDetail(id: JSONValue, display: JSONValue, space: JSONValue,
                  frame: Frame) -> JSONValue
{
    .object([
        JSONMember(key: "id", value: id),
        JSONMember(key: "display", value: display),
        JSONMember(key: "space", value: space),
        JSONMember(key: "frame", value: .object([
            JSONMember(key: "w", value: .number(frame.width)),
            JSONMember(key: "h", value: .number(frame.height)),
            JSONMember(key: "x", value: .number(frame.originX)),
            JSONMember(key: "y", value: .number(frame.originY)),
        ])),
    ])
}

/// Safari 分頁 dump：`<window_id>\t<url>\t<title>`。
let dump = """
7\thttps://a.example/\tAlpha
8\thttps://b.example/\tBeta
9\thttps://a.example/\tAlpha
"""
