import SwiftUI
import WorkmodeDomain
import WorkmodeEditorControl
import WorkmodeEditorModel

/// 側欄選一個 profile，detail 畫那個地點的螢幕；選「視窗規則」時 detail 換成表格。
public struct EditorWindow: View {
    @State private var controller: EditorController
    /// **Optional 不是可以省掉的。** `List` 的單選 initializer 收的是
    /// `Binding<SelectionValue?>`，傳非 Optional 的 binding 直接編不過；
    /// 而且側欄真的可以被點成沒有選中。
    @State private var selection: Selection? = .rules
    @State private var problems: [String] = []
    /// 外部變更自己一個狀態，不擠進 `problems`：它是唯一一種「可以硬幹」的擋下，
    /// 而那個「用我的蓋過去」按鈕要是出現在 validate 擋下來的對話框上，按下去就是
    /// 寫出一份不合法的設定檔。分兩個 alert 讓那個按鈕沒有出現在別處的可能。
    @State private var externalChange = false
    /// 「新增地點」那個 popover 開著沒有。**欄位與它們的守衛在 `AddLocationForm`**
    /// （`LocationView.swift`）——搬出去的理由是 lint：留在這裡這個 struct 的 body
    /// 是 260 行（上限 250），而 `.swiftlint.yml` 開頭明寫不准為了讓數字消失去調參數。
    @State private var addingLocation = false
    /// ⌘R 那顆按鈕正在跑。
    ///
    /// **它擋連按，但它看不見。** 整個流程同步跑在 main thread 上，所以設成 true
    /// 之後 SwiftUI 沒有機會重畫——2026-08-20 實測（讀 SwiftUI 的重畫時機，非人工
    /// 觀察）：第一個重畫機會是 `NSAlert.runModal()` 的巢狀 run loop，所以
    /// **probe 那一趟（約兩秒）畫面完全靜止**，「套用中…」只在確認框出現之後到套用
    /// 結束之間看得到。不要據此宣稱「按下去就有反應」——前半段沒有。
    ///
    /// 旗子留著是因為停用是真的：main thread 被佔住時的點擊會排隊，解開之後那顆
    /// 按鈕已經 disabled。刻意不改成 `Task`：這一層零測試，而 actor 隔離與
    /// 「按兩次會怎樣」是兩個沒人驗得到的新分支。
    @State private var applying = false
    /// readiness 不是 `.ready` 時要講的那句話。與 `problems` 分開：那則的標題是
    /// 「沒有寫入」，而這則根本沒有動到檔案。
    @State private var applyRefusal: String?
    /// 套用跑完之後 `HumanEventRenderer` 產的那幾行，**逐行照原樣**。
    @State private var applyReport: String?
    /// `hotkeys.json` 的編輯器。沒接上就是 nil，側欄那一行不出現。
    @State private var hotkeys: HotkeyEditor?
    /// 格線那一頁。**寫的是 `hotkeys.json` 的另一個鍵**，所以它與 `hotkeys` 是
    /// 兩個 editor、兩個 dirty、兩次 ⌘S——兩邊各自「重讀整份、只換自己那幾個欄位」
    /// 才是它們不互相洗掉的原因（`HotkeyEditor.loadedDocument` 記過同一件事）。
    @State private var gridSettings: GridSettingsEditor?

    public init(controller: EditorController, hotkeys: HotkeyEditor? = nil,
                gridSettings: GridSettingsEditor? = nil)
    {
        _controller = State(initialValue: controller)
        _hotkeys = State(initialValue: hotkeys)
        _gridSettings = State(initialValue: gridSettings)
    }

    public var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 160, ideal: 200)
        } detail: {
            detail
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("復原") { controller.undo() }
                    .keyboardShortcut("z")
                    .disabled(!controller.canUndo)
            }
            ToolbarItem(placement: .primaryAction) {
                // 這個視窗不是 `NSDocument`，所以標題列沒有系統的修改指示器
                // （關窗那顆鈕上的圓點）。dirty 不寫進按鈕上，使用者就沒有地方看得到。
                //
                // **存哪一份看側欄選到誰**：側欄那幾份檔與 layout.json 各是一份、各有兩個
                // dirty，一顆 ⌘S 寫死其中一份的話，另一份就永遠存不了。
                Button(saveTitle) { save() }
                    .keyboardShortcut("s")
                    .disabled(!canSaveNow)
            }
            // 停用的依據是**選取**而不是 profile 本身。2026-08-30 之前的理由是
            // 「`applyReadiness` 要 location 與 profile 兩個值」，而 ⌘R 改跑
            // `SpaceLayout` 之後它一個參數都不收——這個閘門於是變成純粹的意圖確認：
            // ⌘R 會搬真的視窗，站在規則總表或地點那兩種選取上按到它是誤觸。
            // 那一格的其餘部分在 `ApplyButton.swift`（跨檔案的 extension 看不見
            // `private`，見它的檔頭）。
            ApplyToolbarItem(applying: applying,
                             hasTarget: selectedProfileTarget != nil,
                             action: applyLayout)
        }
        .saveAlerts(problems: $problems, externalChange: $externalChange,
                    onOverwrite: overwrite)
        // 第三則。**沒有併進上面那個 `problems`**：這則講的是「剛才那一步編輯沒生效」
        // 而不是「沒有寫入」，標題與時機都不同；而要併就得多一個 observer 把
        // `lastRejection` 抄進 `problems`（`@Observable` 的欄位不能當 `@State` 的來源），
        // 那比多六行 alert 複雜。訊息與「該不該出聲」都在 `EditorController`，
        // 這裡只有顯示與按掉——判斷不寫進這一層（它零測試）。
        .alert("這一步沒有生效", isPresented: Binding(
            get: { controller.lastRejection != nil },
            set: {
                if !$0 {
                    controller.acknowledgeRejection()
                }
            }
        )) {
            Button("知道了") { controller.acknowledgeRejection() }
        } message: {
            Text(verbatim: controller.lastRejection ?? "")
        }
        .alert("順手改了樹", isPresented: Binding(
            get: { controller.notice != nil },
            set: {
                if !$0 {
                    controller.acknowledgeNotice()
                }
            }
        )) {
            Button("知道了", role: .cancel) { controller.acknowledgeNotice() }
        } message: {
            Text(controller.notice ?? "")
        }
        .applyAlerts(refusal: $applyRefusal, report: $applyReport)
    }

    /// 側欄。**地點自己是一個 row 而不是 Section 的標題**：標題在 `List(selection:)`
    /// 裡選不到，而地點的 desc、螢幕角色與 profile 清單都得有地方編。
    private var sidebar: some View {
        VStack(spacing: 0) {
            List(selection: $selection) {
                Label("視窗規則（\(controller.document?.allRules.count ?? 0)）",
                      systemImage: "list.bullet")
                    .tag(Selection.rules)
                if hotkeys != nil {
                    Label("快捷鍵", systemImage: "keyboard")
                        .tag(Selection.hotkeys)
                }
                if gridSettings != nil {
                    Label("格線", systemImage: "square.grid.3x3")
                        .tag(Selection.grid)
                }
                ForEach(EditorSidebar.rows(of: controller)) { row in
                    if let profile = row.profile {
                        Text(profile)
                            .padding(.leading, 14)
                            .tag(row.selection)
                    } else {
                        locationRow(row.location)
                    }
                }
            }
            Divider()
            addLocationBar
        }
    }

    private func locationRow(_ location: String) -> some View {
        // 停用的依據是 Model 的守衛（`locationDeletionRefusal`），不是這裡自己數。
        let refusal = controller.document?.locationDeletionRefusal(location)
        return Label(location, systemImage: "building.2")
            .tag(Selection.location(location))
            .contextMenu {
                Button("刪除地點", role: .destructive) { delete(location) }
                    .disabled(refusal != nil)
                    .help(refusal ?? "刪掉這個地點，連同它底下的 profile 與 trees。⌘Z 救得回來。")
            }
    }

    /// 刪除沒有二次確認：⌘Z 救得回來，而且沒有寫檔。**但選取要換掉**——它記的是
    /// 剛被刪掉的那個地點，留著會讓 detail 停在一個不存在的東西上。
    private func delete(_ location: String) {
        controller.apply { $0.deletingLocation(location) }
        if selection == .location(location) {
            selection = .rules
        }
    }

    private var addLocationBar: some View {
        HStack {
            Button("＋ 新增地點") { addingLocation = true }
                .buttonStyle(.borderless)
                .popover(isPresented: $addingLocation, arrowEdge: .top) {
                    // 表單自己帶四個欄位的狀態，這裡只收「建好了」：關掉 popover 並
                    // 把側欄選過去（選取是這個 struct 的狀態，那邊拿不到）。
                    AddLocationForm(controller: controller) { name in
                        addingLocation = false
                        selection = .location(name)
                    }
                }
            Spacer()
        }
        .padding(8)
    }

    @ViewBuilder private var detail: some View {
        if let document = controller.document {
            switch selection {
            case .rules:
                RulesDetail(controller: controller, document: document)
            case .hotkeys:
                if let hotkeys {
                    HotkeyView(editor: hotkeys)
                } else {
                    ContentUnavailableView("沒接上快捷鍵設定", systemImage: "keyboard")
                }
            case .grid:
                if let gridSettings {
                    GridSettingsView(editor: gridSettings)
                } else {
                    ContentUnavailableView("沒接上格線設定", systemImage: "square.grid.3x3")
                }
            case let .location(location):
                LocationView(controller: controller, document: document, location: location,
                             onRenamed: { selection = .location($0) })
            case let .profile(location, profile):
                CanvasView(controller: controller, document: document,
                           location: location, profile: profile)
            case nil:
                ContentUnavailableView("左邊挑一個", systemImage: "sidebar.left")
            }
        } else {
            ContentUnavailableView("讀不到設定", systemImage: "exclamationmark.triangle")
        }
    }

    /// 側欄選在某個 profile 時的那兩個名字，其餘選取回 nil。**按鈕的停用與這支共用
    /// 同一個條件**：分成兩份寫的話，一個回 nil 而按鈕仍可按的組合就是一顆按下去
    /// 什麼都不做的按鈕，而這一層沒有測試看得到。
    private var selectedProfileTarget: (location: String, profile: String)? {
        if case let .profile(location, profile) = selection {
            return (location, profile)
        }
        return nil
    }

    /// ⌘R。**順序不准改**：先問 readiness，不是 `.ready` 就講理由並結束，是 `.ready`
    /// 才出確認框，選了「套用」才真的下命令。倒過來（先確認再問）等於讓使用者確認
    /// 一件根本做不到的事。
    @MainActor private func applyLayout() {
        // 值用不到了（`applyReadiness` 不收參數），但「有沒有選在 profile 上」
        // 仍然是這顆按鈕的閘門——理由見上面 toolbar 那一格的註解。
        guard selectedProfileTarget != nil else { return }
        applying = true
        defer { applying = false }
        let readiness = controller.applyReadiness()
        guard case .ready = readiness else {
            applyRefusal = Self.refusalText(readiness)
            return
        }
        guard Self.confirmed() else { return }
        guard let run = controller.applyNow(readiness) else {
            applyRefusal = "沒有套用，而且原因不在上面那幾條——這是 bug。"
            return
        }
        applyReport = Self.reportText(run)
    }

    /// 側欄選在哪一份「不是 layout.json」的檔上，nil ＝ 版面設定那一邊。
    ///
    /// **`.map` 而不是 `!= nil` 再解一次**：沒接上那個 editor 的時候側欄根本不會
    /// 出現那一列，但這裡不靠那個假設——回 nil 就落回 `controller`，與
    /// `selection == .hotkeys && hotkeys != nil` 的答案逐字相同。
    private var sidePage: SideFilePage? {
        switch selection {
        case .hotkeys: hotkeys.map(SideFilePage.hotkeys)
        case .grid: gridSettings.map(SideFilePage.grid)
        default: nil
        }
    }

    private var saveTitle: String {
        isDirtyHere ? "儲存（未存）" : "儲存"
    }

    /// 現在這一頁有沒有未存的編輯。每一份檔案各有自己的 dirty（`hotkeys.json`
    /// 那兩頁寫同一個檔，但它們是兩個 editor，見 `gridSettings` 的註解）。
    private var isDirtyHere: Bool {
        sidePage?.isDirty ?? controller.isDirty
    }

    private var canSaveNow: Bool {
        sidePage?.canSave ?? controller.canSave
    }

    private func save() {
        // 那幾份「沒有 force」的檔案各自把結果翻成話（`SideFilePage.save`）。
        // **這個分支不能省**：省掉的話格線那一頁的 ⌘S 會掉到下面那行去存
        // `layout.json`，而畫面上不會有任何一句話說錯了。
        if let sidePage {
            problems = sidePage.save()
            return
        }
        show(controller.save())
    }

    /// 只有這條路徑帶 `force`，而它的唯一入口是那個 alert 上使用者親手按的按鈕。
    private func overwrite() {
        externalChange = false
        show(controller.save(force: true))
    }

    private func show(_ outcome: SaveOutcome) {
        switch outcome {
        case .written:
            problems = []
        case let .blockedByValidation(found):
            // `"\($0)"` 印的是 Swift 的 enum 語法（實測 `missingField("home.desc")`），
            // 那串跳在中文對話框裡。`LayoutProblem.text` 就是為了這個而放在 Domain 的
            // （`LayoutValidator.swift:357-361`），與 `--json` 和 CLI 講同一句話。
            problems = found.map(\.text)
        case .blockedByExternalChange:
            externalChange = true
        case let .failed(message):
            problems = [message]
        }
    }
}
