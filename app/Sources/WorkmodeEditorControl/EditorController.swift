import Observation
import WorkmodeCore
import WorkmodeDomain
import WorkmodeEditorModel
import WorkmodeWire

/// 編輯器的 C。用 `@Observable` 而不是 `ObservableObject`：後者要 Combine，
/// 而這一層的架構斷言禁 SwiftUI／AppKit——Observation 兩者都不是。
///
/// 對外一律走 port（這裡只有 `FileStore`），所以測得到：測試給一個假的 store 就能
/// 驗完三道閘門，不必碰真的檔案系統——更不必碰使用者正在用的 `scripts/layout.json`。
@Observable
public final class EditorController {
    public private(set) var document: LayoutDocument?
    /// 載入成功才准存。讀不懂的檔不該由編輯器寫回去。
    public private(set) var canSave = false
    /// 有沒有還沒寫回磁碟的編輯。存檔**成功**才清，其餘路徑一律留著。
    public private(set) var isDirty = false
    /// 最後一次**沒有生效**的編輯要說的話，nil ＝ 沒有這種事。
    ///
    /// **判斷與措辭都放這裡不放 view**：`WorkmodeEditorUI` 零測試
    /// （`DependencyRuleTests` 的三條禁令就是為了讓判斷寫不進去），而「該不該出聲」
    /// 寫錯的症狀正好就是靜默——那是這個欄位存在的整個理由。view 只做兩件事：
    /// 非 nil 就顯示，使用者按掉就呼叫 `acknowledgeRejection()`。
    public private(set) var lastRejection: String?

    /// 上一次的刪除連帶拿掉了哪些窗格。**判斷與措辭都在這一層**，與 `lastRejection`
    /// 同一條理由：`WorkmodeEditorUI` 零測試，而「該不該出聲」寫錯的症狀正好就是靜默。
    ///
    /// 它與 `lastRejection` 不會同時非 nil：`edit` 成功時把 rejection 清成 nil，
    /// 而沒生效時 `panesAffectedByDeleting` 回空清單（它對「刪不動」也回空）。
    public private(set) var notice: String?

    public var canUndo: Bool {
        !history.isEmpty
    }

    /// 載入當下的原文。存檔前重讀一次比對它，就知道檔案有沒有被別人改過。
    /// 存 hash 也可以，但這份檔 118 行，直接比字串更簡單也更精確。
    private var loadedText: String?

    /// 整份快照，上限 50 步。反向操作要為每個動作各寫一支，而每一支都是新的錯誤
    /// 來源；這份設定 118 行，存快照是一行 `history.append`。
    private var history: [LayoutDocument] = []
    private static let historyLimit = 50

    private let files: any FileStore
    private let layoutPath: String

    /// 由 `WorkmodeCLI` 注入：它帶著真的 adapters 組好 `SpaceLayout`，再把「跑一次」
    /// 包成閉包交進來。nil 代表這個 controller 不能套用。
    ///
    /// **收閉包而不是收 7 個協定**：那 7 個的具體實作全在 `WorkmodeAdapters`，
    /// 而這一層不准 import 它。同一招 `ApplyLayout` 自己就在用——它的 `parse:` 與
    /// `renderRaw:` 是閉包，理由逐字寫在它的 doc 裡（`ApplyLayout.swift:57-62`）。
    ///
    /// **2026-08-30 之前跑的是 `ApplyLayout`**（走 `trees`，會聚集視窗並流放陌生
    /// 視窗）。編輯器現在編的是 `spaceTrees`，按 ⌘R 套一棵他沒在編的樹是說謊。
    ///
    /// **沒有 mode 參數**：`SpaceLayout` 沒有 probe 模式，而我們刻意不加一個
    /// （見 `ApplyReadiness` 與 `ApplyButton.confirmed`）。唯一的參數是 want，
    /// 空字串＝照設定決定 profile，與 `runSpaceLayout(want: "")` 一致。
    private let runLayout: ((String) -> ApplyRun)?

    /// 同樣由 `WorkmodeCLI` 注入，理由與 `runLayout` 同一條：問 yabai 現在接著哪些螢幕
    /// 要 `YabaiClient` 的實作，而**螢幕的名字 yabai 給不出來**（它的 `label` 是使用者
    /// 自己貼的，實測三台都是空字串），要問 `NSScreen`——兩者的實作都住在
    /// `WorkmodeAdapters`，合併在 `DisplayChoice.merge`。
    /// nil 代表沒接上——那與「一台都沒查到」在畫面上是同一件事，見 `connectedDisplays()`。
    /// **沒有 `private`**：讀它們的 `spaceOptions(displayUUID:named:)` 住在
    /// `SpaceLookup.swift`（這個檔差幾行就撞上 swiftlint 的 400 行門檻，而那個參數
    /// 不准調），而 `private` 是同檔可見——搬出去就讀不到。與下面的 `windows` 同一條。
    let displays: (() -> [DisplayChoice])?
    let spaces: (() -> [LiveSpace])?

    /// 現在開著哪些視窗（含 Safari 當前分頁的網址）。理由與 `displays` 同一條：
    /// 問 yabai 要 `YabaiClient`、問 Safari 要 `SafariClient`，兩個實作都住在
    /// `WorkmodeAdapters`，而這一層不准 import 它。
    ///
    /// **沒有 `private`**：讀它的 `connectedWindows()` 住在 `WindowLookup.swift`
    /// （`EditorController.swift` 差一行就撞上 swiftlint 的 400 行門檻，而那個參數
    /// 不准調），而 `private` 是同檔可見——搬出去就讀不到。
    let windows: (() -> [WindowChoice])?

    public init(files: any FileStore,
                layoutPath: String,
                runLayout: ((String) -> ApplyRun)? = nil,
                displays: (() -> [DisplayChoice])? = nil,
                spaces: (() -> [LiveSpace])? = nil,
                windows: (() -> [WindowChoice])? = nil)
    {
        self.files = files
        self.layoutPath = layoutPath
        self.runLayout = runLayout
        self.displays = displays
        self.spaces = spaces
        self.windows = windows
    }

    /// 現在接著哪些螢幕。**回空陣列而不是 nil**：呼叫端要顯示的是一份清單，
    /// 「查不到」與「一台都沒有」在畫面上都是同一件事（沒東西可挑），
    /// 而 UI 那側零測試，多一個 Optional 只是多一個它會猜錯的分支。
    public func connectedDisplays() -> [DisplayChoice] {
        displays?() ?? []
    }

    /// ⌘R 按下去先問這個。
    ///
    /// **先存檔才准跑**：`SpaceLayout` 用 `files` port 從**磁碟**讀 `layout.json`，
    /// 它不知道編輯器記憶體裡有什麼——帶著未存的編輯按下去會套用舊檔。
    ///
    /// **不比對地點了。** 2026-08-30 之前這裡會先跑一次 `ApplyLayout` 的 probe 去問
    /// 「現在偵測到哪個地點」，再與正在編的那個比對；`SpaceLayout` 沒有 probe 模式，
    /// 而我們刻意不加一個（`ApplyReadiness` 的 doc 寫了為什麼）。
    public func applyReadiness() -> ApplyReadiness {
        guard runLayout != nil else { return .notWired }
        guard !isDirty else { return .notSaved }
        return .ready
    }

    /// 真的套用。**會搬動使用者真的視窗。**
    ///
    /// 收一個 `ApplyReadiness` 而不是自己再算一次：UI 那側剛剛才問過。
    /// `isDirty` 仍然重新檢查一次（確認框是 modal，理論上動不了，但那是「理論上」）。
    ///
    /// **不是 `.ready` 就一個 command 都不下**——`applyingWithoutReadinessDoesNothing`
    /// 釘住這件事，而它的鑑別力是「fake 的呼叫紀錄是空的」，不是「回 nil」。
    public func applyNow(_ readiness: ApplyReadiness) -> ApplyRun? {
        guard readiness == .ready, !isDirty, let runLayout else { return nil }
        // 空字串＝照設定決定 profile，與 `runSpaceLayout(want: "")` 一致。
        return runLayout("")
    }

    public var locations: [String] {
        document?.locations ?? []
    }

    /// 檔案不存在時 `read` 回 nil，這裡當成空字串交給 parser——它要求恰好一個值，
    /// 所以空的會拋。那是刻意的：bash 的 `jq empty` 對空輸入 rc=0（一份讀不到的設定
    /// 靜默通過驗證），CLAUDE.md 記著這是移植時刻意不對齊的三個分歧之一。
    public func load() throws {
        let text = try files.read(atPath: layoutPath) ?? ""
        document = try LayoutDocument(root: JSONParser.parse(text))
        loadedText = text
        canSave = true
        // 換了一份檔，undo 到「上一份檔案的狀態」只會把別人的內容寫回去。
        history.removeAll()
        isDirty = false
        // 那句話講的是上一份文件裡的某一列，對新載入的內容不成立。
        lastRejection = nil
    }

    /// 編輯的唯一入口：**真的改到東西才**存快照、換文件、標 dirty。
    ///
    /// `RuleEdit` 對走不通的路徑回傳原文件不變（`RuleEdit.swift:25-29`），而那不是
    /// 假想的——`windows` 裡的**純量** entry（`["糟糕"]`）就是這種：表格畫得出那一列
    /// （`LayoutDocument.rows` 不丟掉任何一列，而 validator 對它完全不出聲），
    /// 使用者於是真的會在上面打字，但每個編輯動作的路徑都會撞到 shapeMismatch。
    /// 記下來的話 undo 會多一步什麼都不還原的按鈕，dirty 會說「有沒存的東西」而
    /// 磁碟上與記憶體裡一個位元組都不差。
    ///
    /// - Returns: 這次編輯有沒有生效。**沒有 `@discardableResult`**：丟掉這個回傳值
    ///   正是它要修的那種靜默。有本地狀態要對帳的呼叫端（表格那一格的緩衝）用這支，
    ///   其餘的用 `apply`——兩個具名入口而不是一個可以忽略的回傳值，理由與
    ///   `JSONPath.set`／`setCreatingMissingObjects` 同一條：合約不同就給不同的名字。
    public func edit(_ transform: (LayoutDocument) -> LayoutDocument) -> Bool {
        guard let current = document else { return false }
        // 比整份文件。`LayoutDocument` 是值型別，`==` 比的是整棵 `JSONValue`
        // （含鍵序與數字字面值），這份檔 118 行。
        let edited = transform(current)
        guard edited != current else {
            lastRejection = Self.rejectionText
            return false
        }
        history.append(current)
        if history.count > Self.historyLimit {
            history.removeFirst()
        }
        document = edited
        isDirty = true
        // 上一次的拒絕已經過去了：留著會讓下一次成功的編輯之後那個 alert 又跳出來。
        lastRejection = nil
        return true
    }

    /// 沒有本地狀態要對帳的呼叫端用這支（`RuleTableView` 的六個按鈕）。
    ///
    /// 存在的理由不是方便：那六個站點各寫一個 `_ =` 等於把「這次沒生效」的靜默
    /// 原封不動留在零測試的那一層，而回傳值一被丟掉就沒有人會回來補。改成走這裡，
    /// 出聲的責任集中在 `lastRejection`，而它測得到。
    public func apply(_ transform: (LayoutDocument) -> LayoutDocument) {
        _ = edit(transform)
    }

    /// 使用者按掉那則說明。清除與設定是同一條規則的兩半，都留在這一層——
    /// 讓 view 直接寫這個欄位的話，「什麼時候該清」就會散到沒有測試的地方去。
    public func acknowledgeRejection() {
        lastRejection = nil
    }

    /// 使用者按掉那則說明。與 `acknowledgeRejection` 同一條：清除與設定都留在這一層。
    public func acknowledgeNotice() {
        notice = nil
    }

    /// 刪一條規則。**UI 只呼叫這支**，不自己組合查詢與動作。
    ///
    /// 順序有意義：先問，再刪。`panesAffectedByDeleting` 讀的是**刪之前**的文件，
    /// 刪完再問會回空清單。
    public func deleteRule(_ scope: RuleScope, index: Int) {
        guard let current = document else { return }
        let removed = current.panesAffectedByDeleting(scope, index: index)
        apply { $0.deletingRule(scope, index: index) }
        notice = Self.sweepNotice(removed)
    }

    /// 那句話。空清單回 nil——刪一條沒人用的規則不該多跳一個對話框。
    ///
    /// 講**幾個**與**在哪**，因為兩者都是使用者從畫面推不出來的：被掃掉的窗格
    /// 散在他沒打開的 profile 與分頁上。分頁的名字一定要在，不然他會以為
    /// 那是「目前可見」那一棵。
    static func sweepNotice(_ panes: [SweptPane]) -> String? {
        guard !panes.isEmpty else { return nil }
        let places = panes.map { pane -> String in
            let page = pane.space.map { "／\($0)" } ?? ""
            return "\(pane.location)／\(pane.profile) \(pane.role)\(page)"
        }.joined(separator: "、")
        return "這條規則有 \(panes.count) 個窗格在用，一起拿掉了：\(places)。"
            + "留著的話 ⌘S 會被擋下——樹裡的每個 window 都必須在生效的 windows 清單裡。"
            + "⌘Z 可以一次還原全部。"
    }

    /// 套一個版面模板。**UI 只呼叫這支**，不自己組合查詢與動作。
    ///
    /// 順序有意義：先問放不放得下（讀的是**套之前**的文件），再套，再數空格。
    ///
    /// 放不下時**先清 `lastRejection`**：它與 `notice` 都會被 `EditorWindow` 接成
    /// alert，兩則同時掛著就是兩個對話框疊起來（`save` 檔頭那條同一個理由）。
    /// 而這條路徑不經過 `edit`，所以沒有人會替它清。
    public func applyTemplate(_ template: PaneTemplate, at path: PanePath) {
        guard let current = document else { return }
        let windows = current.windowLeaves(at: path).count
        guard windows <= template.slotCount else {
            lastRejection = nil
            notice = Self.templateTooSmallNotice(template, windows: windows)
            return
        }
        // **`edit` 而不是 `apply`**：沒有生效時 `edit` 會設 `lastRejection`，
        // 這時候再設 `notice` 就是兩則同時掛著。已經是那個形狀的樹再按一次
        // 就會走到這裡。
        guard edit({ $0.applyingTemplate(template, at: path) }) else { return }
        notice = Self.templateVacancyNotice(template,
                                            vacant: template.slotCount - windows)
    }

    /// 有空格的話那句話。全部填滿回 nil——多一個「一切正常」的對話框只會讓下一則
    /// 被忽略。
    ///
    /// **⌘S 那半是重點**：空的 `{}` 在 `LayoutValidator.splitNodeChecks`
    /// （`LayoutValidator.swift:309`）報「節點既沒有 window 也沒有 axis」，
    /// 而使用者不會自己把「存不了檔」連回剛才按的那顆按鈕。
    static func templateVacancyNotice(_ template: PaneTemplate, vacant: Int) -> String? {
        guard vacant > 0 else { return nil }
        return "已改成\(template.title)，還有 \(vacant) 格未指定。"
            + "把 label 拖進去之前 ⌘S 會被擋下——樹裡的每個節點都要有 window 或 axis。"
    }

    /// 放不下的話那句話。兩個數字都要有：只講「放不下」的話使用者不知道要移掉幾個。
    static func templateTooSmallNotice(_ template: PaneTemplate, windows: Int) -> String {
        "這個版面現在有 \(windows) 個視窗，\(template.title)只放得下 "
            + "\(template.slotCount) 個。先移除幾個，或改用格子多一點的版面。"
    }

    /// 兩種成因都講，因為 `edit` 分不出來——它看到的只有「文件沒變」。
    /// 純量 entry 那條是實測來的：`windows` 裡放 `"糟糕"` 時 `settingRuleField`
    /// 與 `addingFallback` 的路徑都會撞到 `JSONPath.Failure.shapeMismatch`
    /// （走到 `.key("label")` 時那裡是字串），而 `RuleEdit` 把它吞成原文件不變
    /// （`RuleEdit.swift:25-29`）。`__diff validate` 對這種 entry 實測 rc=0 零輸出，
    /// 所以表格是使用者唯一看得到那一列的地方（`LayoutDocument.swift:191-198`）。
    private static let rejectionText =
        "那個動作沒有改到檔案裡的任何東西，所以它沒有被記成一步（復原也不會出現它）。"
            + "成因只有兩種：這一列在檔案裡不是編輯器認得的形狀——例如 windows 裡放的是"
            + "一個純量而不是物件，欄位編輯與 fallback 對它都走不通，而 validate 對這種列"
            + "完全不出聲——或者表格與檔案不同步，那是 bug。前者只能直接編 layout.json。"

    /// undo 之後 `isDirty` 設 true 而不是回推到當時的值：回到最初狀態時檔案內容
    /// 確實與磁碟相同，但要精確追蹤那個需要另存一份「乾淨基準」。**這是刻意的
    /// 保守做法——多存一次無害，少存一次會掉東西。**
    public func undo() {
        guard let previous = history.popLast() else { return }
        document = previous
        isDirty = true
    }

    public func save(force: Bool = false) -> SaveOutcome {
        // 存檔自己有一套 alert（`SaveOutcome`），兩則同時掛著就是兩個對話框疊起來。
        // 先清掉：使用者已經走到存檔了，那句「上一步沒生效」講的事情已經過去。
        lastRejection = nil
        guard canSave, let document else {
            return .failed("沒有載入成功的設定，不寫")
        }

        let problems = LayoutValidator.validate(document.root)
        guard problems.isEmpty else { return .blockedByValidation(problems) }

        if !force {
            let onDisk: String?
            do {
                onDisk = try files.read(atPath: layoutPath)
            } catch {
                // `try?` 會把「讀失敗」與「檔案不存在」併成同一個 nil，兩者都往下寫。
                // 但這道閘門存在的理由就是不要靜默蓋掉使用者手改的內容，而讀不到
                // 現況（權限、I/O 錯）正好是最不該往下寫的那一刻——檔案裡有什麼
                // 完全未知。
                return .failed("讀不到現在的 \(layoutPath)，不知道會蓋掉什麼，所以不寫：\(error)")
            }
            // nil 是「檔案不存在」：那是第一次建立，沒有東西會被蓋掉。
            if let onDisk, onDisk != loadedText {
                return .blockedByExternalChange
            }
        }

        let text = JSONWriter.format(document.root)
        do {
            try files.writeAtomically(text, toPath: layoutPath)
        } catch {
            return .failed("\(error)")
        }
        // `FileStore` 的合約是「寫入這些**行**」，它自己補結尾換行
        // （`FileManagerStore.swift:41`／`:61`），所以下一次比對的基準要含它。
        // 少了它，下一次存檔會被自己的閘門擋下來。
        loadedText = text + "\n"
        // 只有這條路徑清 dirty。上面每個 return 都代表磁碟上還沒有這份編輯，
        // 清了使用者就失去「我還有沒存的東西」這個訊號。
        isDirty = false
        return .written
    }
}
