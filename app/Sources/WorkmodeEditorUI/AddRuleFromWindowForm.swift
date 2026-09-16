import SwiftUI
import WorkmodeEditorControl
import WorkmodeEditorModel

/// 「從視窗建立規則」的 popover：挑一個現在開著的視窗，再挑一個條件。
///
/// 與 `AddLocationForm` 同一個形狀，包括同一個代價：狀態住在 popover 內容裡，
/// **選到一半關掉再打開是空的**。
///
/// 加到哪一層在**點選單的時候**就定了（`scope`），所以這裡沒有層的欄位。
struct AddRuleFromWindowForm: View {
    let controller: EditorController
    let scope: RuleScope
    @Binding var isPresented: Bool

    @State private var choices: [WindowChoice] = []
    @State private var loading = true
    @State private var windowID = ""
    @State private var conditionIndex = 0

    private var selected: WindowChoice? {
        choices.first { $0.id == windowID }
    }

    private var conditions: [RuleCondition] {
        selected?.conditions ?? []
    }

    private var condition: RuleCondition? {
        conditions.indices.contains(conditionIndex) ? conditions[conditionIndex] : nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("從現在開著的視窗建立一條規則").font(.headline)
            if loading {
                // Safari 的分頁 dump 實測 1.94 秒，畫面上要說它在做什麼。
                Text("讀取視窗清單…（Safari 的分頁要幾秒）")
                    .font(.caption).foregroundStyle(.secondary)
            } else if choices.isEmpty {
                Text("查不到任何視窗。yabai 沒接上的時候也會是這樣。")
                    .font(.caption).foregroundStyle(.orange)
            }
            Picker("視窗", selection: $windowID) {
                Text("（選一個）").tag("")
                ForEach(choices, id: \.id) { choice in
                    Text(verbatim: label(for: choice)).tag(choice.id)
                }
            }
            .frame(width: 420)
            .onChange(of: windowID) { _, _ in conditionIndex = 0 }
            if selected != nil {
                Picker("條件", selection: $conditionIndex) {
                    ForEach(Array(conditions.enumerated()), id: \.offset) { index, item in
                        Text(verbatim: "\(item.summary)：\(item.value)").tag(index)
                    }
                }
                .frame(width: 420)
            }
            if let selected, selected.tabURL == nil {
                // 講出理由：只有一個選項而使用者不知道為什麼。
                Text("這個視窗沒有分頁資訊，所以只能用 App 名稱——"
                    + "網址與標題那三種條件都是從 Safari 的分頁清單比對的。")
                    .font(.caption).foregroundStyle(.secondary)
                    .frame(width: 420, alignment: .leading)
            }
            HStack {
                Spacer()
                Button("取消") { isPresented = false }
                Button("建立") {
                    if let selected, let condition {
                        controller.apply {
                            $0.insertingRule(scope, label: selected.app,
                                             match: (condition.kind.rawValue,
                                                     condition.value))
                        }
                    }
                    isPresented = false
                }
                .disabled(condition == nil)
            }
        }
        .padding()
        // **查一次記起來**：`connectedWindows()` spawn 兩個子行程、實測要兩秒，
        // 寫在 body 的求值路徑上會讓每個按鍵都重跑一次。
        .onAppear {
            choices = controller.connectedWindows()
            loading = false
        }
    }

    private func label(for choice: WindowChoice) -> String {
        var text = "\(choice.app)"
        if !choice.title.isEmpty {
            text += " — \(choice.title)"
        }
        if let url = choice.tabURL {
            text += "　\(url)"
        }
        return text
    }
}
