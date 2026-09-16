import Observation
import WorkmodeDomain

/// 「格線」那一頁的載入與存檔。
///
/// 與 `HotkeyEditor` 共用同一份檔案（`hotkeys.json`），所以**兩個 editor 各自
/// 讀寫整份 `HotkeyDocument`**——只寫自己那個鍵會把另一頁未存的編輯洗掉。
/// 這是既有的形狀：那個檔的 read／write 本來就是整份進整份出，理由寫在
/// `HotkeyDocument` 的 doc 裡（「read/write 少收哪個欄位，那個欄位就會在使用者
/// 按 ⌘S 的那一刻無聲消失」）。
///
/// **`@Observable` 與兩個 sibling 逐字同一條**（`HotkeyEditor`、`YabaircEditor`）：
/// 少了它，stepper 改完 `grids` 之後 SwiftUI 沒有任何理由重畫，於是三個數字與
/// 右邊的預覽都不會動——那不是「不好看」，是這一頁按下去完全沒反應。
@Observable
public final class GridSettingsEditor {
    public private(set) var grids: [String: GridConfig] = [:]
    /// 位置庫。與 `grids` 同一份檔案、同一個 dirty、同一個 ⌘S——分開存的話
    /// 「格數存了、位置庫沒存」這種狀態就會存在，而畫面上兩者長得一樣。
    ///
    /// **編得動的只有名字與快捷鍵**，`spec` 唯讀（見 `renameZone`／`setHotkey`）：
    /// 改它要指一塊矩形，而那件事在面板做得到；讓人在這裡手打 `2:2:5:0:1:1`
    /// 只是多一個沒有畫面回饋的錯誤來源——那六個數字打錯了，畫面上什麼都不會說。
    public private(set) var zones: [GridZone] = []
    public private(set) var isDirty = false
    /// 接上的螢幕（uuid ＋ 給人看的名字），由 CLI 那層查好傳進來
    /// ——Control 不准碰 `NSScreen`／Adapters。
    public private(set) var screens: [(uuid: String, name: String)] = []
    /// 讀到一份**看不懂**的 `hotkeys.json` 時要說的話。nil ＝ 可以存。
    public private(set) var loadFailure: String?

    /// 讀整份文件。**回 nil 代表那個檔在、非空，而它的內容不能拿來覆寫**
    /// ——parse 不過，或者 parse 得過但根本不是一份 hotkeys 文件。
    ///
    /// 「檔案不存在」與「檔案是空的」都要回 `HotkeyDocument.defaults`（非 nil）
    /// ——那兩種是常態（第一次跑，或剛從 skhd 搬過來），把它們一起擋掉等於讓
    /// 使用者永遠存不出第一份檔。四種**必須分得開**：`HotkeyFile.load` 分不開
    /// （它對前三種都回 `defaults`，第四種回一份空文件），照它的答案存下去就是
    /// 拿內建的 45 條綁定與 29 個 float app 蓋掉使用者只是打錯一個字的檔，
    /// 而且是靜默的。分開的那一刀是 `HotkeyFile.readable`——**測得到**的那一層，
    /// 它原本在 `EditCommand`（executable target，零測試）。
    private let load: () -> HotkeyDocument?
    private let store: (HotkeyDocument) throws -> Void
    private let connected: () -> [(uuid: String, name: String)]
    private var hasLoaded = false
    /// 載入時那份文件的**全部**欄位。這一頁只讀它的 `bindings`，而且只為了算撞鍵
    /// （`registrableBindings` ＝ 綁定 ＋ 有快捷鍵的 zone）。`save()` 不用它——
    /// 那一支自己重讀一次，理由寫在它的 doc。
    ///
    /// **它是 `loadOnce()` 那一刻的快照。** 使用者在同一次開著編輯器的期間於
    /// 「快捷鍵」那一頁新增的綁定不會出現在這裡，所以撞鍵那個紅字**可能少報**。
    /// 兩頁各自從磁碟載入是既有的形狀（`HotkeyEditor.loadedDocument` 對 zone
    /// 是反方向的同一件事），而修法是重載，那會把使用者未存的編輯洗掉——
    /// 少報一個警告的代價小得多。存檔不受影響：`save()` 重讀整份再合併。
    private var loadedDocument = HotkeyDocument(bindings: [], floatApps: [])

    public init(load: @escaping () -> HotkeyDocument?,
                store: @escaping (HotkeyDocument) throws -> Void,
                connected: @escaping () -> [(uuid: String, name: String)])
    {
        self.load = load
        self.store = store
        self.connected = connected
    }

    /// **只跑一次**（`hasLoaded`）。detail 是一個 `switch selection`，切走再切回來
    /// view 會重建、`.onAppear` 再跑一次，無條件重載會把未存的編輯連同 `isDirty`
    /// 一起洗掉而畫面上零訊號——與 `YabaircEditor.load()` 逐字同一條。
    public func loadOnce() {
        guard !hasLoaded else { return }
        hasLoaded = true
        // 螢幕清單在 guard **之前**：檔案看不懂的時候那一頁仍然該列得出螢幕，
        // 使用者才看得出來自己在哪一頁、以及那句「為什麼不能存」是對誰說的。
        screens = connected()
        guard let document = load() else {
            loadFailure = Self.unreadable
            return
        }
        loadedDocument = document
        grids = document.grids
        zones = document.zones
    }

    public func set(_ config: GridConfig, forDisplay uuid: String) {
        guard !uuid.isEmpty, grids[uuid] != config else { return }
        grids[uuid] = config
        isDirty = true
    }

    public func config(forDisplay uuid: String) -> GridConfig {
        GridConfig.forDisplay(uuid, in: grids)
    }

    // MARK: - 位置庫

    /// 改名之前先問這一支。**回訊息而不是回 Bool**（先例 `LayoutName.rejection`）：
    /// 兩種拒絕要改的東西不一樣，同一句話等於沒說。
    ///
    /// **不擋名字裡的空白字元**，與 `LayoutName` 相反。那邊擋是因為地點與 profile
    /// 名參與**空白分隔的字串集合比對**（`match_location` 把它們串成一行再切開），
    /// 所以一個含空白的名字會被切成兩個。zone 名字沒有那種消費端——它只用來顯示，
    /// 以及 `removingZone(named:)` 的整串比對，兩者對空白都沒有意見。擋掉「左半 大」
    /// 是替一個不存在的問題付代價。
    ///
    /// **前後的空白仍然修掉**：那種名字在縮圖牆上與沒修過的一模一樣，而它會讓
    /// 撞名判斷失準——使用者看到的是「我明明打了同一個名字，它卻收下了」，
    /// 而收下的後果是刪除一次刪掉兩個。
    ///
    /// `index` 是「正在改名的那個自己」，撞名不算它——改名成自己不算撞名
    /// （`LayoutName.rejection` 的 `existing` 逐字同一條）。
    public func renameRejection(at index: Int, to name: String) -> String? {
        let name = Self.trimmed(name)
        if name.isEmpty {
            return "位置的名字不能是空的——縮圖牆上那一格會看不出是什麼。"
        }
        if zones.enumerated().contains(where: { $0.offset != index && $0.element.name == name }) {
            return "已經有一個叫「\(name)」的位置了。刪除是用名字比對的，"
                + "兩個同名會一次刪掉兩個。"
        }
        return nil
    }

    /// 改名。**守衛與動作共用 `renameRejection`**——UI 那一層零測試，各問各的
    /// 那一刻起「按鈕是亮的但按下去什麼都不會發生」就成立了，而那與壞掉分不出來。
    public func renameZone(at index: Int, to name: String) {
        guard renameRejection(at: index, to: name) == nil else { return }
        let name = Self.trimmed(name)
        replaceZone(at: index) { GridZone(name: name, spec: $0.spec, hotkey: $0.hotkey) }
    }

    /// 設快捷鍵之前先問這一支。**只擋不安全的那一種**（沒有 ⌘／⌃／⌥）。
    ///
    /// **撞鍵不擋，改用紅字警告**——與「快捷鍵」那一頁逐字相同的處置：那邊
    /// `HotkeyView` 拿 `conflicts` 把撞到的列標紅，而 `HotkeyRecorder` 唯一會
    /// 拒收的是 `isSafeAsGlobalShortcut`。兩頁不一致本身就是缺陷（同一組鍵在
    /// 一頁設得上、在另一頁被拒，而它們寫的是同一個檔）。而且擋下來會讓「把兩個
    /// zone 的鍵對調」做不到——中間那一步必定撞，於是沒有一條路走得通。
    public func hotkeyRejection(_ hotkey: Hotkey) -> String? {
        guard !hotkey.isSafeAsGlobalShortcut else { return nil }
        return "至少要按住 ⌘、⌃ 或 ⌥ 其中一個——沒有修飾鍵的話，這個鍵在每個 app 裡"
            + "都會被吃掉，而且沒辦法從那個 app 裡救回來。"
    }

    /// 守衛與動作共用 `hotkeyRejection`，理由與 `renameZone` 逐字相同。
    public func setHotkey(_ hotkey: Hotkey, forZoneAt index: Int) {
        guard hotkeyRejection(hotkey) == nil else { return }
        replaceZone(at: index) { GridZone(name: $0.name, spec: $0.spec, hotkey: hotkey) }
    }

    /// 清掉快捷鍵。沒有快捷鍵的 zone 是常態（在面板裡點得到就夠了），所以這件事
    /// 一定要做得到——只設得上不清得掉的話，設錯一次就永遠留在那裡佔著那組鍵。
    public func clearHotkey(forZoneAt index: Int) {
        replaceZone(at: index) { GridZone(name: $0.name, spec: $0.spec, hotkey: nil) }
    }

    /// 刪掉。**走 Domain 那一支 `removingZone(named:)`**，與面板上那個 `×` 同一條路
    /// ——這裡自己寫 `zones.removeAll { $0.name == name }` 就是第二份，而兩份對
    /// 「同名要不要一起刪」漂移的那一刻沒有任何東西會發現。
    ///
    /// 為此組一份臨時文件：那支的收發都是 `HotkeyDocument`，而這一頁持有的是攤平
    /// 出來的 `zones`。**不要「順手簡化」掉這三行。**
    public func removeZone(named name: String) {
        var document = loadedDocument
        document.zones = zones
        let next = document.removingZone(named: name).zones
        guard next != zones else { return }
        zones = next
        isDirty = true
    }

    /// 撞鍵的那幾組。UI 拿它把那幾列標紅——後註冊的那個會安靜地不生效
    /// （`RegisterEventHotKey` 對重複的組合回錯誤），不說的話使用者看到的是
    /// 「我明明設了這個鍵，按下去卻沒反應」。
    ///
    /// **算的是 `registrableBindings`**（綁定 ＋ 有快捷鍵的 zone），不是只看
    /// `zones`：一個 zone 與某條既有綁定撞鍵時，兩邊都要標得出來，而只問 zones
    /// 的話那一列永遠是黑的。與 `HotkeyEditor.conflicts` 同一支、同一個理由。
    public var conflicts: [Hotkey] {
        var document = loadedDocument
        document.zones = zones
        return HotkeyBindings.conflicts(in: document.registrableBindings)
    }

    /// 換掉一個 zone。值沒變就不算一步（與 `set(_:forDisplay:)`、
    /// `HotkeyEditor.mutate` 同一條）。
    private func replaceZone(at index: Int, _ transform: (GridZone) -> GridZone) {
        guard zones.indices.contains(index) else { return }
        let next = transform(zones[index])
        guard next != zones[index] else { return }
        zones[index] = next
        isDirty = true
    }

    /// 修掉前後空白。**不用 Foundation 的 `trimmingCharacters(in:)`**：
    /// `WorkmodeEditorControl` 的 allowlist 沒有 Foundation（`DependencyRuleTests`
    /// 掃原始碼在守），而 `HotkeyEditor.addFloatApp` 那一支編得過是靠 `WorkmodeCore`
    /// 順便帶進來的——為了一個 trim 多收一個模組是相反的方向。
    /// `Character.isWhitespace` 是標準庫的，而且認得全形空白 U+3000 與 NBSP
    /// （與 `LayoutValidator.containsWhitespace` 同一個值域）。
    private static func trimmed(_ text: String) -> String {
        var slice = Substring(text)
        while let first = slice.first, first.isWhitespace {
            slice = slice.dropFirst()
        }
        while let last = slice.last, last.isWhitespace {
            slice = slice.dropLast()
        }
        return String(slice)
    }

    /// ⌘S 能不能按。讀到一份看不懂的檔就不行——`save()` 是「重讀整份、只換掉
    /// `grids` 與 `zones`」，而看不懂的那一份重讀出來是內建的預設值（parse 不過）或一份
    /// 空文件（parse 得過但不是 hotkeys 文件），兩種寫下去都是拿一份不是他寫的
    /// 東西覆蓋掉使用者只是打錯一個字的檔。
    /// **判準在這裡不在 UI**，與 `HotkeyEditor.canSave` 逐字同一條：那一層零測試。
    public var canSave: Bool {
        loadFailure == nil
    }

    /// 存檔：重讀整份文件、只換掉這一頁擁有的兩個欄位（`grids` 與 `zones`）、寫回去。
    /// **重讀是必要的**——快捷鍵那一頁與格線這一頁都會寫同一個檔，拿載入時那份
    /// （`loadedDocument`）去寫會把它們的改動洗掉。
    ///
    /// 回 `HotkeySave` 而不是 throw：那個 enum 講的就是這個檔的存檔結果，而
    /// `SideFileSave.text` 已經把它翻成給人看的話——回別的形狀等於逼零測試的 UI
    /// 那一層自己發明措辭。**`.blockedByExternalChange` 這一頁不會回**：它沒有
    /// 那道閘門，因為「重讀整份」本來就是合併，擋下來反而是把合併變成拒絕。
    public func save() -> HotkeySave {
        guard canSave else { return .failed(loadFailure ?? Self.unreadable) }
        // 重讀也可能失敗：那個檔在 `loadOnce` 與這一刻之間被手改壞了。此時照樣
        // 不能寫，而且要把 `loadFailure` 記起來——⌘S 從這一刻起也該是灰的。
        guard var document = load() else {
            loadFailure = Self.unreadable
            return .failed(Self.unreadable)
        }
        document.grids = grids
        document.zones = zones
        do {
            try store(document)
        } catch {
            return .failed("寫不進 hotkeys.json：\(error)")
        }
        isDirty = false
        return .written
    }

    /// 兩種看不懂**講同一句話**：使用者要做的事一樣（去把那個檔改對），而分開講
    /// 就要在這一層判斷是哪一種——那個判斷已經在 `HotkeyFile.readable` 做過了，
    /// 這裡只收得到 nil。措辭不寫死「不是合法的 JSON」：第四種（鍵名打錯）它是
    /// 合法的 JSON，照那樣講會叫使用者去找一個不存在的語法錯。
    private static let unreadable =
        "hotkeys.json 在，但看不懂——不是合法的 JSON，或不是一份 hotkeys 設定"
            + "（例如 bindings 打錯字）。存下去會蓋掉它，所以這一頁不寫檔。"
}
