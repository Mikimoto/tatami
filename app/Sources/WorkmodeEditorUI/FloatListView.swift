import SwiftUI
import WorkmodeEditorControl

/// 「快捷鍵」頁底部的 float 清單：這些 app 不被 balance／rotate／gaps 動到。
///
/// 獨立檔案是為了不把 `HotkeyView.swift` 推向 `file_length`；判斷全部在
/// `HotkeyEditor`（空字串、重複、索引越界），這一層照抄其他分頁的紀律
/// ——`WorkmodeEditorUI` 零測試，寫進來的判斷沒有東西驗得到。
struct FloatListView: View {
    @Bindable var editor: HotkeyEditor
    @State private var draft = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("這些 app 不被「均分／轉 90°／間隙」動到").font(.headline)
            // 為什麼只有那三個：它們掃整個 space，是唯一沒有「使用者指著誰」的
            // 動作。`--space` 的樹是明確加入的，focus／swap 是指著一個視窗做的。
            Text("對應 yabai 的 manage=off。名字要與選單列上顯示的相同（本地化名稱，"
                + "例如「訊息」不是 Messages）。")
                .font(.callout).foregroundStyle(.secondary)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(editor.floatApps.enumerated()), id: \.element) { index, name in
                        HStack {
                            Text(name).monospaced()
                            Spacer()
                            Button("", systemImage: "trash") { editor.removeFloatApp(at: index) }
                                .buttonStyle(.borderless)
                        }
                        .padding(.horizontal, 4)
                    }
                }
            }
            .frame(maxHeight: 150)
            HStack {
                TextField("app 名稱（例：Finder）", text: $draft)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(add)
                Button("加入", action: add)
                    .disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(12)
    }

    private func add() {
        editor.addFloatApp(draft)
        draft = ""
    }
}
