import SwiftUI
import WorkmodeDomain
import WorkmodeEditorControl
import WorkmodeEditorModel

/// 一棵樹。
///
/// `axis == "vertical"` 畫成左右分，不是上下分——`LayoutTree.swift:6` 明文
/// 「vertical 是左右分，horizontal 是上下分，與 yabai 的 split_type 同義」，
/// 而 `RectTree.swift:37-42` 是在 x/w 切得開時才選 vertical。搞反的話整個畫布
/// 會轉九十度，而它看起來完全像一個正常的畫面。
struct PaneView: View {
    let controller: EditorController
    let document: LayoutDocument
    let labels: [LabelChoice]
    let roleIndex: Int
    /// 這個角色的第幾個分頁。**與 `path.space` 是同一件事的兩種表示**：`path` 送給
    /// 編輯動作（它要名字），`tabIndex` 送進拖放的酬載（它只吃整數）。兩者由
    /// `CanvasView` 同時算出來，錯開的下場是「拖出來的窗格刪到另一個版面」。
    let tabIndex: Int
    /// **`node` 留著不換成「從 `path` 現算」**：phase 1 的遞迴是父節點把 `first`／
    /// `second` 拆好往下傳，換成每一層自己去 `document.node(at:)` 會讓同一份資料被
    /// 走兩遍，而兩遍之間沒有任何東西保證一致。`path` 是新加的，只用來送意圖。
    let node: PaneNode
    let path: PanePath
    /// 現在選到哪一格。`PanePath` 自己帶角色與分頁，所以點另一個角色會自然覆蓋
    /// ——要主動清成 nil 的只有「刪完」與「切分頁」。
    @Binding var selected: PanePath?

    var body: some View {
        switch node {
        case let .window(label, ratio):
            // 順便把 ratio 的字面值畫出來：痛點之一就是「我到底設了什麼從 JSON 看不
            // 出來」，而 ratio 是最看不出來的那個。
            dropTarget(
                VStack(spacing: 2) {
                    Text(label)
                    if let ratio {
                        Text(ratio).font(.caption2).foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.secondary.opacity(0.12))
                .overlay(RoundedRectangle(cornerRadius: 4)
                    .stroke(selected == path ? Color.accentColor : Color.secondary.opacity(0.4),
                            lineWidth: selected == path ? 2 : 1))
                .onTapGesture { selected = path }
                .contextMenu {
                    Button("移除這個視窗", role: .destructive) { remove() }
                }
                // **`.onDrag` 而不是 `.draggable`**：預覽要即時座標，那只有 `DropDelegate`
                // 給得到（`.dropDestination` 的 `isTargeted` 只有 Bool），而它走的是
                // `NSItemProvider` 這條舊路徑，來源端要配套。
                .onDrag {
                    NSItemProvider(object: DragPayload.pane(roleIndex: roleIndex,
                                                            tabIndex: tabIndex,
                                                            slots: path.slots).text as NSString)
                }
            )
        case .empty:
            dropTarget(
                Text("未指定")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .overlay(RoundedRectangle(cornerRadius: 4)
                        .stroke(style: StrokeStyle(lineWidth: selected == path ? 2 : 1,
                                                   dash: [4]))
                        .foregroundStyle(selected == path ? Color.accentColor : Color.secondary))
                    .onTapGesture { selected = path }
                    // 空格刪掉＝取消它所在的那個分割（兄弟頂上來），所以措辭
                    // 與葉子那顆不同——講「視窗」會讓人以為它會刪掉別的東西。
                    .contextMenu {
                        // 整棵樹不存在的那一種「未指定」沒有東西可刪，
                        // 給一個按下去什麼都不會發生的選項與「壞了」分不出來。
                        if document.canDeletePane(at: path) {
                            Button("移除這一格", role: .destructive) { remove() }
                        }
                    }
            )
        case let .split(axis, first, second):
            let stored = Self.dividerFraction(of: first)
            let fraction = dragging ?? stored
            let draggable = document.canSetRatio(at: path)
            GeometryReader { geometry in
                let horizontal = axis == "vertical"
                let span = horizontal ? geometry.size.width : geometry.size.height
                ZStack(alignment: .topLeading) {
                    if horizontal {
                        HStack(spacing: 2) {
                            child(first, 0).frame(width: max(0, span * fraction - 1))
                            child(second, 1)
                        }
                    } else {
                        VStack(spacing: 2) {
                            child(first, 0).frame(height: max(0, span * fraction - 1))
                            child(second, 1)
                        }
                    }
                    handle(span: span, fraction: fraction, horizontal: horizontal,
                           draggable: draggable, geometry: geometry)
                }
            }
        }
    }

    /// 遞迴。`slot` 同時決定 `PanePath`(送意圖用)與投影出來的節點(畫圖用),
    /// 兩者由同一個參數決定，錯開了編不過。
    private func child(_ node: PaneNode, _ slot: Int) -> PaneView {
        PaneView(controller: controller, document: document, labels: labels,
                 roleIndex: roleIndex, tabIndex: tabIndex,
                 node: node, path: path.child(slot),
                 selected: $selected)
    }

    /// 拖的時候只動 `dragging` 這個本地狀態，放手才寫檔——與 `RuleTableView` 的
    /// 本地緩衝同一條理由：每個位移都寫進去的話，拖一次就是幾十步 undo，50 步的歷史
    /// 一次拖曳就滿了。
    @State private var dragging: Double?

    /// 這一格現在要亮哪一區。每一格各自一份——同時只有一格會有游標在上面。
    @State private var preview: DropZone?

    /// 右鍵與畫布那顆按鈕走同一個動作。刪完清掉選取——`selected` 是 view 的狀態、
    /// 不跟著文件變，留著失效的路徑會讓下一次刪除打在別的節點上。
    private func remove() {
        controller.apply { $0.deletingPane(at: path) }
        selected = nil
    }

    /// 存不住 ratio 的分割線畫成不可拖並寫出理由(C1)。**不畫成可拖但沒反應**:
    /// 那與「壞了」在畫面上分不出來。⌥ 點的 gesture 兩種情況都留著——翻方向不需要
    /// ratio,而那正是把一條存不住比例的線變成存得住的方法之一。
    @ViewBuilder private func handle(span: Double, fraction: Double, horizontal: Bool,
                                     draggable: Bool, geometry: GeometryProxy) -> some View
    {
        let offset = max(0, span * fraction - 3)
        let bar = Rectangle()
            .fill(draggable ? Color.accentColor.opacity(dragging == nil ? 0.25 : 0.6)
                : Color.secondary.opacity(0.15))
            .frame(width: horizontal ? 6 : geometry.size.width,
                   height: horizontal ? geometry.size.height : 6)
        ZStack(alignment: horizontal ? .top : .leading) {
            if draggable {
                bar.gesture(dragGesture(span: span, horizontal: horizontal))
            } else {
                bar
            }
            if let dragging, let literal = RectTree.ratioLiteral(dragging) {
                Text(literal)
                    .font(.caption2)
                    .padding(2)
                    .background(.thickMaterial)
                    // **只偏 8pt，不再加 `offset`。** 外層 ZStack 已經位移過 `offset`，
                    // 而位移是疊加的——寫成 `offset + 8` 的話數字落在 `2 * offset + 8`，
                    // 一格高 220pt、比例 0.5 時算出來是 222pt，整個掉到窗格外面看不見。
                    .offset(x: horizontal ? 8 : 0, y: horizontal ? 0 : 8)
            }
        }
        .offset(x: horizontal ? offset : 0, y: horizontal ? 0 : offset)
        .help(draggable
            ? "拖曳改比例，⌥ 點一下翻方向"
            : "這條線存不住比例：ratio 只能掛在葉上，而這一側是分割節點")
        .gesture(TapGesture().modifiers(.option).onEnded {
            controller.apply { $0.flippingAxis(at: path) }
        })
    }

    private func dragGesture(span: Double, horizontal: Bool) -> some Gesture {
        DragGesture(coordinateSpace: .local)
            .onChanged { value in
                guard span > 0 else { return }
                let raw = (horizontal ? value.location.x : value.location.y) / span
                dragging = min(max(raw, 0.05), 0.95)
            }
            .onEnded { _ in
                if let fraction = dragging {
                    controller.apply { $0.settingRatio(at: path, to: fraction) }
                }
                dragging = nil
            }
    }

    /// 分割線的位置。ratio 掛在**葉**上（`LayoutTree.swift:4-5`），而第一個 child 的
    /// 那一個就是分割線——`RectTree.swift:79` 蓋上去的是 lowSpan/total。第一個 child
    /// 自己是分割時沒有 ratio（`stamp:95` 只碰含 `window` 的節點），那就均分。
    ///
    /// 看不懂的字面值回 0.5，超出範圍的夾到邊界而不是回 0.5：0.99 畫成 0.95 比畫成
    /// 均分更接近事實。夾的另一個理由是畫布不能因為使用者打錯字就算出負的寬度。
    private static func dividerFraction(of first: PaneNode) -> Double {
        guard case let .window(_, literal) = first,
              let value = literal.flatMap(Double.init), value.isFinite
        else { return 0.5 }
        return min(max(value, 0.05), 0.95)
    }

    /// 葉與「未指定」都收放下，也都可以被拖走。分割節點自己不收——它的面積整個
    /// 被 children 蓋住，收不到任何事件（`placing` 的 `.center` 對分割節點回原文件
    /// 那條因此在 UI 到不了，與 `canInsertRule` 的 false 分支同一個處境）。
    ///
    /// **`GeometryReader` 沒有 intrinsic size**，直接包在既有 view 外面會改變版面
    /// （它自己吃掉全部可用空間、把 content 貼到左上角），所以 content 必須明確填滿。
    /// `DropInfo.location` 是**被修飾的那個 view 自己的座標空間**，除以
    /// `geometry.size` 就是 0…1。
    private func dropTarget(_ content: some View) -> some View {
        GeometryReader { geometry in
            content
                .frame(width: geometry.size.width, height: geometry.size.height)
                .overlay(alignment: .topLeading) { highlight(in: geometry.size) }
                .onDrop(of: [.text], delegate: PaneDropDelegate(
                    size: geometry.size,
                    labels: labels,
                    onPlace: { choice, zone in
                        controller.apply { $0.placing(choice, at: path, zone: zone) }
                    },
                    preview: $preview
                ))
        }
    }

    /// 會落在哪裡。比例由 `DropZone.previewFraction` 算，這裡只負責乘上尺寸
    /// ——判斷寫在這一層就沒有東西驗它（`WorkmodeEditorUI` 零測試）。
    ///
    /// `allowsHitTesting(false)` 是必要的：色塊蓋在整格上面，會吃掉 drop 事件，
    /// 而那會讓 `dropUpdated` 從此收不到座標——預覽亮一次之後就凍在那裡。
    @ViewBuilder private func highlight(in size: CGSize) -> some View {
        if let preview {
            let box = preview.previewFraction
            RoundedRectangle(cornerRadius: 4)
                .fill(Color.accentColor.opacity(0.35))
                .frame(width: size.width * box.width, height: size.height * box.height)
                .offset(x: size.width * box.originX, y: size.height * box.originY)
                .allowsHitTesting(false)
        }
    }
}
