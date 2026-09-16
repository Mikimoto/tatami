import SwiftUI
import WorkmodeEditorControl

// ⌘S 那兩則 alert。**拆成獨立檔案的理由是 lint**：yabairc 分頁接上之後
// `EditorWindow.swift` 是 406 行（上限 400），而 `.swiftlint.yml` 開頭明寫不准為了讓
// 數字消失去調參數。搬哪一塊的判準與 `ApplyButton.swift` 同一條——跨檔案的 extension
// 看不見 `EditorWindow` 的 `private` 欄位，所以只能搬「收 Binding 就夠」的東西，
// 這兩則正好是（其餘幾則都要讀 `controller`）。

extension View {
    /// 存檔擋下來的兩則。**兩個狀態不是一個**：外部變更是唯一一種「可以硬幹」的擋下，
    /// 而那個「用我的蓋過去」按鈕要是出現在 validate 擋下來的對話框上，按下去就是
    /// 寫出一份不合法的設定檔。分兩則讓那個按鈕沒有出現在別處的可能。
    ///
    /// 收 `Binding` 而不是讀狀態，理由見檔頭。
    func saveAlerts(problems: Binding<[String]>,
                    externalChange: Binding<Bool>,
                    onOverwrite: @escaping () -> Void) -> some View
    {
        // 不要寫成 `.constant(!problems.isEmpty)`：那樣 SwiftUI 想關閉它的時候
        // （Esc、點外面）寫不回去，alert 會卡在一個它自己以為已經關掉的狀態。
        alert("沒有寫入", isPresented: Binding(
            get: { !problems.wrappedValue.isEmpty },
            set: {
                if !$0 {
                    problems.wrappedValue = []
                }
            }
        )) {
            Button("知道了") { problems.wrappedValue = [] }
        } message: {
            Text(problems.wrappedValue.joined(separator: "\n"))
        }
        // `SaveOutcome.blockedByExternalChange` 的註解一直說「呼叫端要問使用者」，
        // phase 1 沒有那個呼叫端（`save(force: true)` 只有測試在走），這裡補上。
        // **只有 layout.json 走這則**：yabairc 沒有 force 的存檔，見 `EditorWindow.save()`。
        .alert("layout.json 在編輯期間被改過了", isPresented: externalChange) {
            Button("用我的蓋過去", role: .destructive) { onOverwrite() }
            Button("取消", role: .cancel) { externalChange.wrappedValue = false }
        } message: {
            Text(verbatim: "磁碟上的內容與載入時不同（有人手改，或跑過 workmode --save）。"
                + "蓋過去會丟掉那些變更；取消之後關掉重開會載入新的內容。")
        }
    }
}

/// 兩份「沒有 force 的存檔」的結果翻成給人看的話。
///
/// **搬出 `EditorWindow` 的理由是 lint**：快捷鍵那一頁接上之後那個 struct 的
/// body 是 280 行（`type_body_length` 上限 250，不計註解與空行），而
/// `.swiftlint.yml` 開頭明寫不准為了讓數字消失去調參數。這兩支不碰任何
/// `private` 欄位（收結果、回字串），所以搬得動——與這個檔原本那兩則 alert
/// 同一個判準。
/// 側欄那幾頁「不是 `layout.json`」的檔案：yabai 設定、快捷鍵、格線。
///
/// 三頁的 dirty／canSave／存檔結果**形狀相同**，而 `EditorWindow` 對它們的問法原本
/// 是三組各自的 `if`。格線那一頁（第四份表面、第三個 editor）加進來的時候那三組
/// 會漲成十二行分支，而 `EditorWindow` 的 `type_body_length` 已經滿了（上限 250，
/// 不計註解與空行，`.swiftlint.yml` 開頭明寫不准調參數）。收成一個 enum 之後
/// 每個問題只問一次，而**下一份檔案只要在這裡加一個 case**——漏掉哪一個問題
/// 會是編譯錯誤，不是「那一頁的 ⌘S 安靜地去存了 layout.json」。
///
/// 住在這個檔而不是 `EditorWindow.swift`：它一個 `@State` 都不碰（收 editor、回值），
/// 與這個檔原本那兩則 alert 及 `SideFileSave` 同一個判準，見檔頭。
enum SideFilePage {
    case hotkeys(HotkeyEditor)
    case grid(GridSettingsEditor)

    var isDirty: Bool {
        switch self {
        case let .hotkeys(editor): editor.isDirty
        case let .grid(editor): editor.isDirty
        }
    }

    /// 每一邊都問對方自己的 `canSave`，這一層不發明判準。
    var canSave: Bool {
        switch self {
        case let .hotkeys(editor): editor.canSave
        case let .grid(editor): editor.canSave
        }
    }

    /// 存檔，並把結果翻成給人看的話。
    ///
    /// **這兩頁都不走 `externalChange` 那則 alert**：它的標題寫死 layout.json，
    /// 而它的「用我的蓋過去」按的是 `controller.save(force:)`——寫的是另一份檔。
    func save() -> [String] {
        switch self {
        case let .hotkeys(editor): SideFileSave.text(editor.save())
        case let .grid(editor): SideFileSave.text(editor.save())
        }
    }
}

enum SideFileSave {
    static func text(_ outcome: HotkeySave) -> [String] {
        switch outcome {
        case .written, .unchanged: []
        case .blockedByExternalChange:
            ["hotkeys.json 在編輯期間被改過了。沒有寫入。", "關掉重開會載入新的內容。"]
        case let .failed(reason): [reason]
        }
    }
}
