import Testing
import WorkmodeCore
import WorkmodeDomain
import WorkmodeEditorControl
import WorkmodeEditorModel

private let path = "/x/scripts/layout.json"

/// 通過 validate 的最小設定（實測 rc=0、零輸出）。
private let good = #"{"windows":[],"home":{"desc":"家","displays":{"main":"A"},"# +
    #""profiles":{"開發":{"trees":{}}}}}"#

/// 缺 desc。實測 `! layout.json 缺欄位：home.desc（要非空字串）`、rc=1。
private let invalid = #"{"windows":[],"home":{"displays":{"main":"A"},"# +
    #""profiles":{"開發":{"trees":{}}}}}"#

/// 與 `good` 同一份，只是共用層真的有一條規則。
///
/// **`good` 的 `windows` 是空陣列，所以 index 0 那條規則不存在**，而 `RuleEdit`
/// 對走不通的路徑是回傳原文件不變（`RuleEdit.swift:24-29`）——拿它驗 undo 會得到
/// 「改了但文件沒變」，`document != before` 那條斷言就分不出「undo 有效」與
/// 「這次編輯根本沒發生」。凡是要看到編輯結果的測試都用這一份。
///
/// 三種狀態都實測過 `__diff validate` rc=0、零輸出：原始的 `甲`、改成 `改過`、
/// 改成 `第0`（歷史上限那條會連改 60 次）。
private let oneRule = #"{"windows":[{"label":"甲","match":["app","A"]}],"# +
    #""home":{"desc":"家","displays":{"main":"A"},"# +
    #""profiles":{"開發":{"trees":{}}}}}"#

/// `windows` 的第 0 筆是**純量**，第 1 筆是正常規則。
///
/// 純量那筆是「表格畫得出來、但編不動」的唯一形狀：`LayoutDocument.rows` 不丟掉任何
/// 一列（`LayoutDocument.swift:191-198`），所以使用者看得到它、會在上面打字；而
/// `settingRuleField` 的路徑走到 `.key("label")` 時那裡是字串，`JSONPath` 丟
/// `shapeMismatch`，`RuleEdit` 吞成原文件不變。**validator 對它完全不出聲**
/// （`__diff validate` 實測 rc=0 零輸出——`jqMapLabel` 只收物件與 null，其餘讓整個
/// 串流中止），下面 `aRejectionIsClearedBySaving` 那條 `save() == .written` 就是這件事
/// 的斷言：這份檔真的存得下去。
///
/// 兩筆一起放是為了同一份 fixture 能做「拒絕」與「成功」兩條路徑：index 0 必被拒、
/// index 1 必成功。
private let scalarThenRule = #"{"windows":["糟糕",{"label":"甲","match":["app","A"]}],"# +
    #""home":{"desc":"家","displays":{"main":"A"},"# +
    #""profiles":{"開發":{"trees":{}}}}}"#

/// 共用層一條規則，而且**有一棵樹在用它**——刪掉那條規則必定連帶拿掉一個窗格。
///
/// `oneRule` 的 `trees` 是空的，拿它驗不出「有沒有出聲」：沒有窗格被拿掉時
/// `notice` 本來就該是 nil，那條斷言分不出「順序寫反了」與「這次真的沒東西可拿」。
///
/// 兩種狀態都實測過（2026-08-26）：原始的 `workmode validate` rc=0 零輸出；
/// 刪掉 `windows[0]` 而不動樹則是
/// `home.開發.trees.main：window「甲」不在生效的 windows 清單裡`、rc=1。
private let ruleWithTree = #"{"windows":[{"label":"甲","match":["app","A"]}],"# +
    #""home":{"desc":"家","displays":{"main":"A"},"# +
    #""profiles":{"開發":{"trees":{"main":{"window":"甲"}}}}}}"#

private func editor(_ store: Store) -> EditorController {
    EditorController(files: store, layoutPath: path)
}

@Test func loadingReadsTheFile() throws {
    let store = Store(files: [path: good + "\n"])
    let controller = editor(store)
    try controller.load()

    #expect(controller.document != nil)
    #expect(controller.canSave)
    #expect(controller.locations == ["home"])
}

/// 讀不懂的檔不讓存：編輯器沒解析成功的東西不該由它寫回去。
@Test func loadingAnUnparseableFileLeavesItUnsavable() {
    let store = Store(files: [path: "{not json"])
    let controller = editor(store)

    #expect(throws: (any Error).self) { try controller.load() }
    #expect(controller.canSave == false)
    #expect(controller.save() != .written)
    #expect(store.writes.isEmpty)
}

/// 存檔走 `writeAtomically` 而不是 `write`：中途失敗不能留下半份設定。
/// 兩條路徑在「檔案內容變了」這件事上看起來一樣，所以要斷言走了哪一支。
@Test func savingUsesTheAtomicWrite() throws {
    let store = Store(files: [path: good + "\n"])
    let controller = editor(store)
    try controller.load()

    #expect(controller.save() == .written)
    #expect(store.writes.count == 1)
    #expect(store.writes[0].atomic == true)
}

/// 連續存兩次都要成功。這條釘的是 `loadedText` 的記帳：存完之後那個基準必須等於
/// **檔案上實際的內容**（含 `FileStore` 補的結尾換行）。少算一個位元組，第二次存檔
/// 就會被自己的外部變更閘門擋下來，而使用者什麼都沒做——那種假警報沒有別的測試看得到。
@Test func savingTwiceInARowIsNotAnExternalChange() throws {
    let store = Store(files: [path: good + "\n"])
    let controller = editor(store)
    try controller.load()

    #expect(controller.save() == .written)
    #expect(controller.save() == .written)
    #expect(store.writes.count == 2)
}

/// 第一道閘門：驗證不過就不寫。
@Test func validationFailureBlocksTheWrite() throws {
    let store = Store(files: [path: invalid + "\n"])
    let controller = editor(store)
    try controller.load()

    guard case let .blockedByValidation(problems) = controller.save() else {
        Issue.record("預期被驗證擋下")
        return
    }
    #expect(!problems.isEmpty)
    #expect(store.writes.isEmpty, "被擋下時一個位元組都不該寫出去")
}

/// 第二道閘門：檔案在我們手上時被別人改了。這在本機是常態——使用者會手改
/// layout.json，`--save` 也會寫它。沒有這道，編輯器開著的期間手改的東西會被靜默蓋掉。
@Test func anExternalChangeBlocksTheWrite() throws {
    let store = Store(files: [path: good + "\n"])
    let controller = editor(store)
    try controller.load()

    store.files[path] = #"{"windows":[]}"# + "\n" // 別人整份換掉了

    #expect(controller.save() == .blockedByExternalChange)
    #expect(store.writes.isEmpty)
}

/// 第二道閘門的失敗側：讀不到現況就不寫。這條與上面那條是同一道閘門的兩種輸入，
/// 但少了它，「讀失敗」會與「檔案不存在」走同一條路（`try?` 兩者都給 nil）而**跳過**
/// 整道閘門——在最不知道會蓋掉什麼的時候直接寫下去。
@Test func anUnreadableFileBlocksTheWrite() throws {
    let store = Store(files: [path: good + "\n"])
    let controller = editor(store)
    try controller.load()
    store.unreadablePaths = [path] // 載入之後才變成讀不到（權限、I/O 錯）

    guard case .failed = controller.save() else {
        Issue.record("預期回報讀不到現況")
        return
    }
    #expect(store.writes.isEmpty, "讀不到現況時一個位元組都不該寫出去")
}

/// 使用者選了「用我的蓋過去」之後，同一次存檔要成功。
@Test func savingCanBeForcedPastAnExternalChange() throws {
    let store = Store(files: [path: good + "\n"])
    let controller = editor(store)
    try controller.load()
    store.files[path] = #"{"windows":[]}"# + "\n"

    #expect(controller.save(force: true) == .written)
    #expect(store.writes.count == 1)
}

/// 第三道：寫檔本身失敗。回報而不是吞掉，而且**檔案要保持原樣**——
/// 原子寫存在的整個理由就是不留半份。
@Test func aFailedWriteIsReportedAndLeavesTheFileAlone() throws {
    let store = Store(files: [path: good + "\n"])
    let controller = editor(store)
    try controller.load()
    store.failWrites = true

    guard case .failed = controller.save() else {
        Issue.record("預期回報寫檔失敗")
        return
    }
    #expect(store.files[path] == good + "\n")
    #expect(store.writes.isEmpty)
}

@Test func editingMarksDirtyAndSavingClearsIt() throws {
    let store = Store(files: [path: oneRule + "\n"])
    let controller = editor(store)
    try controller.load()
    #expect(controller.isDirty == false)

    // `edit` 的**正控制組**：真的改到東西時回 true。少了它，
    // `anEditThatChangesNothingIsNotRecorded` 可以靠一個「永遠回 false」的實作滿足。
    let applied = controller.edit {
        $0.settingRuleField(.shared, index: 0, field: .label, to: "改過")
    }
    #expect(applied)
    #expect(controller.isDirty)
    #expect(controller.lastRejection == nil)

    #expect(controller.save() == .written)
    #expect(controller.isDirty == false)
}

/// undo 是整份快照。設計稿的理由：反向操作要為每個動作各寫一支，而每一支都是
/// 新的錯誤來源；整份設定 118 行，存快照是一行。
@Test func undoRestoresThePreviousDocument() throws {
    let store = Store(files: [path: oneRule + "\n"])
    let controller = editor(store)
    try controller.load()
    let before = controller.document

    controller.apply { $0.settingRuleField(.shared, index: 0, field: .label, to: "改過") }
    #expect(controller.document != before)
    #expect(controller.canUndo)

    controller.undo()
    #expect(controller.document == before)
    #expect(controller.canUndo == false)
}

/// 存檔失敗**不得**清掉 dirty——清了使用者就失去「我還有沒存的東西」這個訊號。
@Test func aFailedSaveKeepsDirtySet() throws {
    let store = Store(files: [path: oneRule + "\n"])
    let controller = editor(store)
    try controller.load()
    controller.apply { $0.settingRuleField(.shared, index: 0, field: .label, to: "改過") }
    store.failWrites = true

    guard case .failed = controller.save() else {
        Issue.record("預期寫檔失敗")
        return
    }
    #expect(controller.isDirty)
}

/// 被閘門擋下來也一樣不清。
@Test func aBlockedSaveKeepsDirtySet() throws {
    let store = Store(files: [path: oneRule + "\n"])
    let controller = editor(store)
    try controller.load()
    controller.apply { $0.settingRuleField(.shared, index: 0, field: .label, to: "改過") }
    store.files[path] = #"{"windows":[]}"# + "\n"

    #expect(controller.save() == .blockedByExternalChange)
    #expect(controller.isDirty)
}

/// 上限 50 步：超過就丟掉最舊的，不是拒絕記錄。
@Test func theHistoryStopsAtFiftyAndDropsTheOldest() throws {
    let store = Store(files: [path: oneRule + "\n"])
    let controller = editor(store)
    try controller.load()
    var tenth: LayoutDocument?
    for step in 0 ..< 60 {
        controller.apply {
            $0.settingRuleField(.shared, index: 0, field: .label, to: "第\(step)")
        }
        // 前 10 步被擠掉之後，undo 到底就停在這一份。
        if step == 9 {
            tenth = controller.document
        }
    }
    var count = 0
    while controller.canUndo {
        controller.undo()
        count += 1
    }
    #expect(count == 50)
    // **只數步數分不出「丟最舊的」與「丟最新的」。** `history.append` 之後才判上限，
    // 所以 `removeLast()` 丟的正是剛存進去的那一份，歷史一樣恰好停在 50 筆——
    // 2026-08-19 實測那個突變全綠。兩者的差別只在 undo 到底落在哪一份文件上：
    // 丟最舊的會停在第 10 次編輯的結果，丟最新的（或拒絕記錄）會停在載入時的原文。
    #expect(controller.document == tenth)
}

/// **沒有生效的編輯不算一步。** 三重靜默的第一與第二重：文件沒變、`isDirty` 照樣
/// 被設成 true、undo 多一步什麼都不還原的按鈕。第三重（表格那一格留著使用者打的字）
/// 在 `RuleTableView`，靠 `edit` 的回傳值退回本地緩衝。
///
/// 這不是假想的輸入：純量 entry 使用者看得到（表格是唯一看得到它的地方）也編得動
/// 畫面，而存下去檔案一個位元組都沒變。
@Test func anEditThatChangesNothingIsNotRecorded() throws {
    let store = Store(files: [path: scalarThenRule + "\n"])
    let controller = editor(store)
    try controller.load()
    let before = controller.document

    let applied = controller.edit {
        $0.settingRuleField(.shared, index: 0, field: .label, to: "改過")
    }
    #expect(applied == false)
    #expect(controller.isDirty == false)
    #expect(controller.canUndo == false)
    #expect(controller.document == before)
    // 而且要出聲。這是六個按鈕（走 `apply`，沒有回傳值可看）唯一的訊號來源。
    #expect(controller.lastRejection != nil)
}

/// `apply` 是 Void 的那個入口，拒絕一樣要出聲——否則 `RuleTableView` 那六個按鈕
/// （`addingFallback`／`removingFallback`／上／下／刪／新增）按下去仍然是全靜默的。
@Test func applyAlsoReportsARejectedEdit() throws {
    let store = Store(files: [path: scalarThenRule + "\n"])
    let controller = editor(store)
    try controller.load()

    controller.apply { $0.addingFallback(.shared, index: 0) }
    #expect(controller.lastRejection != nil)
    #expect(controller.isDirty == false)
    #expect(controller.canUndo == false)
}

/// 那句話會過去：下一次成功的編輯、按掉它、重新載入、存檔，四條路徑都清。
/// 不清的話 alert 會在下一次成功的編輯之後又跳出來，講一件已經不成立的事。
@Test func aRejectionIsClearedByEverySubsequentPath() throws {
    let store = Store(files: [path: scalarThenRule + "\n"])
    let controller = editor(store)

    func reject() throws {
        controller.apply { $0.settingRuleField(.shared, index: 0, field: .label, to: "X") }
        #expect(controller.lastRejection != nil)
    }

    try controller.load()
    try reject()
    controller.acknowledgeRejection()
    #expect(controller.lastRejection == nil)

    try reject()
    // index 1 是正常那筆，這次真的改到東西。
    controller.apply { $0.settingRuleField(.shared, index: 1, field: .label, to: "乙") }
    #expect(controller.lastRejection == nil)

    try reject()
    try controller.load()
    #expect(controller.lastRejection == nil)

    try reject()
    // 純量 entry 的那份檔真的存得下去（validator 對它零輸出），所以這條走得到
    // `.written` 而不是被閘門擋在半路。
    #expect(controller.save() == .written)
    #expect(controller.lastRejection == nil)
}

/// 重新載入把歷史清掉：undo 到「上一份檔案的狀態」是沒有意義的。
@Test func loadingClearsTheHistory() throws {
    let store = Store(files: [path: oneRule + "\n"])
    let controller = editor(store)
    try controller.load()
    controller.apply { $0.settingRuleField(.shared, index: 0, field: .label, to: "改過") }
    try controller.load()
    #expect(controller.canUndo == false)
    #expect(controller.isDirty == false)
}

/// **問的必須是刪之前的那份文件。**
///
/// 守衛不在「那兩行的順序」——`deleteRule` 先 `guard let current = document` 抓一份
/// 快照再問它，而 `LayoutDocument` 是值型別，`apply` 改不到 `current`。所以把那兩行
/// 對調是**沒有可觀測差異**的（2026-08-26 實測：對調之後 947 條全綠）。
///
/// 真正的守衛是「問的是 `current` 而不是 `document`」。把它改成刪完之後才問
/// `document`，這一條就紅（2026-08-26 實測，2 個 issue）——而那個寫法看起來完全合理，
/// 「沒有窗格被拿掉」與「問錯了那份文件」在畫面上逐字相同。
@Test func deletingARuleThatOwnsAPaneSaysSo() throws {
    let store = Store(files: [path: ruleWithTree + "\n"])
    let controller = editor(store)
    try controller.load()
    controller.deleteRule(.shared, index: 0)
    #expect(controller.notice != nil)
    #expect(controller.notice?.contains("main") == true)
}

/// 沒有樹在用的規則刪掉**不出聲**。與上面那條走同一個 `deleteRule`，
/// 所以它同時擋住「一律出聲」那種實作。
@Test func deletingARuleNobodyUsesSaysNothing() throws {
    let store = Store(files: [path: oneRule + "\n"])
    let controller = editor(store)
    try controller.load()
    controller.deleteRule(.shared, index: 0)
    #expect(controller.notice == nil)
}

/// 沒接上 yabai 就回空陣列。**空陣列而不是 nil**：呼叫端要顯示的是一份清單，
/// 「查不到」與「一台視窗都沒開」在畫面上是同一件事，而 UI 那層零測試——
/// 多一個 Optional 只是多一個它會猜錯的分支（與 `connectedDisplays` 同一條）。
@Test func windowsAreEmptyWhenNothingIsWired() throws {
    let store = Store(files: [path: good + "\n"])
    let controller = editor(store)
    try controller.load()
    #expect(controller.connectedWindows().isEmpty)
}

/// 接上了就照傳。這一條的鑑別力在「不是空的」——回 `[]` 的實作會紅。
@Test func windowsComeStraightFromTheClosure() throws {
    let store = Store(files: [path: good + "\n"])
    let controller = EditorController(
        files: store, layoutPath: path,
        windows: { [WindowChoice(id: "1", app: "Zed", title: "x",
                                 tabURL: nil, tabTitle: nil)] }
    )
    try controller.load()
    #expect(controller.connectedWindows().map(\.app) == ["Zed"])
}
