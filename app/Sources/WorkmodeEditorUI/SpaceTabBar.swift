import SwiftUI
import WorkmodeEditorControl
import WorkmodeEditorModel

/// 一個螢幕角色畫布上方的分頁列。**每一頁是一個 space**。
///
/// **2026-08-30 之前第一頁是「目前可見」**（`trees.<角色>`），其餘是使用者手動命名的
/// space，還有一顆「+」按鈕與右鍵的「改名／刪除」。全部拿掉了：分頁自動列出 yabai
/// 查得到的 space，身分是 uuid 不是名字，所以沒有東西可以命名。
///
/// **一個判斷都不寫在這裡**：分頁清單、順序、哪些是孤兒全部來自 Model
/// （`spaceTabs`）。`WorkmodeEditorUI` 零測試，`DependencyRuleTests` 的三條禁令
/// 就是為了讓判斷寫不進來。
struct SpaceTabBar: View {
    let controller: EditorController
    let document: LayoutDocument
    let location: String
    let profile: String
    let role: String
    /// yabai 現在查到的 space。由 `CanvasView` 查一次記起來再傳下來——
    /// 每次呼叫都 spawn 子行程，不能寫在 view body 的求值路徑上。
    let live: [LiveSpace]
    @Binding var selected: Int

    private var tabs: [SpaceTab] {
        document.spaceTabs(location: location, profile: profile, role: role, live: live)
    }

    var body: some View {
        HStack(spacing: 4) {
            ForEach(Array(tabs.enumerated()), id: \.offset) { index, tab in
                chip(index: index, tab: tab)
            }
            Spacer()
            Text("版面").font(.caption2).foregroundStyle(.secondary)
            ForEach(PaneTemplate.allCases, id: \.self) { template in
                Button(template.title) {
                    controller.applyTemplate(template, at: PanePath(
                        location: location, profile: profile, role: role,
                        space: currentSpace, slots: []
                    ))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .font(.caption2)
                .help("把整個「\(role)」重排成\(template.title)；"
                    + "現有的視窗會依序填進去，放不下就整個不動")
            }
        }
    }

    private func chip(index: Int, tab: SpaceTab) -> some View {
        Text(label(tab))
            .font(.caption)
            // 孤兒那一頁：`spaceTrees` 裡有樹、但 yabai 查不到這個 space
            // （被 macOS 刪掉了，或根本沒接上 yabai）。標橘字而不是藏起來——
            // 藏起來等於在畫面上把那棵樹刪掉，而 `validate` 照樣會檢查它。
            .foregroundStyle(warning(tab) == nil ? Color.primary : Color.orange)
            .padding(.horizontal, 8).padding(.vertical, 2)
            .background(Capsule().fill(index == selected
                    ? Color.accentColor.opacity(0.25)
                    : Color.secondary.opacity(0.12)))
            .help(warning(tab) ?? tooltip(tab))
            .onTapGesture { selected = index }
    }

    /// 標籤用 **yabai 的編號**，查不到就退回 uuid 前 8 碼。
    ///
    /// 編號不寫進檔案：重新插拔螢幕會跳號（實測本機是 1、3、2），uuid 才是身分。
    private func label(_ tab: SpaceTab) -> String {
        guard let index = tab.index else { return String(tab.space.prefix(8)) }
        return "space \(index)"
    }

    /// 模板要套在**現在看的那一頁**的樹上。
    ///
    /// 夾取的方式與 `CanvasView.tab(for:role:)` 相同（越界退回第一頁）：
    /// 兩邊不一致的話，按鈕會把版面套到使用者沒有在看的那一棵，而畫面上零訊號。
    ///
    /// 分頁列可能是空的（沒接 yabai 且這個角色一棵樹都沒有），那時回空字串——
    /// `applyTemplate` 對走不通的路徑是 no-op，而按鈕本來就沒有東西可以套。
    private var currentSpace: String {
        let list = tabs
        guard list.indices.contains(selected) else { return list.first?.space ?? "" }
        return list[selected].space
    }

    /// 這一頁有沒有問題。回 nil ＝ 沒問題。
    private func warning(_ tab: SpaceTab) -> String? {
        guard tab.index == nil else { return nil }
        return "yabai 查不到這個 space（\(tab.space)）——它可能已經被刪掉了，"
            + "或者現在沒接上 yabai。這棵樹留在檔案裡，但 workmode --space 套不到它。"
    }

    private func tooltip(_ tab: SpaceTab) -> String {
        tab.hasTree ? tab.space : "\(tab.space)（還沒畫版面）"
    }
}
