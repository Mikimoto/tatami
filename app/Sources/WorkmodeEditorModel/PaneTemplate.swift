import WorkmodeDomain

/// 一鍵版面。作用在一個螢幕角色的**整棵樹**（`PanePath.slots` 為空），
/// 不是選到的那一格。
///
/// **不做鏡像版**（右一左二、下一上二）：⌥ 點分割線本來就會翻方向
/// （`TreeEdit.flippingAxis`），多四顆按鈕換不到新的形狀。
public enum PaneTemplate: String, CaseIterable, Sendable {
    case split2Vertical
    case split2Horizontal
    case grid4
    case oneLeftTwoRight

    /// 按鈕上的字，也會出現在兩句 notice 裡。
    public var title: String {
        switch self {
        case .split2Vertical: "左右二分"
        case .split2Horizontal: "上下二分"
        case .grid4: "田字"
        case .oneLeftTwoRight: "左一右二"
        }
    }

    /// 放得下幾個視窗。**從骨架數出來**，兩者不會漂移——手寫一份數字的話，
    /// 改了骨架而忘了改數字的症狀是「說放得下 4 個，實際上第 4 個被丟掉」。
    public var slotCount: Int {
        skeleton.slotCount
    }

    /// 這個模板的形狀。
    ///
    /// **`vertical` 是左右分、`horizontal` 是上下分**（`LayoutTree.swift:6`，
    /// 與 yabai 的 `split_type` 同義）。搞反的話整個版面轉九十度，而它看起來
    /// 完全像一個正常的畫面。
    var skeleton: Skeleton {
        switch self {
        case .split2Vertical:
            .split(axis: "vertical", first: .slot, second: .slot)
        case .split2Horizontal:
            .split(axis: "horizontal", first: .slot, second: .slot)
        case .grid4:
            // 外層上下分兩排，每排各自左右分。
            .split(axis: "horizontal",
                   first: .split(axis: "vertical", first: .slot, second: .slot),
                   second: .split(axis: "vertical", first: .slot, second: .slot))
        case .oneLeftTwoRight:
            .split(axis: "vertical",
                   first: .slot,
                   second: .split(axis: "horizontal", first: .slot, second: .slot))
        }
    }
}

/// 模板的形狀。`indirect` 是必要的——`split` 的 payload 含自己
/// （與 `PaneNode` 同一個理由）。
indirect enum Skeleton {
    case slot
    case split(axis: String, first: Skeleton, second: Skeleton)

    var slotCount: Int {
        switch self {
        case .slot: 1
        case let .split(_, first, second): first.slotCount + second.slotCount
        }
    }

    /// 從佇列前端依序取節點填進去。取完之後剩下的格子是空物件 `{}`。
    ///
    /// **求值順序是語意的一部分**：`first` 必須先從佇列拿。寫成
    /// `.array([second.filled(…), first.filled(…)])` 的話，Swift 由左而右求值，
    /// 於是右邊那半先拿到第一個視窗——結果仍然是一棵合法的樹，只是每個視窗都
    /// 站錯位置，而畫面上看起來完全正常。
    func filled(from queue: inout ArraySlice<JSONValue>) -> JSONValue {
        switch self {
        case .slot:
            return queue.popFirst() ?? .object([])
        case let .split(axis, first, second):
            let filledFirst = first.filled(from: &queue)
            let filledSecond = second.filled(from: &queue)
            return .object([
                JSONMember(key: "axis", value: .string(axis)),
                JSONMember(key: "children", value: .array([filledFirst, filledSecond])),
            ])
        }
    }
}
