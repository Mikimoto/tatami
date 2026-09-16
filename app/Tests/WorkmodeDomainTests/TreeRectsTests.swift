import Testing
import WorkmodeDomain

// 樹 → 矩形。這是 RectTree.fromRects（矩形 → 樹）的反向，兩支互為 round-trip。
// 每條的鑑別值寫在註解：那是「錯的實作會算出什麼」。

private let screen = Rect(originX: 0, originY: 0, width: 1000, height: 500)

@Test func aLeafFillsTheWholeRect() throws {
    let leaves = try TreeRects.leaves(of: leaf(.string("A")), in: screen)
    #expect(leaves == [TreeRects.Leaf(window: .string("A"), rect: screen)])
}

/// 沒有 ratio 就均分。鑑別值：500／500——拿 0 或 1000 當預設都會錯。
@Test func aSplitWithoutRatiosHalves() throws {
    let tree = obj([("axis", .string("vertical")),
                    ("children", .array([leaf(.string("A")), leaf(.string("B"))]))])
    let leaves = try TreeRects.leaves(of: tree, in: screen)
    #expect(leaves.map(\.rect) == [
        Rect(originX: 0, originY: 0, width: 500, height: 500),
        Rect(originX: 500, originY: 0, width: 500, height: 500),
    ])
}

/// 第一個葉的 ratio 決定分割線。鑑別值：750，不是 500（忽略 ratio）也不是 250（用錯邊）。
@Test func theFirstLeafRatioPlacesTheDivider() throws {
    let tree = obj([("axis", .string("vertical")),
                    ("children", .array([leaf(.string("A"), "0.75"), leaf(.string("B"), "0.25")]))])
    let leaves = try TreeRects.leaves(of: tree, in: screen)
    #expect(leaves.map(\.rect.width) == [750, 250])
    #expect(leaves.map(\.rect.originX) == [0, 750])
}

/// 第一個 child 是分割（沒有 ratio）時用第二個葉的 ratio 反推。鑑別值：外層 700／300。
@Test func aSplitFirstChildUsesTheSecondLeafRatio() throws {
    let inner = obj([("axis", .string("horizontal")),
                     ("children", .array([leaf(.string("A")), leaf(.string("B"))]))])
    let tree = obj([("axis", .string("vertical")),
                    ("children", .array([inner, leaf(.string("C"), "0.3")]))])
    let leaves = try TreeRects.leaves(of: tree, in: screen)
    #expect(leaves.map(\.window) == [.string("A"), .string("B"), .string("C")])
    #expect(leaves.map(\.rect) == [
        Rect(originX: 0, originY: 0, width: 700, height: 250),
        Rect(originX: 0, originY: 250, width: 700, height: 250),
        Rect(originX: 700, originY: 0, width: 300, height: 500),
    ])
}

/// 第二塊的尺寸必須是**父減掉第一塊**，不是 `父 × (1 - share)`。
///
/// 鑑別值只有 0.3 給得出來：`1000 * (1 - 0.7)` 是 300.00000000000006 而
/// `1000 - 700` 是 300.0；0.75／0.25／0.5 在兩種實作下都給整數，分不出來。
///
/// **這條原本寫成「兩塊寬度加起來等於父的寬」，而那個斷言沒有牙齒**：1000 附近
/// double 的 ULP 是 1.14e-13，那個 6e-14 的誤差在加法裡被吸收掉，`700 +
/// 300.00000000000006` 就是 1000.0（實測），右緣那個斷言同理。所以要問的不是
/// 「加起來對不對」而是「第二塊的值本身對不對」。
@Test func theSecondChildIsTheParentMinusTheFirst() throws {
    let tree = obj([("axis", .string("vertical")),
                    ("children", .array([leaf(.string("A")), leaf(.string("B"), "0.3")]))])
    let leaves = try TreeRects.leaves(of: tree, in: screen)
    #expect(leaves[1].rect.width == screen.width - leaves[0].rect.width)
}

/// horizontal 沿 y 切。鑑別值：兩個矩形的 originY 是 0／250 而 originX 都是 0
/// ——軸弄反的實作會給 originX 0／500。
@Test func horizontalSplitsAlongY() throws {
    let tree = obj([("axis", .string("horizontal")),
                    ("children", .array([leaf(.string("A")), leaf(.string("B"))]))])
    let leaves = try TreeRects.leaves(of: tree, in: screen)
    #expect(leaves.map(\.rect.originY) == [0, 250])
    #expect(leaves.map(\.rect.originX) == [0, 0])
}

/// 與 RectTree 的 round-trip：樹 → 矩形 → 樹要等於原樹（ratio 取兩位小數，
/// fixture 選 0.75／0.25 所以沒有捨入誤差）。
@Test func leavesFeedBackIntoRectTree() throws {
    let tree = obj([("axis", .string("vertical")),
                    ("children", .array([leaf(.string("A"), "0.75"), leaf(.string("B"), "0.25")]))])
    let leaves = try TreeRects.leaves(of: tree, in: screen)
    let rects = JSONValue.array(leaves.map { item in
        rect(item.window, "\(Int(item.rect.originX))", "\(Int(item.rect.originY))",
             "\(Int(item.rect.width))", "\(Int(item.rect.height))")
    })
    #expect(try RectTree.fromRects(rects) == tree)
}

@Test func aNodeWithNeitherWindowNorAxisIsMalformed() {
    #expect(throws: TreeRects.Failure.malformed) {
        try TreeRects.leaves(of: obj([]), in: screen)
    }
}
