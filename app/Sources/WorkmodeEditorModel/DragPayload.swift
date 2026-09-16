/// 一次拖放帶的東西。**只有整數**：角色用畫布的來源索引而不是名字，
/// 名字是 JSON 的鍵、內容任意，塞進字串就得處理跳脫。
///
/// `Int(_:)` 對 `"01"`、`" 1"`、`"+1"` 的行為不是每個人都記得，所以
/// `garbageIsRefused` 逐項釘住；解不出來一律 nil，UI 據此整個忽略那次放下。
///
/// **`tabIndex` 是 phase 3b 加的，而它非有不可**：同一個角色現在有好幾棵樹
/// （「目前可見」加上每個具名 space 一棵）。少了它，從 space 分頁拖出來的窗格
/// 會被當成「目前可見」那棵樹的窗格刪掉——**刪的是另一個版面**，而畫面上零訊號。
public enum DragPayload: Equatable, Sendable {
    case label(Int)
    case pane(roleIndex: Int, tabIndex: Int, slots: [Int])

    public var text: String {
        switch self {
        case let .label(index): "L:\(index)"
        case let .pane(roleIndex, tabIndex, slots):
            "P:\(roleIndex):\(tabIndex):" + slots.map(String.init).joined(separator: ",")
        }
    }

    public init?(text: String) {
        let parts = text.split(separator: ":", omittingEmptySubsequences: false)
        switch (parts.first, parts.count) {
        case ("L", 2):
            guard let index = Int(parts[1]), index >= 0 else { return nil }
            self = .label(index)
        case ("P", 4):
            guard let roleIndex = Int(parts[1]), roleIndex >= 0,
                  let tabIndex = Int(parts[2]), tabIndex >= 0 else { return nil }
            let raw = parts[3]
            let slots: [Int]
            if raw.isEmpty {
                slots = []
            } else {
                let parsed = raw.split(separator: ",", omittingEmptySubsequences: false)
                    .map { Int($0) }
                guard parsed.allSatisfy({ $0 == 0 || $0 == 1 }) else { return nil }
                slots = parsed.compactMap(\.self)
            }
            self = .pane(roleIndex: roleIndex, tabIndex: tabIndex, slots: slots)
        default:
            return nil
        }
    }
}
