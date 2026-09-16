import SwiftUI
import WorkmodeDomain
import WorkmodeEditorControl

/// 側欄「格線」那一頁：每台螢幕的格數與間距，右邊一個預覽。
///
/// **預覽只畫純色 ＋ 格線，不畫真桌布。** 桌布要
/// `NSWorkspace.desktopImageURL(for:)`，而這一層不准 import Adapters
/// （`DependencyRuleTests` 掃原始碼在守），得再開一個閉包穿進去——換到的只是好看。
struct GridSettingsView: View {
    let editor: GridSettingsEditor
    @State private var selected = ""

    var body: some View {
        content
            .padding()
            .onAppear {
                editor.loadOnce()
                if selected.isEmpty {
                    selected = editor.screens.first?.uuid ?? ""
                }
            }
    }

    /// 檔案看不懂時整頁換成那句話，與 `HotkeyView` 逐字同一個形狀：讓使用者改一堆
    /// 數字再發現 ⌘S 是灰的，比一開始就講出來糟。**句子由 Control 給**
    /// （`GridSettingsEditor.loadFailure`），這一層不發明措辭。
    @ViewBuilder private var content: some View {
        if let failure = editor.loadFailure {
            ContentUnavailableView(failure, systemImage: "exclamationmark.triangle",
                                   description: Text("修好那個檔再開一次，"
                                       + "或把它刪掉讓 tatami 重建預設值。"))
        } else {
            settings
        }
    }

    /// 上半是每台螢幕的格數與間距，下半是位置庫。**同一頁**而不是側欄再開一項：
    /// 兩者住在同一個檔（`hotkeys.json`），第三個 editor 就是那個檔的第三個寫入者，
    /// 而每一個都有自己的「外部變更」處置——只會讓「A 頁存過之後 B 頁存不了」
    /// 更常發生。而且一個 zone 就是一塊格線位置，與上半同一個主題。
    private var settings: some View {
        VStack(alignment: .leading, spacing: 16) {
            displaySettings
            Divider()
            ZoneListView(editor: editor)
            Spacer(minLength: 0)
        }
    }

    private var displaySettings: some View {
        VStack(alignment: .leading, spacing: 16) {
            // **螢幕那一列佔整個寬度，不在左邊那個 260pt 的欄裡。**
            // 2026-09-09 人工驗抓到：三台真螢幕的名字讓 segmented picker 的固有寬度
            // 遠超過 260，而 `.frame(width: 260)` **不會壓縮它**——它把那個過寬的
            // 內容置中，於是左右各切掉一塊。症狀是整個左欄看起來往左移：
            // 「欄：6」只剩「6」、說明那一行前後都被咬掉。
            // 這個缺陷比位置庫早（`c9620e4` 就是這樣），只是這一頁沒有人配真螢幕看過。
            Picker("螢幕", selection: $selected) {
                ForEach(editor.screens, id: \.uuid) { screen in
                    Text(screen.name).tag(screen.uuid)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            grid
        }
    }

    private var grid: some View {
        HStack(alignment: .top, spacing: 24) {
            VStack(alignment: .leading, spacing: 16) {
                let current = editor.config(forDisplay: selected)
                Stepper("欄：\(current.columns)", value: columns, in: 1 ... 12)
                Stepper("列：\(current.rows)", value: rows, in: 1 ... 12)
                Stepper("視窗間距：\(Int(current.gap)) pt", value: gap, in: 0 ... 80, step: 4)

                Text("格線與 balance／rotate 都用這個間距。留 0 就是不留縫。")
                    .font(.caption).foregroundStyle(.secondary)
                // 這裡原本有一個 `Spacer()`（那時這一頁只有這一段，它把控制項推到
                // 頂端）。位置庫接在下面之後它會把上半撐到吃掉整頁，而 HStack 本來
                // 就是 `.top` 對齊——留著只有害處。
            }
            .frame(width: 260)

            GridPreview(config: editor.config(forDisplay: selected))
                .frame(maxWidth: .infinity, maxHeight: 240)
        }
    }

    /// 三個 stepper 各自一個 binding，寫回去走 `editor.set`。
    private var columns: Binding<Int> {
        field(\.columns) { GridConfig(columns: $1, rows: $0.rows, gap: $0.gap) }
    }

    private var rows: Binding<Int> {
        field(\.rows) { GridConfig(columns: $0.columns, rows: $1, gap: $0.gap) }
    }

    /// 兩個引數都寫在括號裡：`columns`／`rows` 那兩支的第一個是 key path 所以
    /// 尾隨閉包合法，這一支兩個都是閉包（`multiple_closures_with_trailing_closure`）。
    private var gap: Binding<Int> {
        field({ Int($0.gap) },
              { GridConfig(columns: $0.columns, rows: $0.rows, gap: Double($1)) })
    }

    private func field(_ read: @escaping (GridConfig) -> Int,
                       _ write: @escaping (GridConfig, Int) -> GridConfig) -> Binding<Int>
    {
        Binding(get: { read(editor.config(forDisplay: selected)) },
                set: { editor.set(write(editor.config(forDisplay: selected), $0),
                                  forDisplay: selected) })
    }
}

/// 預覽。格線畫在等分處，**用的是與 `GridSelection` 邊界相同的算式**
/// （`extent * i / n`）——各寫一套的症狀是「預覽長這樣、實際排出來不是」。
private struct GridPreview: View {
    let config: GridConfig

    var body: some View {
        GeometryReader { geometry in
            let size = geometry.size
            ZStack {
                RoundedRectangle(cornerRadius: 8).fill(.quaternary)
                Path { path in
                    for column in 1 ..< max(config.columns, 1) {
                        let position = size.width * Double(column) / Double(config.columns)
                        path.move(to: CGPoint(x: position, y: 0))
                        path.addLine(to: CGPoint(x: position, y: size.height))
                    }
                    for row in 1 ..< max(config.rows, 1) {
                        let position = size.height * Double(row) / Double(config.rows)
                        path.move(to: CGPoint(x: 0, y: position))
                        path.addLine(to: CGPoint(x: size.width, y: position))
                    }
                }
                .stroke(.separator, lineWidth: 1)
            }
        }
    }
}
