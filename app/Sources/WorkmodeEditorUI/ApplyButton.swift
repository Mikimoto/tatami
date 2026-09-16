import SwiftUI
import WorkmodeEditorControl

// ⌘R 那顆按鈕的三個零件：toolbar 那一格、兩則 alert、以及把 readiness 與 outcome
// 翻成中文的那幾支。
//
// **拆成獨立檔案的理由有兩層。** 表面上是 lint：全部塞在 `EditorWindow.swift` 之後
// 那個檔 427 行（上限 400）、struct body 321 行（上限 250），而 `.swiftlint.yml` 開頭
// 明寫不准為了讓數字消失去調參數。更根本的是這一層本來就按功能拆檔
// （`CanvasView.swift`／`RuleTableView.swift`／`LocationView.swift`），套用這一組
// 放在自己的檔案裡與既有結構一致。
//
// **這裡一個 `@State` 都碰不到，那是設計不是巧合。** Swift 的 `private` 只對
// **同一個檔案**裡的 extension 開放，所以住在別的檔案的 extension 看不見
// `EditorWindow` 的 `applying`／`selection`／`controller`。要嘛把那些欄位放寬成
// internal，要嘛讓搬出來的東西不需要它們——選後者：放寬存取範圍是為了排版去動
// 封裝，而那四個 `@State` 只有 `EditorWindow` 該碰。所以這裡的東西一律
// **收參數或收 Binding**，`applyLayout()` 本身留在原檔。

/// toolbar 那一格。收值不讀狀態（見檔頭）：`disabledReason` 由呼叫端從選取算出來，
/// nil 代表可以按。
struct ApplyToolbarItem: ToolbarContent {
    let applying: Bool
    /// 側欄有沒有選在某個 profile 上。**收 Bool 而不是收那句話**：理由與那句話由
    /// 同一個地方算出來（下面的 `disabledReason`），分兩份寫會出現「灰掉但沒說為
    /// 什麼」或「說了卻按得下去」，而這一層零測試。
    let hasTarget: Bool
    /// 不能按的理由，nil ＝ 可以按。同一個值同時餵 `.disabled` 與 `.help`。
    private var disabledReason: String? {
        hasTarget ? nil : "先選一個 profile"
    }

    let action: () -> Void

    var body: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            Button(applying ? "套用中…" : "套用看看", action: action)
                .keyboardShortcut("r")
                .disabled(applying || disabledReason != nil)
                .help(disabledReason
                    ?? "把每個螢幕目前可見的那個 space，排成你在 spaceTrees 裡編的樹。")
        }
    }
}

extension View {
    /// 兩則各自一個狀態，理由與 `EditorWindow` 既有那三則相同：標題不同、時機不同，
    /// 而「不能套用」那則一個視窗都沒動、「套用完成」那則已經動過了——併成一則會讓
    /// 這個差別消失。
    ///
    /// 收 `Binding` 而不是讀狀態，理由見檔頭。
    func applyAlerts(refusal: Binding<String?>, report: Binding<String?>) -> some View {
        // 不要寫成 `.constant(...)`：那樣 SwiftUI 想關閉它的時候（Esc、點外面）
        // 寫不回去，alert 會卡在一個它自己以為已經關掉的狀態。與既有三則同一條。
        alert("不能套用", isPresented: Binding(
            get: { refusal.wrappedValue != nil },
            set: {
                if !$0 {
                    refusal.wrappedValue = nil
                }
            }
        )) {
            Button("知道了") { refusal.wrappedValue = nil }
        } message: {
            Text(verbatim: refusal.wrappedValue ?? "")
        }
        .alert("套用完成", isPresented: Binding(
            get: { report.wrappedValue != nil },
            set: {
                if !$0 {
                    report.wrappedValue = nil
                }
            }
        )) {
            Button("知道了") { report.wrappedValue = nil }
        } message: {
            Text(verbatim: report.wrappedValue ?? "")
        }
    }
}

/// 四支純函式與那個確認框。**`static` 而不是實例方法**：它們一個欄位都不需要，
/// 而 static 是 internal，跨檔案的 extension 拿得到（`private` 拿不到，見檔頭）。
extension EditorWindow {
    /// 確認框。**第一顆是「取消」**，與關窗那個對話框（`EditCommand.swift` 的
    /// `windowShouldClose`）同一條理由：第一顆是 Enter 的預設鍵，而 ⌘R 在很多 app
    /// 是 reload，反射性按下去之後最可能的下一個動作就是反射性 Enter——把「套用」
    /// 放預設，這道閘門對它最該防的情境就完全無效。
    ///
    /// **`@MainActor` 不是裝飾**：`NSAlert.runModal()` 是 main-actor 隔離的，不標就是
    /// 一行 `call to main actor-isolated instance method in a synchronous nonisolated
    /// context` 警告，而這個 repo 的驗收條件是零警告。
    ///
    /// **不講地點也不講 profile**：`SpaceLayout` 沒有 probe 模式，而我們刻意不加一個
    /// ——加了只為了這句抬頭文字，卻要多一條要驗的路徑。附帶好處是這個對話框現在
    /// **立刻**出現，舊版要先跑一次 probe（無條件 dump Safari 分頁，實測約兩秒），
    /// 而那兩秒畫面完全靜止。
    @MainActor static func confirmed() -> Bool {
        let alert = NSAlert()
        alert.messageText = "把目前可見的 space 套成你編的版面？"
        alert.informativeText = "這會搬動你真的視窗，而且沒有復原。"
        alert.addButton(withTitle: "取消")
        alert.addButton(withTitle: "套用")
        return alert.runModal() == .alertSecondButtonReturn
    }

    /// 三種 readiness 各一句。判斷全在 `EditorController.applyReadiness`（有測試），
    /// 這裡只把它翻成中文——`.ready` 走不到，但列舉沒有 `default` 才擋得住漏一種。
    ///
    /// 2026-08-30 之前有五種：`wrongLocation` 與 `probeFailed` 只有 probe 產生得出來，
    /// 而 ⌘R 改跑 `SpaceLayout` 之後沒有 probe（見 `ApplyReadiness` 的 doc）。
    static func refusalText(_ readiness: ApplyReadiness) -> String {
        switch readiness {
        case .ready:
            "可以套用。"
        case .notSaved:
            "有未存的變更。套用讀的是磁碟上的檔，所以先按 ⌘S。"
        case .notWired:
            "找不到 yabai，這個編輯器只能改檔案。"
        }
    }

    /// 套用沒跑到 `completed` 時它是哪一種。三句的差別是使用者要去改的東西
    /// 不同：設定檔本身、`displays` 的 UUID、還是那個地點的 profile 清單。
    ///
    /// **收 `ApplyRun` 而不是收那個 outcome，是因為它的型別在這一層寫不出名字。**
    /// `run.outcome` 的型別是 `SpaceLayout.Outcome`，住在 `WorkmodeCore`，而
    /// `WorkmodeEditorUI` 的 import allowlist 沒有它（實測：寫
    /// `func f(_ o: ApplyLayout.Outcome)` 得到 `cannot find type 'ApplyLayout' in scope`）。
    /// **值本身穿得過來**：leading-dot 的 `case .completed` 是拿被比對值的型別去查
    /// 成員，不需要那個型別的名字在 scope 裡；只有「寫成參數型別」才需要——所以
    /// 2026-08-30 把 `ApplyRun.outcome` 從 `ApplyLayout.Outcome` 換成
    /// `SpaceLayout.Outcome` 時，下面那四個 pattern 一個都不用改。
    ///
    /// **正解不是把 `WorkmodeCore` 加進 UI 的 allowlist。** 那一層裡有八個 port
    /// （`YabaiClient`／`FileStore`／…），開了門這個 view 就直接叫得到 yabai，
    /// 而整個編輯器的三層界線（`DependencyRuleTests.editorLayersKeepTheirDistance`）
    /// 就是為了讓那件事寫不進來。多一個 `ApplyRun(outcome:lines: [])` 的包裝便宜得多。
    static func outcomeText(_ run: ApplyRun) -> String {
        switch run.outcome {
        case let .completed(location, profile):
            "跑完了（\(location) / \(profile)）。"
        case .layoutUnavailable:
            "讀不到或讀不懂 layout.json——先用 workmode validate 看它在抱怨什麼。"
        case .locationUnrecognized:
            "現在接著的螢幕組合對不上任何地點的 displays。"
        case .profileUnresolved:
            "認出地點了，但那個地點挑不出 profile（default 指到不存在的那個？）。"
        }
    }

    /// 事件文字**逐行照原樣**：那幾行是 `HumanEventRenderer` 產的，與 CLI 印出來的
    /// 逐位元組相同，重排等於在這一層另外發明一套輸出。
    static func reportText(_ run: ApplyRun) -> String {
        let lines = run.lines.joined(separator: "\n")
        if case .completed = run.outcome {
            return lines.isEmpty ? "跑完了，但它一個字都沒說。" : lines
        }
        return lines + (lines.isEmpty ? "" : "\n\n") + "沒有跑完：" + outcomeText(run)
    }
}
