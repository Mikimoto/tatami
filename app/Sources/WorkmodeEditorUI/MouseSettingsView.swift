import SwiftUI
import WorkmodeDomain
import WorkmodeEditorControl

/// 「快捷鍵」頁的滑鼠拖曳那一段：按住哪一顆、左右鍵各做什麼。
///
/// 三個 `Picker`，一個判斷都不做——`MouseSettings` 自己管值域與預設值
/// （`WorkmodeEditorUI` 零測試，與其他分頁同一條紀律）。
struct MouseSettingsView: View {
    @Bindable var editor: HotkeyEditor

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("滑鼠拖曳").font(.headline)
            // 為什麼要講這件事：它取代的是 yabai 最後一個工作，而使用者按了十年
            // 的手勢是 fn ＋ 拖曳。改了之後與快捷鍵同一條規矩——要重開選單列。
            Text("按住修飾鍵再拖曳視窗任何一處。縮放時抓在哪一角就動哪一角，"
                + "對面那一角釘住。")
                .font(.callout).foregroundStyle(.secondary)
            HStack(spacing: 16) {
                Picker("修飾鍵", selection: modifier) {
                    ForEach(MouseSettings.Modifier.allCases, id: \.self) { option in
                        Text(option.rawValue).tag(option)
                    }
                }
                .frame(width: 160)
                Picker("左鍵", selection: button(\.button1)) {
                    ForEach(actionChoices, id: \.0) { Text($0.1).tag($0.0) }
                }
                .frame(width: 150)
                Picker("右鍵", selection: button(\.button2)) {
                    ForEach(actionChoices, id: \.0) { Text($0.1).tag($0.0) }
                }
                .frame(width: 150)
            }
        }
        .padding(12)
    }

    /// `Picker` 的 tag 不能是 Optional，所以「關掉」用空字串表示。
    private var actionChoices: [(String, String)] {
        [("move", "搬移"), ("resize", "縮放"), ("", "關掉")]
    }

    private var modifier: Binding<MouseSettings.Modifier> {
        Binding(get: { editor.mouse.modifier }, set: { next in
            editor.setMouse(MouseSettings(modifier: next, button1: editor.mouse.button1,
                                          button2: editor.mouse.button2))
        })
    }

    private func button(_ path: KeyPath<MouseSettings, MouseDrag.Action?>) -> Binding<String> {
        Binding(
            get: { editor.mouse[keyPath: path]?.rawValue ?? "" },
            set: { next in
                let action = MouseDrag.Action(rawValue: next)
                let current = editor.mouse
                editor.setMouse(path == \MouseSettings.button1
                    ? MouseSettings(modifier: current.modifier, button1: action,
                                    button2: current.button2)
                    : MouseSettings(modifier: current.modifier, button1: current.button1,
                                    button2: action))
            }
        )
    }
}
