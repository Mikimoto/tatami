import SwiftUI
import WorkmodeDomain
import WorkmodeEditorControl

/// 「快捷鍵」那一頁：一列一條綁定，按鍵那格用錄的，動作那格用選單或手打。
///
/// 與其他分頁同一條紀律——**這一層一個判斷都不做**。能不能存、有沒有撞、
/// 一個組合安不安全，全部問下面那層（`HotkeyEditor.canSave`／`.conflicts`、
/// `Hotkey.isSafeAsGlobalShortcut`）：`WorkmodeEditorUI` 零測試，寫進來的判斷
/// 沒有任何東西驗得到。
public struct HotkeyView: View {
    @Bindable var editor: HotkeyEditor

    public init(editor: HotkeyEditor) {
        self.editor = editor
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            if let failure = editor.loadFailure {
                ContentUnavailableView(failure, systemImage: "exclamationmark.triangle",
                                       description: Text("修好那個檔再開一次，"
                                           + "或把它刪掉讓 tatami 重建預設值。"))
            } else {
                table
                Divider()
                FloatListView(editor: editor)
                Divider()
                MouseSettingsView(editor: editor)
            }
        }
        .onAppear {
            if !editor.hasLoaded {
                editor.load()
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("快捷鍵").font(.title2)
            // 這句話是這一頁最重要的資訊：快捷鍵註冊在行程上，而不是像 skhd
            // 那樣有一個常駐的服務。沒有它，「改好了但按了沒反應」查不出原因。
            Text("這些鍵只在 Tatami 的選單列程式跑著的時候有效。"
                + "改完存檔之後要結束選單列再開一次才會重新註冊。")
                .font(.callout).foregroundStyle(.secondary)
            if !editor.problems.isEmpty {
                Text(editor.problems.joined(separator: "\n"))
                    .font(.callout).foregroundStyle(.orange)
            }
            HStack {
                Button("新增一條", systemImage: "plus") { editor.add() }
                Button("還原成預設的 \(HotkeyBindings.defaults.count) 條",
                       systemImage: "arrow.uturn.backward") { editor.restoreDefaults() }
                Spacer()
                Text("\(editor.bindings.count) 條")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
        .padding(12)
    }

    /// 一列。**索引不能當 id**（刪掉一列之後後面每一列的 id 都變了，SwiftUI 會
    /// 把整個表重畫並丟掉錄製狀態），所以用綁定內容加索引組出來的複合鍵。
    /// 那與 `CanvasView.IndexedCanvasRole`／`RuleTableView.IndexedRule` 同一條。
    private struct Row: Identifiable {
        let id: String
        let index: Int
        let binding: HotkeyBinding
    }

    private var rows: [Row] {
        editor.bindings.enumerated().map { index, binding in
            Row(id: "\(index)-\(binding.hotkey.description)", index: index, binding: binding)
        }
    }

    private var table: some View {
        let clashing = Set(editor.conflicts)
        return ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(rows) { row in
                    line(row, isConflicting: clashing.contains(row.binding.hotkey))
                    Divider()
                }
            }
        }
    }

    private func line(_ row: Row, isConflicting: Bool) -> some View {
        HStack(spacing: 10) {
            Toggle("", isOn: Binding(
                get: { row.binding.isEnabled },
                set: { editor.setEnabled($0, at: row.index) }
            ))
            .labelsHidden()
            .help("關掉的綁定留在檔案裡但不註冊")
            HotkeyRecorder(hotkey: row.binding.hotkey, isConflicting: isConflicting) {
                editor.setHotkey($0, at: row.index)
            }
            .frame(width: 220)
            actionCell(row)
            Button("", systemImage: "trash") { editor.remove(at: row.index) }
                .buttonStyle(.borderless)
                .help("刪掉這一條")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        .opacity(row.binding.isEnabled ? 1 : 0.45)
    }

    /// 動作那一格：一個選單列出常用的，加一個文字欄位給選單裡沒有的
    /// （`space:3`、`grid:2:2:0:0:1:1`、`shell:…`）。
    ///
    /// **文字欄位不能拿掉**：選單列不完（`space` 有九個、`grid` 的組合無限多），
    /// 而那個字串形式就是這個欄位的規範表示。
    private func actionCell(_ row: Row) -> some View {
        HStack(spacing: 6) {
            Menu(HotkeyCatalogue.label(for: row.binding.action)) {
                ForEach(HotkeyCatalogue.groups, id: \.title) { group in
                    Section(group.title) {
                        ForEach(group.actions, id: \.text) { action in
                            Button(HotkeyCatalogue.label(for: action)) {
                                editor.setAction(action.text, at: row.index)
                            }
                        }
                    }
                }
            }
            .frame(width: 220)
            ActionField(text: row.binding.action.text) { editor.setAction($0, at: row.index) }
        }
    }
}

/// 動作字串的輸入格。**本地緩衝，`onSubmit` 與失焦才提交**——直接繫結會讓每個
/// 按鍵都是一次編輯（打到一半的 `foc` 解不開，於是那一格會跳回去）。
/// 與 `RuleTableView.EditableCell`／`LocationView.BufferedField` 同一個做法。
private struct ActionField: View {
    let text: String
    let onCommit: (String) -> Void
    @State private var buffer: String = ""
    @FocusState private var focused: Bool

    var body: some View {
        TextField("", text: $buffer)
            .textFieldStyle(.roundedBorder)
            .monospaced()
            .focused($focused)
            .onAppear { buffer = text }
            .onChange(of: text) { _, new in buffer = new }
            .onSubmit(commit)
            .onChange(of: focused) { _, isFocused in commitOnBlur(isFocused) }
            .help("解不開的字串會被忽略，那一格會跳回原值")
    }

    /// 失焦才提交。抽成一支具名函式而不是內嵌 `if`，是為了讓 swiftformat 與
    /// swiftlint 的 `closure_parameter_position` 對得起來（多行 closure 的參數
    /// 會被排到第二行，而那條規則要求它與大括號同一行）。
    private func commitOnBlur(_ isFocused: Bool) {
        guard !isFocused else { return }
        commit()
    }

    private func commit() {
        guard buffer != text else { return }
        onCommit(buffer)
        // 提交被拒（解不開）時退回原值：那一格的 `text` 沒變，`onChange` 不會觸發，
        // 不自己退就會留著使用者打的字而檔案裡什麼都沒有
        // （`RuleTableView.EditableCell` 記過同一個坑）。
        buffer = text
    }
}
