import SwiftUI
import WorkmodeDomain
import WorkmodeEditorControl

/// 「格線」那一頁的下半：位置庫（`hotkeys.json` 的 `zones`）。
///
/// **分成獨立一個檔**而不是塞進 `GridSettingsView`：與「快捷鍵」那一頁把 float
/// 清單與滑鼠設定各自拆成 `FloatListView`／`MouseSettingsView` 同一條先例——
/// 一頁多一段就多一段，那個檔遲早撞上 `file_length`（上限 400，`.swiftlint.yml`
/// 的檔頭明寫不准調參數）。
///
/// **這一層一個判斷都不做**（與其他分頁逐字同一條紀律）：名字能不能改、快捷鍵
/// 收不收、哪幾組撞了，全部問 `GridSettingsEditor`（`renameRejection`／
/// `hotkeyRejection`／`conflicts`）。`WorkmodeEditorUI` 零測試，判斷寫進來就沒有
/// 任何東西驗得到。
struct ZoneListView: View {
    let editor: GridSettingsEditor

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            if editor.zones.isEmpty {
                empty
            } else {
                table
            }
        }
    }

    private var header: some View {
        HStack {
            Text("位置庫").font(.headline)
            Spacer()
            Text("\(editor.zones.count) 個").font(.callout).foregroundStyle(.secondary)
        }
    }

    /// 沒有 zone 時那句話。**只講今天做得到的事**：這一頁建不出新的 zone
    /// （要指一塊矩形，見 `GridSettingsEditor.zones` 的 doc），唯一的入口是面板上
    /// 那顆「記」。按鍵寫成「預設」——它是一條使用者改得動的綁定
    /// （`HotkeyDefaults` 的 `grid-picker`），寫死會在他改過之後變成假話。
    private var empty: some View {
        Text("還沒有存過位置。開格線面板（預設 ⌃⌥⌘G）、拖出一塊，"
            + "再按右上角的「記」就會存進來，然後回到這裡改名字或設快捷鍵。")
            .font(.callout).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    /// 一列。**索引不能當 id**（刪掉一列之後後面每一列的 id 都變了，SwiftUI 會把
    /// 整個表重畫並丟掉錄製狀態），所以用內容加索引組出來的複合鍵——與
    /// `HotkeyView.Row`／`CanvasView.IndexedCanvasRole` 同一條。
    private struct Row: Identifiable {
        let id: String
        let index: Int
        let zone: GridZone
    }

    private var rows: [Row] {
        editor.zones.enumerated().map { index, zone in
            Row(id: "\(index)-\(zone.name)", index: index, zone: zone)
        }
    }

    private var table: some View {
        let clashing = Set(editor.conflicts)
        return ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(rows) { row in
                    ZoneRow(editor: editor, index: row.index, zone: row.zone,
                            isConflicting: row.zone.hotkey.map(clashing.contains) ?? false)
                    Divider()
                }
            }
        }
        .frame(maxHeight: 220)
    }
}

/// 一個 zone 那一列。拒絕的那句話是**每一列自己的**狀態，所以這裡是一個 struct
/// 而不是 `ZoneListView` 的一支 `func`——放在外面的話一列被拒會讓每一列都跳出
/// 同一句話。
private struct ZoneRow: View {
    let editor: GridSettingsEditor
    let index: Int
    let zone: GridZone
    let isConflicting: Bool
    /// 上一次改名被拒的理由。**句子由 Control 給**（`renameRejection`），
    /// 這一層不發明措辭。
    @State private var refusal: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            line
            if let refusal {
                Text(refusal).font(.caption).foregroundStyle(.orange)
            }
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 5)
    }

    private var line: some View {
        HStack(spacing: 10) {
            ZoneNameField(name: zone.name, refusal: $refusal) { typed in
                refusal = editor.renameRejection(at: index, to: typed)
                editor.renameZone(at: index, to: typed)
            }
            .frame(width: 160)
            // `spec` 唯讀，理由在 `GridSettingsEditor.zones` 的 doc：改它要指一塊
            // 矩形，而那件事在面板做得到；手打那六個數字打錯了畫面上什麼都不會說。
            Text(zone.gridText)
                .monospaced().font(.callout).foregroundStyle(.secondary)
                .frame(width: 120, alignment: .leading)
                .help("這塊位置的格線座標（欄:列:x:y:寬:高）。要改它就在格線面板重拖一塊。")
            HotkeyRecorder(hotkey: zone.hotkey, isConflicting: isConflicting) {
                editor.setHotkey($0, forZoneAt: index)
            }
            .frame(width: 190)
            Button("", systemImage: "xmark.circle") { editor.clearHotkey(forZoneAt: index) }
                .buttonStyle(.borderless)
                .disabled(zone.hotkey == nil)
                .help("清掉這個位置的快捷鍵。它在面板裡照樣點得到。")
            Spacer(minLength: 0)
            Button("", systemImage: "trash") { editor.removeZone(named: zone.name) }
                .buttonStyle(.borderless)
                .help("刪掉這個位置")
        }
    }
}

/// 名字那一格。**本地緩衝，`onSubmit` 與失焦才提交**——直接繫結會讓每個按鍵都是
/// 一次改名，而打到一半的名字撞到別人就會被拒（於是那一格跳回去，打不完一個字）。
///
/// 這是這個 target 裡第三份同形狀的東西（`RuleTableView.EditableCell`、
/// `LocationView.BufferedField`），而那兩份是**刻意**不抽共用型別的——它們各自
/// 帶著同一段「提交被拒要把緩衝退回 `initial`」的註解。這一份多一件事（把拒絕的
/// 理由掛回去），所以照舊各留一份。**改其中一份就要看另外兩份。**
private struct ZoneNameField: View {
    let name: String
    @Binding var refusal: String?
    let onCommit: (String) -> Void
    @State private var buffer: String = ""
    @FocusState private var focused: Bool

    var body: some View {
        TextField("", text: $buffer)
            .textFieldStyle(.roundedBorder)
            .foregroundStyle(refusal == nil ? Color.primary : Color.orange)
            .focused($focused)
            .onAppear { buffer = name }
            .onChange(of: name) { _, new in
                buffer = new
                refusal = nil
            }
            .onSubmit(commit)
            .onChange(of: focused) { _, isFocused in commitOnBlur(isFocused) }
    }

    /// 失焦才提交。抽成具名函式而不是內嵌 `if`，是為了讓 swiftlint 的
    /// `closure_parameter_position` 對得起來（`HotkeyView.ActionField` 同一條）。
    private func commitOnBlur(_ isFocused: Bool) {
        guard !isFocused else { return }
        commit()
    }

    private func commit() {
        guard buffer != name else {
            refusal = nil
            return
        }
        onCommit(buffer)
        // 提交被拒時退回原值：那一格的 `name` 沒變，`onChange` 不會觸發，不自己退
        // 就會留著使用者打的字而檔案裡什麼都沒有（`RuleTableView.EditableCell`
        // 記過同一個坑）。**理由那句話留著**，不然這裡看起來就只是「打的字消失了」。
        buffer = name
    }
}
