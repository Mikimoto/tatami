import SwiftUI
import WorkmodeDomain
import WorkmodeEditorControl
import WorkmodeEditorModel

/// **角色名不能當 id**，與 `RuleTableView` 的 `IndexedRule` 同一條。JSON parser
/// 不去重（實測 `workmode fmt` 對 `{"a":{"main":"A","main":"B"}}` 兩筆都留），而
/// 重複的 `displays` 鍵 `__diff validate` 實測 rc=0 一聲不吭——所以同一個角色名
/// 真的會在 `canvasRoles` 出現兩次。SwiftUI 對重複的 id 不出聲，只會少畫，而少掉的
/// 那一格正是使用者開編輯器要修的東西。用來源順序的索引：天生唯一，順序也有意義。
private struct IndexedCanvasRole: Identifiable {
    let id: Int
    let canvasRole: CanvasRole
}

/// 一個 profile 在一個地點上的全部螢幕。
struct CanvasView: View {
    let controller: EditorController
    let document: LayoutDocument
    let location: String
    let profile: String

    /// 每個角色（用畫布索引當鍵）選到第幾個分頁。
    ///
    /// 住在 view 而不是 document：它是**看哪一頁**，不是設定的內容——寫進文件會讓
    /// 切個分頁就標 dirty、⌘S 也會把它寫進 `layout.json`。
    @State private var selectedTab: [Int: Int] = [:]

    /// 有沒有東西正拖在刪除區上方。只影響外觀。
    @State private var overDeleteZone = false

    /// 選到哪一格。住在 view 不住在文件，與 `selectedTab` 同一條理由。
    @State private var selected: PanePath?

    /// 角色 → 那台螢幕上的 space，**查一次記起來**。
    ///
    /// `spaceOptions()` 每次呼叫都 spawn 子行程（最多兩個：`--displays` 與 `--spaces`），
    /// 寫在 view body 的求值路徑上會讓每一步編輯與每一次 undo 都生一批 `yabai -m query`。
    /// 代價是拔插螢幕後要切走再切回來才會更新。
    ///
    /// **分角色存**：每個角色的螢幕不同，存一份全部的話別台螢幕的 space 也會變成
    /// 這個角色的分頁，而 `--space` 只套「這台螢幕現在可見的 space」，那些分頁
    /// 永遠不會生效（`SpaceChoice.merge` 的 `onDisplay:` 是同一條理由）。
    @State private var liveSpaces: [String: [LiveSpace]] = [:]

    private var indexed: [IndexedCanvasRole] {
        document.canvasRoles(location: location, profile: profile)
            .enumerated()
            .map { IndexedCanvasRole(id: $0.offset, canvasRole: $0.element) }
    }

    /// 可拖的 label。**列的是這個 profile 生效的那一份**（C4）：拿檔案裡全部的
    /// 來列，拖進去會存不了檔而畫面上兩個名字長得一模一樣。
    private var labels: [LabelChoice] {
        document.paletteLabels(location: location, profile: profile)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            palette
            ForEach(indexed) { item in
                let canvasRole = item.canvasRole
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(canvasRole.role).font(.caption).foregroundStyle(.secondary)
                        // 這個角色有 `spaceTrees` 但 `displays` 沒定義它，所以
                        // `workmode --space` 走到它時只會說一句「螢幕沒接上」然後跳過
                        // （`SpaceLayout` 的四個 `continue` 之一）。標出來的理由與畫它
                        // 同一個：`validate` 對它一聲不吭。
                        if !canvasRole.hasDisplay {
                            Text("displays 沒定義，套用時會跳過")
                                .font(.caption2)
                                .foregroundStyle(.orange)
                        }
                    }
                    SpaceTabBar(controller: controller, document: document,
                                location: location, profile: profile,
                                role: canvasRole.role,
                                live: liveSpaces[canvasRole.role] ?? [],
                                selected: binding(for: item.id, role: canvasRole.role))
                    PaneView(controller: controller, document: document, labels: labels,
                             roleIndex: item.id, tabIndex: tab(for: item.id, role: canvasRole.role),
                             node: document.tree(location: location, profile: profile,
                                                 role: canvasRole.role,
                                                 space: space(for: item.id, role: canvasRole.role)),
                             path: PanePath(location: location, profile: profile,
                                            role: canvasRole.role,
                                            space: space(for: item.id, role: canvasRole.role),
                                            slots: []),
                             selected: $selected)
                        // 220 而不是 140：分成四格時每格 110pt，上下的放置區各有
                        // 66pt。140 的時候上下區只剩 42pt，實際上瞄不準——那是
                        // 「看起來只能左右放」的一半成因。
                        .frame(height: 220)
                }
            }
            Spacer()
        }
        .padding()
        // 點畫布的空白處取消選取。`contentShape` 是必要的——`VStack` 的空白區域
        // 預設不接受點擊，沒有它只有文字本身收得到。子 view 自己的
        // `onTapGesture` 優先，所以點格子仍然是選取而不是取消。
        .contentShape(Rectangle())
        .onTapGesture { clearSelection() }
        // 查一次記起來。**`id` 要同時綁 profile**：下面那個迴圈走的是
        // `canvasRoles(location:profile:)`，而換 profile 會讓角色清單變——只綁
        // `location` 的話，新出現的角色在 `liveSpaces` 裡沒有 key，那一頁的分頁列
        // 就是空的，要切走再切回來才會有東西（2026-08-30 由批次 B 的實作者指出）。
        // 用陣列而不是字串串接：`"a" + "-" + "b"` 與 `"a-" + "b"` 撞得到。
        .task(id: [location, profile]) {
            var out: [String: [LiveSpace]] = [:]
            for canvasRole in document.canvasRoles(location: location, profile: profile) {
                out[canvasRole.role] = liveSpaces(for: canvasRole.role)
            }
            liveSpaces = out
        }
    }

    /// 這個角色那台螢幕上的 space。**不濾的話，別台螢幕的 space 也會變成分頁，
    /// 而 `--space` 只套「這台螢幕現在可見的 space」，那些分頁永遠不會生效**
    /// ——做得出一個靜默永遠不生效的設定（`SpaceChoice.merge` 的 `onDisplay:`
    /// 是同一條理由）。
    ///
    /// 走 `spaceOptions` 而不是另開一支「回全部 space」的入口：過濾必須發生，
    /// 而那一支已經在做（角色 → 螢幕 uuid → 現場的 display index → 濾）。
    private func liveSpaces(for role: String) -> [LiveSpace] {
        guard case let .ready(choices) = controller.spaceOptions(
            displayUUID: document.displayUUID(location: location, role: role),
            treed: document.spaceTreeNames(location: location, profile: profile, role: role)
        ) else { return [] }
        return choices.map { LiveSpace(uuid: $0.uuid, index: $0.index,
                                       display: $0.displayIndex, visible: $0.isVisible) }
    }

    /// 取消選取。**只有點背景這一條路**——鍵盤的 Esc 走 `.onKeyPress`，而那需要
    /// SwiftUI 的焦點，在這個環境拿不到（見 `removeButton` 的說明）。
    private func clearSelection() {
        selected = nil
    }

    /// 可拖的一排 label，同時是「拖窗格過來就刪掉」的落點——與 spec 的
    /// 「把 pane 拖回左邊清單 → 刪掉它」同一個動作。
    private var palette: some View {
        HStack(spacing: 6) {
            if labels.isEmpty {
                Text("這個 profile 沒有生效的視窗規則")
                    .font(.caption).foregroundStyle(.orange)
            }
            ForEach(Array(labels.enumerated()), id: \.offset) { index, choice in
                Text(choice.display)
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(Capsule().fill(Color.accentColor.opacity(0.15)))
                    .onDrag {
                        NSItemProvider(object: DragPayload.label(index).text as NSString)
                    }
            }
            Spacer()
            if overDeleteZone {
                Text("放開就從版面移除").font(.caption).foregroundStyle(.red)
            } else {
                removeButton
            }
        }
        .frame(minHeight: 28)
        // **`maxWidth` 一定要在 `dropDestination` 之前。** 沒有它的時候接收區只有
        // 那排膠囊的自然寬度，拖到右邊的空白處一律沒反應——那就是使用者回報的
        // 「拖拉都沒變化」。
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 4)
        .background(RoundedRectangle(cornerRadius: 6)
            .fill(overDeleteZone ? Color.red.opacity(0.2) : Color.clear))
        .dropDestination(for: String.self) { items, _ in
            // `tabIndex` 一定要用上：少了它，從 space 分頁拖出來的窗格會被當成
            // 「目前可見」那棵樹的窗格刪掉——刪的是另一個版面而畫面上零訊號。
            guard let text = items.first, case let .pane(roleIndex, tabIndex, slots)? =
                DragPayload(text: text), let role = role(at: roleIndex)
            else { return false }
            let tabs = document.spaceTabs(location: location, profile: profile, role: role,
                                          live: liveSpaces[role] ?? [])
            guard tabs.indices.contains(tabIndex) else { return false }
            controller.apply {
                $0.deletingPane(at: PanePath(location: location, profile: profile,
                                             role: role, space: tabs[tabIndex].space,
                                             slots: slots))
            }
            return true
        } isTargeted: { overDeleteZone = $0 }
    }

    /// 刪掉選到的窗格。
    ///
    /// **走按鈕的 `keyboardShortcut` 而不是 `.onKeyPress`。** 後者要那個 view 拿到
    /// SwiftUI 的鍵盤焦點，而 `.focusable()` ＋ `@FocusState` 在這個環境拿不到
    /// first responder（2026-08-28 人工實測兩輪，掛在畫布最外層與掛在每一格上都
    /// 是按了完全沒反應；最可能的成因是 macOS 的「鍵盤導覽」預設關閉）。
    /// `keyboardShortcut` 是視窗層級的，不經過焦點。
    ///
    /// **裸的 Backspace，不帶 ⌘。** 使用者要的就是這個鍵。
    ///
    /// 它是視窗層級的，所以理論上會在規則表格打字時攔截 Backspace——但 AppKit 的
    /// key equivalent 是**先給 first responder**，文字欄位吃掉那個鍵之後就不會再
    /// 往下傳。2026-08-28 人工實測「在 label 欄位打字時按 Backspace，選到的窗格
    /// 沒有被刪」，所以這條路是安全的。**改動這一行要重驗那件事**——它的失敗
    /// 樣子是「刪掉一個字元的同時窗格也消失了」，而使用者不會把兩件事連起來。
    ///
    /// `.disabled` 那條同時是安全網：沒有選取時這個快捷鍵整個不存在，
    /// 而畫布沒有選取正是打字時的常態。
    private var removeButton: some View {
        Button("移除窗格") {
            deleteSelected()
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .keyboardShortcut(.delete, modifiers: [])
        // 沒有選取時 disabled：這個快捷鍵是視窗層級的，不擋的話它會在使用者沒有選
        // 任何東西的時候被按到，而那時候 `deleteSelected` 什麼都不做——一個安靜的
        // 快捷鍵與「壞了」分不出來。
        .disabled(selected == nil)
        .help(selected == nil
            ? "先點一個窗格，再按這裡或 Backspace"
            : "移除選到的窗格（Backspace）")
    }

    /// 刪掉選到的那一格。按鈕與 ⌘⌫ 共用這一支。
    private func deleteSelected() {
        guard let path = selected else { return }
        controller.apply { $0.deletingPane(at: path) }
        clearSelection()
    }

    private func role(at index: Int) -> String? {
        let all = document.canvasRoles(location: location, profile: profile)
        return all.indices.contains(index) ? all[index].role : nil
    }

    /// **get 這一側也要夾取**：`selectedTab` 是 view 的狀態，不會跟著文件變。
    /// 刪掉正在看的那一頁之後 `PaneView` 靠 `tab(for:role:)` 退回第 0 頁，但分頁列
    /// 若拿到越界的索引就**一片高亮都沒有**——畫布顯示第一頁而分頁列說「沒有選任何
    /// 一頁」，兩邊互相矛盾（2026-08-23 由 fresh-context verifier 抓到）。
    private func binding(for index: Int, role: String) -> Binding<Int> {
        Binding(get: { tab(for: index, role: role) }, set: {
            // 換一頁＝換一棵樹，舊的路徑指向的東西在這一頁不存在。
            clearSelection()
            selectedTab[index] = $0
        })
    }

    /// **選到的分頁被刪掉之後要退回第一頁**：`selectedTab` 是 view 的狀態，不會跟著
    /// 文件變。留著越界的索引會讓那一格畫成空白而使用者看不出為什麼。
    private func tab(for index: Int, role: String) -> Int {
        let count = document.spaceTabs(location: location, profile: profile, role: role,
                                       live: liveSpaces[role] ?? []).count
        let want = selectedTab[index] ?? 0
        return want < count ? want : 0
    }

    /// 現在看的那一頁的 space uuid。
    ///
    /// 分頁列空的時候回空字串——`JSONPath` 對走不通的路徑是 no-op，而分頁列空就
    /// 代表這個角色沒有東西可以編（沒接 yabai 而且一棵樹都還沒畫）。
    private func space(for index: Int, role: String) -> String {
        let tabs = document.spaceTabs(location: location, profile: profile, role: role,
                                      live: liveSpaces[role] ?? [])
        guard !tabs.isEmpty else { return "" }
        return tabs[tab(for: index, role: role)].space
    }
}
