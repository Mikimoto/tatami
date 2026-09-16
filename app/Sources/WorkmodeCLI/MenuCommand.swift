import AppKit
import WorkmodeAdapters
import WorkmodeCore
import WorkmodeDomain
import WorkmodeWire

/// `tatami menu`：常駐選單列。
///
/// **它必須由 yabai 起（`yabairc` 檔尾那一段）而不是由 launchd 或 Finder。**
/// AX 的授權掛在 responsible process 上：yabai 起的子行程歸給 yabai，而 yabai 本來
/// 就有權限；自己起的話它就是自己的 responsible，而 `~/.local/bin/tatami` 是指向
/// `.build/debug` 的 symlink、每次 `swift build` 都換簽章，授權留不住
/// （2026-09-07 實測，見 CLAUDE.md 的「登入時把版面排好」）。
///
/// `.accessory` 而不是 `.regular`：不要 Dock 圖示，也不要它出現在 ⌘Tab。
@MainActor
func runMenuBar() -> Never {
    let application = NSApplication.shared
    application.setActivationPolicy(.accessory)
    reportAccessibility()
    menuController.install()
    // 自己聽 space 切換（不經過 yabai 的 signal）。要不要真的排由
    // `SpaceWatchDecision` 每次現算，所以這裡無條件掛上去。
    spaceWatch.start()
    // 快捷鍵取代退役的 skhd 綁定（數字不寫在這裡：skhdrc 退役當天是 47 條，而
    // 搬過來的那些之後還會增減，兩個數字都不是這句話在講的事）。
    // **只有這個常駐行程收得到它們**——`RegisterEventHotKey`
    // 註冊在行程上，行程結束註冊就沒了。那是它與 skhd 最實際的差別，所以
    // 「登入時自動啟動」那個開關對快捷鍵是必要的而不只是方便。
    installHotkeys()
    // 啟動時把版面排好，取代 `yabairc` 檔尾那段 shell。非同步（走 Timer），
    // 所以選單列圖示不會等它那 5 秒。
    startupLayout.start()
    application.run()
    exit(0)
}

/// 啟動時報一次「這個行程有沒有 AX 權限」，沒有就跳系統的授權對話框。
///
/// **這是這條路徑唯一的診斷訊號。** 沒有它，權限不在的症狀是「選單打得開、按了
/// 重排卻什麼都沒發生」，而那與「版面本來就已經是對的」在畫面上分不出來。
///
/// 它同時是**驗這件事的唯一辦法**：`__smoke ws` 從終端機跑會繼承終端機的授權，
/// 問不到 launchd 起的這個行程（2026-09-08 差點就這樣量錯）。
/// 讀法：`open -a Tatami --stderr /tmp/tatami_app.log` 再看那個檔。
///
/// 對話框（`AXTrustedCheckOptionPrompt`）順手把這個 app 加進「輔助使用」清單
/// （未勾選），所以使用者只要撥一個開關，不必自己去 Finder 把 .app 拖進去。
/// 只在沒權限時問，所以它不是每次啟動都煩人的東西。
private func reportAccessibility() {
    if (try? WindowServerClient()) != nil {
        FileHandle.standardError.write(Data("AX：有權限\n".utf8))
        return
    }
    // 字面字串而不是 `kAXTrustedCheckOptionPrompt`：那個常數是 `var`，
    // Swift 6 的嚴格併發把它判成「共享可變狀態」而編不過。值是穩定的公開 API 字串。
    _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
    FileHandle.standardError.write(Data(
        "AX：沒有權限，已跳出授權對話框；撥開之後**要重開這個 app**（TCC 不會套用到已在跑的行程）\n".utf8
    ))
}

/// 全域一份，因為 `NSStatusItem` 與 menu delegate 都要有人持有——區域變數在
/// `application.run()` 之前就出了作用域，狀態列圖示會當場消失。
/// （`EditCommand` 的 `quitOnClose` 是同一個理由。）
@MainActor
private let menuController = MenuController()

/// 同一個理由要有人持有：`Timer` 與 `NSWorkspace` 的 observer 掛在它身上。
@MainActor
private let spaceWatch = SpaceWatch()

/// 同上：Carbon 的 `EventHotKeyRef` 與事件處理器掛在它身上，它一被回收
/// 全部的快捷鍵就註銷了。
@MainActor
private let hotkeyMonitor = HotkeyMonitor()

/// 同上：重試的 `Timer` 與「試過幾次」掛在它身上。
@MainActor
private let startupLayout = StartupLayout()

/// 讀 `hotkeys.json`（沒有就用內建那 45 條）並註冊。
///
/// 讀不到或有壞掉的條目都不是致命的：`HotkeyFile.load` 逐條說出來再跳過，
/// 剩下的照樣註冊——一個錯字關掉全部快捷鍵比較糟。
@MainActor
private func installHotkeys() {
    let reporter = TextReporter(renderer: HumanEventRenderer(), sink: StandardStreams())
    let paths = TatamiPaths()
    let document = HotkeyFile.load(from: paths.hotkeys, files: FileManagerStore(),
                                   reporter: reporter)
    let result = hotkeyMonitor.register(document.registrableBindings) { action in
        HotkeyRuntime.perform(action, floatApps: document.floatApps, grids: document.grids,
                              reporter: reporter)
    }
    reporter.report(.hotkeysRegistered(count: result.count, skipped: result.skipped))
    // fn ＋ 拖曳。與快捷鍵同一份設定檔、同一個「改完要重開」的規矩。
    // 裝不起來只說一句——拖曳壞掉不該讓 45 個快捷鍵一起消失。
    if !document.mouse.isDisabled {
        guard let engine = try? WindowServerClient(),
              mouseTap(settings: document.mouse, engine: engine)
        else {
            reporter.report(.hotkeyMouseTapRefused)
            return
        }
        reporter.report(.hotkeyMouseTapInstalled(modifier: document.mouse.modifier.rawValue))
    }
}

/// `MouseTap` 也要有人持有：`CFMachPort` 與 run loop source 掛在它身上。
@MainActor private var installedMouseTap: MouseTap?

@MainActor
private func mouseTap(settings: MouseSettings, engine: WindowServerClient) -> Bool {
    let paths = TatamiPaths()
    // 吸附區：拖曳時浮出候選區塊，游標所在那一區整塊變色，放開就吸進去。
    // **樹優先**——那個 space 在 `spaceTrees` 有樹就用樹的葉，沒有就退回九宮格。
    let overlay = SnapOverlay(source: SnapSource(
        yabai: engine, files: FileManagerStore(), layoutPath: paths.layout,
        statePath: paths.state, parse: JSONParser.parse, renderRaw: rawText
    ))
    installedSnapOverlay = overlay
    let tap = MouseTap(settings: settings, engine: engine, snap: overlay)
    installedMouseTap = tap
    return tap.install()
}

/// 同一個理由要有人持有：`NSPanel` 與那個 view 掛在它身上。
@MainActor private var installedSnapOverlay: SnapOverlay?

@MainActor
private final class MenuController: NSObject, NSMenuDelegate {
    private var item: NSStatusItem?

    func install() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        // SF Symbol 而不是文字：`isTemplate` 讓它跟著淺色／深色選單列自動反色，
        // 文字要自己處理那件事。拿不到符號（舊系統）就退回一個字。
        if let image = NSImage(systemSymbolName: "square.grid.2x2",
                               accessibilityDescription: "tatami")
        {
            image.isTemplate = true
            item.button?.image = image
        } else {
            item.button?.title = "疊"
        }
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        self.item = item
    }

    /// 每次打開都重建，不快取。
    ///
    /// 地點與 profile 會被 `--switch`、編輯器、以及插拔螢幕改掉，而一份快取的選單
    /// 顯示的是「上次打開時」的狀態——那比沒有這個選單更糟，因為它看起來是現況。
    /// 代價是打開選單時會做一次查詢（SkyLight，不 spawn 子行程）。
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let snapshot = MenuSnapshot()
        menu.addItem(header(snapshot.headline))
        menu.addItem(.separator())
        for profile in snapshot.profiles {
            let entry = NSMenuItem(title: profile, action: #selector(chooseProfile(_:)),
                                   keyEquivalent: "")
            entry.target = self
            entry.representedObject = profile
            // 打勾而不是禁用：目前這個仍然點得下去（重新套用一次是合理的動作）。
            entry.state = profile == snapshot.profile ? .on : .off
            menu.addItem(entry)
        }
        if !snapshot.profiles.isEmpty {
            menu.addItem(.separator())
        }
        menu.addItem(action("重排目前可見的 space", #selector(applySpaces)))
        // 拔插螢幕之後 macOS 會把可見的那一個換成別的（常常是另一個地點的 space），
        // 上面那一項那時什麼都不做。這一項排這個 profile 底下每一棵有樹的 space。
        menu.addItem(action("重排全部有版面的 space", #selector(applyAllSpaces)))
        menu.addItem(action("格線…", #selector(openGrid)))
        menu.addItem(.separator())
        // 存檔：一個子選單而不是兩個 top-level 項目。
        //
        // 原本是「存進「<目前那個>」」加「存成新 profile…」兩項，於是**覆蓋一個
        // 不是目前那個的既有 profile 表達不出來**——第一項只給目前那個，第二項
        // 走 `overwrite: false` 會被 `SaveLayout` 擋下。子選單讓每個 profile 都
        // 點得到，而且**看得見有哪些可以存**（輸入框要先記得名字才打得出來）。
        menu.addItem(saveMenu(snapshot))
        menu.addItem(.separator())
        // 兩個開關都**每次打開現算**，與抬頭同一個理由：快取顯示的是「上次打開時」。
        menu.addItem(toggle("切換 space 自動重排", #selector(toggleAutoSpace), on: autoSpaceIsOn))
        menu.addItem(toggle("登入時自動啟動", #selector(toggleLoginItem),
                            on: LoginItem.isRegistered))
        menu.addItem(action("編輯設定…", #selector(openEditor)))
        menu.addItem(.separator())
        menu.addItem(action("結束 tatami menu", #selector(quit)))
    }

    private func header(_ title: String) -> NSMenuItem {
        let entry = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        entry.isEnabled = false
        return entry
    }

    /// 「把目前排版存進 ▸」：每個 profile 一列（目前那個打勾）、分隔線、「新的…」。
    ///
    /// 清單來自 `MenuSnapshot.profiles`（**生效**地點底下的那一份），**不跨地點**：
    /// `--save` 用的是偵測到的地點的螢幕，存進別的地點的 profile 會寫進一組
    /// 對不上的畫布。
    private func saveMenu(_ snapshot: MenuSnapshot) -> NSMenuItem {
        let parent = NSMenuItem(title: "把目前排版存進", action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        for profile in snapshot.profiles {
            let entry = NSMenuItem(title: profile, action: #selector(saveInto(_:)),
                                   keyEquivalent: "")
            entry.target = self
            entry.representedObject = ProfileChoice(location: snapshot.location,
                                                    profile: profile)
            entry.state = profile == snapshot.profile ? .on : .off
            submenu.addItem(entry)
        }
        if !snapshot.profiles.isEmpty {
            submenu.addItem(.separator())
        }
        submenu.addItem(action("新的 profile…", #selector(saveIntoNewProfile)))
        parent.submenu = submenu
        return parent
    }

    private func action(_ title: String, _ selector: Selector) -> NSMenuItem {
        let entry = NSMenuItem(title: title, action: selector, keyEquivalent: "")
        entry.target = self
        return entry
    }

    // MARK: - 動作

    /// 切 profile 之後接著套用。
    ///
    /// **在行程內跑 Core 而不是 spawn `tatami --switch X`**：名字要經過 shell 就要
    /// 處理引號（profile 名是中文，`validate` 只擋空白），而 `SwitchSetting.run`
    /// 與 `SpaceLayout.run` 本來就回 `Outcome` 而不是 `exit`——只有 CLI 的包裝層
    /// 會退出。代價是那幾秒 main thread 被佔住、選單列圖示不會回應，與編輯器
    /// ⌘R 相同。
    ///
    /// **切失敗就停下不排。** 排一個使用者沒要的 profile 正是這個缺陷最初的災難：
    /// 切失敗之後照樣 `applySpaces`，排的是舊的那個，而畫面上看起來只是
    /// 「重排之後視窗沒就位」（2026-09-10 使用者回報的原句）。
    @objc private func chooseProfile(_ sender: NSMenuItem) {
        guard let profile = sender.representedObject as? String else { return }
        let result = MenuActions.switchProfile(profile: profile)
        guard result.outcome == .updated else {
            MenuDialogs.reportSwitchFailure(profile: profile, reason: result.message)
            return
        }
        MenuActions.applySpaces(scope: .visible)
    }

    @objc private func applySpaces() {
        MenuActions.applySpaces(scope: .visible)
    }

    @objc private func applyAllSpaces() {
        MenuActions.applySpaces(scope: .all)
    }

    /// 存進一個既有的 profile（子選單上的任一列）。**先確認**——它會蓋掉那個
    /// profile 裡每一棵樹。
    ///
    /// 沒有「存進目前那個」的特例：子選單上打勾那一列就是它。
    @objc private func saveInto(_ sender: NSMenuItem) {
        guard let choice = sender.representedObject as? ProfileChoice else { return }
        let trees = MenuActions.savedSpaceCount(location: choice.location,
                                                profile: choice.profile)
        guard MenuDialogs.confirmOverwrite(profile: choice.profile, trees: trees)
        else { return }
        MenuDialogs.reportSaveResult(MenuActions.saveSpaces(profile: choice.profile,
                                                            overwrite: true))
    }

    /// 存成新的。
    ///
    /// **撞名不再靠 `SaveLayout` 的 `overwrite: false` 擋**：那條路只印一句
    /// 「已經有了」就結束，而打進一個既有名字的人要的通常就是覆蓋它。改成先比對
    /// 清單，撞到就問——與子選單上點既有那一列走同一個確認框。
    ///
    /// 清單來自建這個框**之前**的 `MenuSnapshot`，不是打完字之後再問一次：那樣會
    /// 多一次查詢，而結果只可能在使用者打字期間插拔螢幕時不同。
    @objc private func saveIntoNewProfile() {
        let snapshot = MenuSnapshot()
        guard let name = MenuDialogs.askNewProfileName() else { return }
        var overwrite = false
        if snapshot.profiles.contains(name) {
            let trees = MenuActions.savedSpaceCount(location: snapshot.location,
                                                    profile: name)
            guard MenuDialogs.confirmOverwrite(profile: name, trees: trees)
            else { return }
            overwrite = true
        }
        MenuDialogs.reportSaveResult(MenuActions.saveSpaces(profile: name,
                                                            overwrite: overwrite))
    }

    /// `grid` 與 `edit` **spawn 出去**，不在行程內跑：兩個都要自己的
    /// activation policy 與視窗（`grid` 要 `.regular` 才收得到 Esc），而這個行程是
    /// `.accessory`。一個行程一種身分比在 runtime 切來切去可靠。
    /// 孫行程的 AX 授權照樣沿著 yabai 那條鏈下來。
    @objc private func openGrid() {
        MenuActions.spawn(["grid"])
    }

    @objc private func openEditor() {
        MenuActions.spawn(["edit"])
    }

    private func toggle(_ title: String, _ selector: Selector, on checked: Bool) -> NSMenuItem {
        let entry = action(title, selector)
        entry.state = checked ? .on : .off
        return entry
    }

    /// 現算而不是記住：使用者會在別的地方改狀態檔（編輯器、手改）。
    private var autoSpaceIsOn: Bool {
        let state = (try? FileManagerStore().read(atPath: TatamiPaths().state)) ?? ""
        return StateFile.value(forKey: SpaceWatchDecision.key, in: state) == "on"
    }

    /// 兩個開關的結果都落 stderr：選單列沒有地方顯示一句話，而丟掉它等於
    /// 「按了沒反應」查不出原因。
    @objc private func toggleAutoSpace() {
        FileHandle.standardError.write(Data((MenuActions.toggleAutoSpace() + "\n").utf8))
    }

    @objc private func toggleLoginItem() {
        FileHandle.standardError.write(Data((LoginItem.toggle() + "\n").utf8))
    }

    @objc private func quit() {
        NSApplication.shared.terminate(nil)
    }
}

/// 存檔子選單那些項目帶的酬載：地點與 profile 兩半。
///
/// **為什麼要地點**：`MenuActions.savedSpaceCount` 要它去查那個 profile 現在存了
/// 幾個 space 的樹。而在 selector 裡重新問一次 `MenuSnapshot()` 會多一次查詢，
/// 還可能拿到與「使用者剛剛看到的那份清單」不同的地點（插拔螢幕就會）。
///
/// 切 profile 那些項目**不用它**（酬載是單純的名字）：`switchProfile` 自己組
/// `/<profile>` 這個形式，刻意不帶地點。
private struct ProfileChoice {
    let location: String
    let profile: String
}
