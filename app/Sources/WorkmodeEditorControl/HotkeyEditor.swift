import Observation
import WorkmodeCore
import WorkmodeDomain

/// 存檔的四種結果。與 `YabaircSave` 少一種：這個檔沒有 `sh -n` 那道語法閘門，
/// 因為每一條在**編輯的當下**就已經解析過了（打不出一條解不開的綁定）。
public enum HotkeySave: Equatable, Sendable {
    case written
    case unchanged
    /// 檔案在載入之後被別人改過（手改，或另一個 tatami 存過）。
    case blockedByExternalChange
    case failed(String)
}

/// `hotkeys.json` 的編輯器。
///
/// 與 `YabaircEditor` 同一個形狀（獨立型別、走 `FileStore` port、注入閉包），
/// 理由也一樣：`EditorController` 在 400 行門檻邊上，而這一層要測得到。
///
/// **解析與輸出用注入的閉包**，不 import Wire：`WorkmodeEditorControl` 的相依
/// 由 `DependencyRuleTests` 掃原始碼在守，而 `SpaceLayout` 的 `parse:`／`renderRaw:`
/// 是同一個先例（理由逐字寫在它的 doc 裡：Core 不許 import Wire）。
@Observable
public final class HotkeyEditor {
    public private(set) var bindings: [HotkeyBinding] = []
    /// balance／rotate／gaps 跳過的 app 名。與 `bindings` 同一份檔案、同一個
    /// dirty、同一個 ⌘S——分開存的話「清單存了、綁定沒存」這種狀態就會存在。
    public private(set) var floatApps: [String] = []
    /// 滑鼠拖曳（fn ＋ 拖曳）。與 `bindings` 同一份檔案、同一個 dirty、同一個 ⌘S。
    public private(set) var mouse: MouseSettings = .defaults
    /// 讀進來時解不開的那幾條，逐條一句話。**不是致命的**：其餘照收。
    public private(set) var problems: [String] = []
    public private(set) var isDirty = false
    /// 讀不到檔要說的話。nil ＝ 讀到了，或者**那個檔本來就不存在**（見 `load`）。
    public private(set) var loadFailure: String?
    /// 讀過了沒有。與 `YabaircEditor.hasLoaded` 同一個理由：detail 是一個
    /// `switch selection`，切走再切回來 view 會重建，無條件 `load()` 會把
    /// 未存的編輯洗掉而畫面上零訊號。
    public private(set) var hasLoaded = false

    private let files: any FileStore
    private let path: String
    private let parse: (String) throws -> JSONValue
    private let format: (JSONValue) -> String
    /// 上一次讀到的原文，外部變更那道閘門用。**檔案不存在時是 nil**，
    /// 而那時任何磁碟上的內容都算外部變更——別人剛建了它。
    private var loadedText: String?
    /// 載入時那份文件的**全部**欄位。存檔時只換掉這一頁擁有的三個
    /// （`bindings`／`floatApps`／`mouse`），其餘原樣帶回去。
    ///
    /// 不留這一份的話，`save()` 會用那三個欄位**重組**一份新的 `HotkeyDocument`
    /// ——而那等於把這一頁沒在編的鍵（`grids`，之後還有 `zones`）在使用者按 ⌘S
    /// 的那一刻**無聲刪掉**。`HotkeyDocument` 自己的 doc 就在警告這個形狀，
    /// 而 2026-09-09 實測它已經真的會吃掉手寫的 `grids` 區塊。
    private var loadedDocument = HotkeyDocument(bindings: [], floatApps: [])

    public init(files: any FileStore, path: String,
                parse: @escaping (String) throws -> JSONValue,
                format: @escaping (JSONValue) -> String)
    {
        self.files = files
        self.path = path
        self.parse = parse
        self.format = format
    }

    /// 讀。**檔案不存在不是錯誤**——那是第一次跑（或剛從 skhd 搬過來）的常態，
    /// 這時給內建那 45 條並標成 dirty，使用者按 ⌘S 就把它落成檔案。
    ///
    /// 標 dirty 是刻意的：畫面上列著 45 條而磁碟上沒有檔案，不標的話 ⌘S 是灰的，
    /// 使用者只能先改一條再改回去才存得掉。
    public func load() {
        hasLoaded = true
        guard let text = ((try? files.read(atPath: path)) ?? nil) else {
            bindings = HotkeyDocument.defaults.bindings
            floatApps = HotkeyDocument.defaults.floatApps
            mouse = HotkeyDocument.defaults.mouse
            problems = []
            loadedText = nil
            loadFailure = nil
            isDirty = true
            return
        }
        let parsed = try? parse(text)
        guard let json = parsed, HotkeyBindings.isDocument(json) else {
            // 這裡與「檔案不存在」相反：檔案在，但看不懂。給預設值會讓 ⌘S 覆蓋掉
            // 一份使用者可能只是打錯一個逗號的檔，所以什麼都不給並說出來。
            //
            // **兩種「看不懂」走同一條路。** 第二種是 2026-09-09 在格線那一頁抓到
            // 的資料遺失：`bindings` 打成 `binding`（或最外層是陣列、或 `bindings`
            // 不是陣列）時 `HotkeyBindings.read` 回的是一份**空文件加一句 problem**
            // 而不是失敗，於是這一頁 `canSave` 為真、`save()` 回 `.written`，使用者
            // 那 45 條綁定與 float 清單就在他動一下這一頁的那一刻被一份空設定蓋掉。
            // 覆寫那條路（`HotkeyFile.readable`）問的是同一句 `isDocument`。
            //
            // 壞掉的**單一條**不走這裡：那是「少一條」不是「看不懂」，照舊由 `read`
            // 逐條說出來再跳過——整份擋掉會讓一個錯字關掉整頁。
            bindings = []
            floatApps = []
            problems = []
            // 訊息分得出兩種：對一份 parse 得過的檔說「不是合法的 JSON」，
            // 會叫使用者去找一個不存在的逗號。
            loadFailure = parsed == nil ? "\(path) 不是合法的 JSON"
                : "\(path) 沒有 bindings 陣列，不像一份 hotkeys 設定"
            loadedText = text
            isDirty = false
            return
        }
        let read = HotkeyBindings.read(json)
        loadedDocument = read.document
        bindings = read.document.bindings
        floatApps = read.document.floatApps
        mouse = read.document.mouse
        problems = read.problems
        loadedText = text
        loadFailure = nil
        isDirty = false
    }

    // MARK: - 編輯

    /// 每個編輯動作都經過這裡。值沒變就不算一步（與 `EditorController.edit` 同一條）。
    private func mutate(_ transform: ([HotkeyBinding]) -> [HotkeyBinding]) {
        let next = transform(bindings)
        guard next != bindings else { return }
        bindings = next
        isDirty = true
    }

    public func setHotkey(_ hotkey: Hotkey, at index: Int) {
        mutate { rows in
            guard rows.indices.contains(index) else { return rows }
            var rows = rows
            rows[index] = HotkeyBinding(hotkey: hotkey, action: rows[index].action,
                                        isEnabled: rows[index].isEnabled)
            return rows
        }
    }

    /// 動作用字串收，解不開就整條不動——UI 那層零測試，讓它自己解析等於把一個
    /// 沒有人驗得到的判斷放在最不該放的地方。
    public func setAction(_ text: String, at index: Int) {
        guard let action = HotkeyAction.parse(text) else { return }
        mutate { rows in
            guard rows.indices.contains(index) else { return rows }
            var rows = rows
            rows[index] = HotkeyBinding(hotkey: rows[index].hotkey, action: action,
                                        isEnabled: rows[index].isEnabled)
            return rows
        }
    }

    public func setEnabled(_ isEnabled: Bool, at index: Int) {
        mutate { rows in
            guard rows.indices.contains(index) else { return rows }
            var rows = rows
            rows[index] = HotkeyBinding(hotkey: rows[index].hotkey, action: rows[index].action,
                                        isEnabled: isEnabled)
            return rows
        }
    }

    public func remove(at index: Int) {
        mutate { rows in
            guard rows.indices.contains(index) else { return rows }
            var rows = rows
            rows.remove(at: index)
            return rows
        }
    }

    /// 新增一條空白綁定。
    ///
    /// **按鍵給一個一定不會撞的預留值**（`f20`，配上四個修飾鍵），而不是留空：
    /// `Hotkey` 沒有「還沒設」這個狀態，而給一個常見組合會讓新增的那一條當場
    /// 搶走使用者正在用的鍵。動作預設是 `focus:west`——它是最無害的一個
    /// （只換焦點，不搬視窗）。
    public func add() {
        mutate { rows in
            rows + [HotkeyBinding(hotkey: Hotkey(key: "f20",
                                                 modifiers: [.ctrl, .alt, .shift, .cmd]),
                                  action: .focusWindow(.west))]
        }
    }

    /// 整份換回內建的預設（45 條綁定加 29 個 float app）。
    public func restoreDefaults() {
        setMouse(HotkeyDocument.defaults.mouse)
        mutateFloat { _ in HotkeyDocument.defaults.floatApps }
        mutate { _ in HotkeyDocument.defaults.bindings }
    }

    // MARK: - float 清單

    private func mutateFloat(_ transform: ([String]) -> [String]) {
        let next = transform(floatApps)
        guard next != floatApps else { return }
        floatApps = next
        isDirty = true
    }

    /// 空字串與重複的名字都不收——一個空項寫進檔案是一個看不出效果的元素，
    /// 而重複的第二份刪掉其中一個之後看起來像「刪不掉」。
    public func addFloatApp(_ name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        mutateFloat { apps in apps.contains(trimmed) ? apps : apps + [trimmed] }
    }

    /// 換一份滑鼠設定。值沒變就不算一步（與其他編輯同一條）。
    public func setMouse(_ settings: MouseSettings) {
        guard settings != mouse else { return }
        mouse = settings
        isDirty = true
    }

    public func removeFloatApp(at index: Int) {
        mutateFloat { apps in
            guard apps.indices.contains(index) else { return apps }
            var apps = apps
            apps.remove(at: index)
            return apps
        }
    }

    /// 同一組鍵綁了兩次的那幾組。UI 拿它把那幾列標紅——後面那條會安靜地
    /// 不生效（`RegisterEventHotKey` 拒絕重複註冊），不說的話使用者會以為沒存到。
    ///
    /// **算的是 `registrableBindings`**（綁定 ＋ 有快捷鍵的 zone），因為撞掉的那一半
    /// 就在這一頁上：註冊時先來的贏，所以一條與 zone 撞鍵的綁定是**這一列**會安靜地
    /// 不生效。只問 `bindings` 的話那一列不會標紅，而使用者看到的只是「我明明設了
    /// 這個鍵，按下去卻沒反應」。
    ///
    /// 標紅不會落到錯的那一列：`HotkeyView` 是拿 `Set<Hotkey>` 比對每一列**自己的**
    /// 鍵（不是拿索引去對這個陣列），所以多出來的 zone 鍵只會讓真正撞到的那一列變紅。
    /// 代價是 zone 與 zone 之間撞鍵會出現在這份清單裡而畫面上沒有對應的一列——
    /// zone 編在「格線」那一頁（`GridSettingsEditor.conflicts` 是反方向的同一支，
    /// 它把這裡的 `bindings` 算進去），而漏掉它才是回歸。
    ///
    /// 從 `loadedDocument` 出發只換掉 `bindings`，與 `save()` 逐字相同的理由：
    /// zone 不是這一頁擁有的欄位，重組一份新文件等於當它們不存在。
    public var conflicts: [Hotkey] {
        var document = loadedDocument
        document.bindings = bindings
        return HotkeyBindings.conflicts(in: document.registrableBindings)
    }

    // MARK: - 存檔

    /// 兩道閘門。沒有語法那道（見 `HotkeySave` 的 doc）。
    public func save() -> HotkeySave {
        guard canSave else { return .failed(loadFailure ?? "現在不能存檔") }
        // `FileStore` 的合約是「寫這些**行**」，結尾那個換行由它補
        // （`FileManagerStore` 兩支 write 都做 `contents + "\n"`），而
        // `JSONWriter.format` 不補。所以磁碟上的是 `payload + "\n"`，
        // 而 `loadedText` 記的必須是**磁碟上那份**——記成 `payload` 的話，
        // 下一次存檔會被外部變更那道閘門誤判（`YabaircEditor.save` 記過同一個坑）。
        // 從載入時那份**整份**文件出發，只換掉這一頁擁有的三個欄位
        // ——重組一份新的會把 `grids`（與之後的 `zones`）刪掉，見 `loadedDocument`。
        var document = loadedDocument
        document.bindings = bindings
        document.floatApps = floatApps
        document.mouse = mouse
        let payload = format(HotkeyBindings.write(document))
        let onDiskText = payload + "\n"
        guard onDiskText != loadedText else {
            isDirty = false
            return .unchanged
        }
        let onDisk = (try? files.read(atPath: path)) ?? nil
        guard onDisk == loadedText else { return .blockedByExternalChange }
        do {
            try files.writeAtomically(payload, toPath: path)
        } catch {
            return .failed("寫不進 \(path)：\(error)")
        }
        loadedText = onDiskText
        isDirty = false
        return .written
    }

    /// ⌘S 能不能按。讀到一份看不懂的檔就不行——那時 `bindings` 是空的，
    /// 存下去等於拿一份空設定覆蓋掉使用者只是打錯一個逗號的檔。
    /// **判準在這裡不在 UI**，與 `YabaircEditor.canSave` 同一條。
    public var canSave: Bool {
        loadFailure == nil
    }
}
