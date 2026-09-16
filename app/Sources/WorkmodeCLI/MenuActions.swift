import AppKit
import Foundation
import WorkmodeAdapters
import WorkmodeCore
import WorkmodeDomain
import WorkmodeWire

/// 選單列那幾個動作的組裝。與 `SpaceCommand`／`EditCommand` 同一個分工：這裡只組
/// adapter 與呼叫 Core，一個判斷都不放。
///
/// 與那兩支的差別是**不 `exit`**——常駐的行程做完一件事要留著。所以這裡不能重用
/// `runSpaceLayout`（它的回傳型別是 `Never`）。
@MainActor
enum MenuActions {
    /// 事件落 stderr，而 `yabairc` 那一段把它導到 `/tmp/tatami_menu.log`。
    /// 選單列沒有地方顯示 60 幾句話，而丟掉它們等於「按了沒反應」查不出原因。
    ///
    /// `fileprivate` 而不是 `private`：`MenuSnapshot` 是同檔的另一個型別，
    /// 而它要同一個 reporter（`ActiveLocation.resolve` 在「覆寫指到不存在的地點」
    /// 時會說一句，那句話該落 log）。
    fileprivate static func reporter() -> any Reporter {
        TextReporter(renderer: HumanEventRenderer(), sink: StandardStreams())
    }

    /// 切 profile。**兩半分開收，不是一個字串。**
    ///
    /// `SwitchSetting.run(argument:)` 對沒有斜線的參數一律當**地點**解析
    /// （`SwitchSetting.swift:82-87`），所以傳裸的 profile 名字會去 pin 一個不存在
    /// 的地點、在 `:135` 被拒絕、狀態檔一個字都不寫，而症狀是「選單上的打勾沒有
    /// 動」。這一支自己組字串，所以呼叫端造不出那個誤用。
    ///
    /// **不在 Core 開第二個入口**：那個斜線解析是鏡射 bash 的行為，而 CLI 那條路
    /// 收的是使用者打的字（`office/開發`、`auto`、裸地點名），必須留著字串形式。
    /// 選單是唯一「兩半各自已知」的呼叫端，所以組字串的責任在它。
    ///
    /// 回 outcome ＋ 收集到的訊息：`Outcome.rejected` **不帶原因**（原因只走
    /// reporter，見 `SwitchSetting.swift:16`），而選單列要把那個原因放進對話框
    /// ——它沒有別的地方講話。
    ///
    /// **前導斜線、地點那半留空，這是語意不是排版。** 實測（2026-09-10 沙盒）：
    /// `--switch office/X` 寫 `location=office` **加** `profile.office=X`——`pin(location:)`
    /// 對非空的地點會釘住**覆寫**；而 `--switch /X` 只寫 `profile.office=X`，因為
    /// `pin(location:)` 對空的那半直接 `return true` 不寫檔，`pin(profile:)` 再自己
    /// 去解生效地點。從選單挑一個 profile 的意圖是「換 profile」，**不是「把地點
    /// 鎖在這裡」**——鎖了之後帶筆電換地方，偵測說 home 而覆寫強迫 office，那正是
    /// `MenuSnapshot` 那個缺陷剛修掉的錯配，只是換成由我們自己造成。
    /// 對照組：`--switch /沒有這個` 仍然 rc=1 並拒絕，所以 profile 照樣對生效地點
    /// 驗證，沒有因此變寬。
    static func switchProfile(profile: String)
        -> (outcome: SwitchSetting.Outcome, message: String)
    {
        guard let engine = try? WindowServerClient() else {
            return (.rejected, "! 接不上視窗引擎\n")
        }
        let paths = TatamiPaths()
        let collected = CollectingReporter()
        let outcome = SwitchSetting(
            yabai: engine,
            files: FileManagerStore(),
            picker: FzfPicker(),
            layoutPath: paths.layout,
            statePath: paths.state,
            parse: JSONParser.parse,
            renderRaw: rawText,
            reporter: TeeReporter(first: reporter(), second: collected)
        ).run(argument: "/\(profile)")
        return (outcome, collected.lines.joined())
    }

    /// `--space`，**不開 app**：`presence` 傳 nil。
    ///
    /// 與 `__space-signal` 和編輯器 ⌘R 同一個立場——從選單按一下不該順便開起一堆
    /// app。要開的話打 `tatami --space --launch`（那是明確要求的旗標）。
    static func applySpaces(scope: SpaceLayout.Scope) {
        guard let engine = try? WindowServerClient() else { return }
        let paths = TatamiPaths()
        _ = SpaceLayout(
            yabai: engine,
            server: engine,
            safari: SafariOsascriptClient(),
            clock: SystemClock(),
            files: FileManagerStore(),
            layoutPath: paths.layout,
            statePath: paths.state,
            parse: JSONParser.parse,
            renderRaw: rawText,
            reporter: reporter(),
            presence: nil
        ).run(want: "", mode: .apply, scope: scope)
    }

    /// 切「切換 space 自動重排」那個開關（狀態檔的 `autospace`）。
    ///
    /// 寫狀態檔而不是寫 `yabairc`：那個鍵由**這個常駐行程**讀，不需要 yabai 參與，
    /// 也就不必碰一個 yabai 會 exec 的檔（那條路的三道閘門是為了它才存在的）。
    /// 整份重建不追加——同一個 key 追加兩次，讀的時候只拿得到其中一筆。
    static func toggleAutoSpace() -> String {
        let paths = TatamiPaths()
        let files = FileManagerStore()
        let state = (try? files.read(atPath: paths.state)) ?? ""
        let wasOn = StateFile.value(forKey: SpaceWatchDecision.key, in: state) == "on"
        let next = StateFile.set(state, key: SpaceWatchDecision.key, value: wasOn ? "off" : "on")
        // `FileStore.write` 的合約是「寫這些行」，所以交出去前把結尾換行拿掉
        // （`YabaircEditor.save()` 同一條）。
        do {
            try files.write(next.hasSuffix("\n") ? String(next.dropLast()) : next,
                            toPath: paths.state)
        } catch {
            return "切換 space 自動重排：寫不進狀態檔（\(error)）"
        }
        return wasOn ? "切換 space 自動重排：已關閉" : "切換 space 自動重排：已開啟"
    }

    /// 開一個新的 `tatami <args>`。
    ///
    /// 絕對路徑而不是裸命令名：這個行程由 yabai 起，`PATH` 可能只剩
    /// `/usr/bin:/bin:/usr/sbin:/sbin`（`skhdrc` 與 `yabairc` 的 signal 同一條理由）。
    /// 不等它結束、也不看它的 exit code：它自己會把話印到自己的 stderr。
    static func spawn(_ arguments: [String]) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: TatamiPaths.installedExecutable)
        process.arguments = arguments
        try? process.run()
    }

    /// 那個 profile 現在存了幾個 space 的樹。
    ///
    /// 覆蓋確認框要說出它要毀掉多少東西——「2 個」與「0 個」的差別是「兩天的
    /// 工作」與「一個空殼」。計數本身在 Domain（`SpaceNames.spaceCount`），
    /// 那是這條路唯一測得到的一塊。
    ///
    /// 讀不到設定就回 0：那句話會退成「現在沒有存過任何 space 的樹」，而那比
    /// 一個假數字好——真正的失敗會在接下來的 `saveSpaces` 說出來。
    static func savedSpaceCount(location: String, profile: String) -> Int {
        let paths = TatamiPaths()
        guard let text = try? FileManagerStore().read(atPath: paths.layout),
              let config = try? JSONParser.parse(text),
              let spaceTrees = config[location]?["profiles"]?[profile]?["spaceTrees"]
        else { return 0 }
        return SpaceNames.spaceCount(in: spaceTrees)
    }
}

/// 打開選單那一刻的現況：抬頭那一行與可選的 profile 清單。
///
/// 查不到就是空的（清單沒有東西、抬頭說原因），**不是**丟一個錯誤對話框：
/// 選單列的東西被按到時使用者在做別的事，一個 modal 比一行灰字惱人得多。
@MainActor
extension MenuActions {
    /// 把每一個有視窗的 space 目前的排版存進設定（選單列版的 `--save --all`）。
    ///
    /// **走 `Interaction.automatic`**：選單列沒有 tty，問不了「這個視窗要叫什麼」。
    /// 認不出名字的視窗直接跳過並說一句——它們不進樹，下次套用時不會出現。
    ///
    /// `overwrite` 由呼叫端決定，因為那件事**已經在畫面上問過了**（覆蓋目前的
    /// profile 會跳確認框，存成新的不會）。
    static func saveSpaces(profile: String, overwrite: Bool) -> String {
        guard let engine = try? WindowServerClient() else { return "接不上視窗引擎" }
        let paths = TatamiPaths()
        let collected = CollectingReporter()
        let outcome = SaveLayout(
            yabai: engine, safari: SafariOsascriptClient(), terminal: NoTerminal(),
            files: FileManagerStore(), layoutPath: paths.layout, statePath: paths.state,
            parse: JSONParser.parse, renderRaw: rawText, format: JSONWriter.format,
            reporter: TeeReporter(first: reporter(), second: collected)
        ).run(want: profile, scope: .all, interaction: .automatic(overwrite: overwrite))
        switch outcome {
        case .written: return collected.lines.joined() + switchAfterSave(profile)
        case .cancelled: return "沒有寫入。"
        default: return collected.lines.isEmpty ? "沒有寫入。" : collected.lines.joined()
        }
    }

    /// 存完就切過去，**只寫狀態檔不重排**。
    ///
    /// 不重排是因為剛存進去的就是畫面現在的樣子，重排一次什麼都不會改變。少了這
    /// 一步，存進一個不是目前那個的 profile 之後打勾與「我剛存進哪裡」不一致，
    /// 而下一步「重排」排的是舊的那個（2026-09-10 使用者踩到的那條）。
    ///
    /// **只有 `.written` 才走到這裡**（見上面那個 switch）：被拒絕或取消的存檔
    /// 不該改變任何東西。
    ///
    /// 重讀一次 `MenuSnapshot` 是必要的：存檔剛把新 profile 寫進 `layout.json`，
    /// 而 `SwitchSetting` 會驗「這個 profile 在這個地點底下嗎」——用存檔**之前**
    /// 那份快照的話，一個全新的 profile 必定驗不過。
    ///
    /// **兩種結果都要說。** 存成功了而切失敗（狀態檔寫不進去、地點認不出來）是
    /// 查得出來的狀態，而它的外觀與「存完切過去了」在選單上完全相同。
    private static func switchAfterSave(_ profile: String) -> String {
        // 已經在用它了，切是 no-op——不必說一句沒有資訊的話。
        if MenuSnapshot().profile == profile {
            return ""
        }
        let result = switchProfile(profile: profile)
        return result.outcome == .updated
            ? "已切到「\(profile)」。\n"
            : "! 存好了，但沒切到「\(profile)」：\(result.message)"
    }
}

/// 沒有 tty。`Interaction.automatic` 一個問題都不問，所以這兩支永遠不會被叫到
/// ——回死值而不是 fatalError：真的被叫到時「什麼都沒答」比整個 app 掛掉好。
private struct NoTerminal: Terminal {
    var hasControllingTTY: Bool {
        false
    }

    func readLine() -> String? {
        nil
    }
}

/// 把事件同時送到兩邊：一份進 log（stderr），一份收起來給對話框顯示。
private struct TeeReporter: Reporter {
    let first: any Reporter
    let second: any Reporter

    func report(_ event: WorkmodeEvent) {
        first.report(event)
        second.report(event)
    }
}

/// 收成給人看的文字。選單列沒有地方顯示事件流，而存檔的結果**一定要看得到**
/// ——「按了沒反應」與「存好了」在選單列上長得一樣。
private final class CollectingReporter: Reporter {
    private(set) var lines: [String] = []
    private let renderer = HumanEventRenderer()

    func report(_ event: WorkmodeEvent) {
        let text = renderer.render(event)
        if !text.isEmpty {
            lines.append(text)
        }
    }
}

struct MenuSnapshot {
    let headline: String
    let profiles: [String]
    let profile: String
    /// **生效**的地點（覆寫優先），不是偵測到的那個。空字串＝認不出來。
    let location: String
    /// 那個地點是誰決定的。nil ＝連地點都認不出來。
    let source: ActiveLocation.Source?

    /// **`@MainActor`：`MenuActions.reporter()` 是 main-actor 隔離的。**
    /// 兩個呼叫端（`menuNeedsUpdate` 與那個 `@objc` 的存檔動作）本來就在 main
    /// actor 上，所以這不是新的限制——只是把既有的事實寫進型別。
    @MainActor
    init() {
        guard let engine = try? WindowServerClient() else {
            headline = "接不上視窗引擎"
            profiles = []
            profile = ""
            location = ""
            source = nil
            return
        }
        let paths = TatamiPaths()
        guard let text = try? FileManagerStore().read(atPath: paths.layout),
              let config = try? JSONParser.parse(text)
        else {
            headline = "讀不到 \(paths.layout)"
            profiles = []
            profile = ""
            location = ""
            source = nil
            return
        }
        let state = (try? FileManagerStore().read(atPath: paths.state)) ?? ""
        // **`ActiveLocation.resolve` 而不是 `detectLocation`。**
        //
        // 後者不理狀態檔的 `location=` 覆寫，而 `SwitchSetting`／`SpaceLayout`／
        // `SaveLayout` 全部走前者。用偵測的話，有覆寫時這個選單列的是「偵測到
        // 那個地點」的 profile、讀的是那把鍵，而每一個動作用的是覆寫那個地點的
        // 鍵——症狀是「打勾永遠不會動」，而畫面上每一個字都正常。
        guard let resolved = ActiveLocation(yabai: engine,
                                            reporter: MenuActions.reporter())
            .resolve(state: state, config: config)
        else {
            headline = "認不出這是哪個地點"
            profiles = []
            profile = ""
            location = ""
            source = nil
            return
        }
        location = resolved.location
        source = resolved.source
        // `profileNames` 回的是空白分隔的一串（jq 的 `join(" ")`），與 bash 同形。
        let names = (try? LayoutQuery.profileNames(inLocation: location, in: config)) ?? ""
        profiles = names.split(separator: " ").map(String.init)
        profile = StateFile.value(forKey: "profile.\(location)", in: state)
        headline = profile.isEmpty ? location : "\(location) · \(profile)"
    }
}

/// `tatami __smoke save-all <profile>`：選單列那條存檔路徑的探針。
///
/// 它存在的理由與 `__smoke snap` 逐字相同——**選單列那條路的失敗是看不見的**。
/// `saveSpaces` 把事件收進一個對話框，而對話框關掉之後就什麼都不剩；那條路又只有
/// 人按得到（`MenuActions` 的其餘幾支都有 CLI 的對應入口，這支沒有）。所以要問
/// 「為什麼存不進去」就只能有一個從終端機叫得到、走**同一個** `Interaction`
/// 的入口。搭 `TATAMI_DIR` 指到副本就完全碰不到線上設定。
@MainActor
func runSaveAllSmoke(_ profile: String) -> Never {
    print("要存的 profile：\(profile)")
    print("layout.json：\(TatamiPaths().layout)")
    print("---")
    print(MenuActions.saveSpaces(profile: profile, overwrite: false))
    exit(0)
}
