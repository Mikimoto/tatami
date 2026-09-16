import WorkmodeDomain

/// `workmode --space`：把每個螢幕**當下可見**的那個 space，排成它在設定裡的那棵樹。
///
/// 與 `ApplyLayout` 刻意分開的兩件事（spec 的 D1／D3）：
///   * **不流放陌生視窗**。切過去看到的、不在樹裡的視窗一概不碰——送回「它自己的
///     space」需要每個 label 都有歸屬，而流放到同螢幕的另一個 space 時「另一個」
///     是哪一個很隨機，切過去之後又會看到它。
///   * **不聚集**。`trees` 那條路會把視窗抓到可見的 space 上，這一條不會：
///     這個 space 上沒有的視窗就是沒有。
///
/// **三種**「查不到」——螢幕沒接上（**螢幕在但 `displays` 回的 frame 缺欄位也算這一
/// 種**：沒有可視區就沒有畫布，而半份 frame 排出來的樹會把視窗丟到螢幕外，比不動更
/// 糟）、螢幕接著但抓不到可見的 space（含 uuid 不是字串的畸形回應）、這個 uuid 在
/// `spaceTrees` 裡沒有樹——都是**那個螢幕什麼都不做**，
/// 各自發一個事件說明理由然後 `continue`。
/// 一個角色查不到不該讓其他角色跟著不動；三種**各有**一條「後面還有角色」的護欄測試
/// （2026-08-22 的 verifier 抓到其中兩種原本沒有，把 `continue` 改成 `return` 全綠）。
/// 2026-08-30 之前是四種：名字那一層拿掉之後，「space 沒命名」與「名字沒有樹」
/// 併成同一件事。
///
/// 開場（讀設定 → 認地點 → 決定 profile）與 `workmode` 共用 `LayoutPreamble`：
/// 兩條路徑若各自決定 profile，同一台機器上它們會套到不同的版面而沒有任何訊息。
public struct SpaceLayout {
    public enum Outcome: Equatable, Sendable {
        case completed(location: String, profile: String)
        case layoutUnavailable(LayoutLoadFailure)
        case locationUnrecognized
        case profileUnresolved

        init(_ failure: LayoutPreamble.Failure) {
            switch failure {
            case let .layoutUnavailable(reason): self = .layoutUnavailable(reason)
            case .locationUnrecognized: self = .locationUnrecognized
            case .profileUnresolved: self = .profileUnresolved
            }
        }
    }

    /// 一個查得到樹的螢幕。`spaceText` 是要餵給 `moveToSpace` 的 space index（一段
    /// 文字；yabai 與 `WindowServerClient` 都吃 mission control 編號的文字）。
    /// `canvas` 是那台螢幕的可視區（已套過學到的頂端 inset），也就是這棵樹要被排進去
    /// 的畫布。`display` 是那台螢幕的 uuid——inset 是**逐螢幕**學的（每台螢幕各有自己
    /// 的選單列），所以寫回狀態檔時要用它當 key。
    struct Target {
        let role: String
        let uuid: String
        let display: String
        let tree: JSONValue
        let spaceText: String
        let canvas: FrameLayout.Canvas
    }

    private let yabai: any YabaiClient
    private let safari: any SafariClient
    // internal 而不是 private：`SpaceTargets.swift` 的 extension 要用。
    let reporter: any Reporter
    private let reading: LayoutReading
    private let parse: (String) throws -> JSONValue
    let renderRaw: (JSONValue) -> String
    private let preamble: LayoutPreamble
    private let rules: RuleResolution
    private let minimized: MinimizedWindows
    /// 只有 probe 用得到。套用那條路報的是 `frameRejected` 那類實際結果，
    /// 不是「這條規則配到哪個視窗」。
    private let positions: RulePositionReport
    private let frames: FrameLayout
    private let files: any FileStore
    private let statePath: String
    private let stateReader: StateReader
    private let presence: AppPresence?

    /// **`presence` 是 optional，nil ＝ 這一輪一個 app 都不開。**
    ///
    /// 這裡原本寫「比 `ApplyLayout` 少收兩個 port（`apps`／`launcher` 與它們帶來的
    /// `AppPresence`）：少收不是省事——收了就會有人用，而用了就多一條要驗的路徑」。
    /// 2026-09-07 改變主意，理由是那條路徑本來就存在、只是**沒有訊號**：樹裡引用的
    /// app 沒開時那個葉靜默排不到，畫面上只是「那個視窗沒出現」，沒有任何一句話。
    ///
    /// 「收了就會有人用」那個顧慮改用型別擋：**這條路徑預設仍然什麼都不開**，
    /// 只有 `tatami --space --launch` 那一個入口會建 `AppPresence` 傳進來。
    /// `__space-signal`（每次切 space 都會觸發）與編輯器的 ⌘R 一律傳 nil——
    /// 自動開 app 一律生效的話，切個 space 就會開一堆。
    ///
    /// 要開哪些 app 由 `LaunchableApps.named` 從設定推出來，**不是**像
    /// `ApplyLayout` 那樣寫死 `Ghostty` 與 `Safari`（那兩個名字是從 bash 抄的）。
    ///
    /// **`clock` 與 `MinimizedWindows` 原本也不收，2026-08-29 收了回來。** 當時的理由是
    /// 「不等還原動畫」，而實測那讓最小化的視窗在這條路徑上變成一個**看不見的洞**：
    /// `moveToSpace` 對它有效（實測 space 2 → 1），但 `--warp` 對不在 bsp 樹裡的視窗
    /// 回「not managed」，於是它被搬到對的 space 卻仍然縮著、樹也沒排成——畫面上就是
    /// 「切過去它沒出現」，而唯一的訊號是一句 warp 警告。
    ///
    /// 範圍是精準的：`restore(map:)` 只走 `resolved`，而這條路徑的 `resolved` 已經被
    /// `keep` 限縮成「這一輪要套的那幾棵樹引用到的 label」。所以只有寫進 `spaceTrees`
    /// 的視窗會被叫出來，使用者刻意縮起來的其他視窗一概不碰。
    public init(yabai: any YabaiClient,
                server: any WindowServer,
                safari: any SafariClient,
                clock: any Clock,
                files: any FileStore,
                layoutPath: String,
                statePath: String,
                parse: @escaping (String) throws -> JSONValue,
                renderRaw: @escaping (JSONValue) -> String,
                reporter: any Reporter,
                presence: AppPresence?)
    {
        self.presence = presence
        self.yabai = yabai
        self.safari = safari
        self.reporter = reporter
        self.parse = parse
        self.renderRaw = renderRaw
        reading = LayoutReading(renderRaw: renderRaw)
        preamble = LayoutPreamble(
            yabai: yabai, reporter: reporter,
            reading: LayoutReading(renderRaw: renderRaw), renderRaw: renderRaw,
            loader: LayoutLoader(files: files, path: layoutPath,
                                 parse: parse, reporter: reporter),
            stateReader: StateReader(files: files, path: statePath),
            activeLocation: ActiveLocation(yabai: yabai, reporter: reporter)
        )
        self.files = files
        self.statePath = statePath
        stateReader = StateReader(files: files, path: statePath)
        rules = RuleResolution(yabai: yabai, reporter: reporter)
        minimized = MinimizedWindows(yabai: yabai, clock: clock, reporter: reporter)
        positions = RulePositionReport(yabai: yabai, reporter: reporter)
        frames = FrameLayout(yabai: yabai, server: server, reporter: reporter)
    }

    /// 套用，或只辨識。
    ///
    /// `probe` 2026-09-07 從 `ApplyLayout` 搬過來（那一支連同裸 `tatami <profile>`
    /// 一起退役）。**做成這一支的一個模式而不是另一支命令**：probe 的價值全在
    /// 「它報的就是真的會用的那一份」，各走一條路的話它遲早報一個與實際不同的答案，
    /// 而那比沒有 probe 更糟。
    ///
    /// 這也推翻了 `EditorController` 那段「`SpaceLayout` 沒有 probe 模式而刻意不加」
    /// ——當時的理由是「加了只為了確認框的一句抬頭文字」，那仍然成立（⌘R 還是不用
    /// probe）；現在加它的理由是使用者要一個查規則的工具。
    public enum Mode: Equatable, Sendable {
        case apply
        case probe
    }

    /// 排哪些 space。
    ///
    /// `.visible` 是原本的行為：每台螢幕只排**當下可見**那一個。`.all`（`--all`）
    /// 排這個 profile 底下**每一棵有樹的 space**，不管可不可見——2026-09-08 加，
    /// 成因是拔插螢幕之後 macOS 會重排哪個 space 在哪台、哪個可見：那時 `main` 上
    /// 可見的可能是一個**家裡的** space（office 底下沒有它的樹），`.visible` 就把
    /// 整台跳過，而 Ghostty 的樹掛在旁邊那個不可見的 space 上，永遠不會被走到
    /// （2026-09-08 用 IS/IS-NOT 追出來的，probe 印的正是「這個 space 還沒有版面，跳過」）。
    ///
    /// `.all` 做得到是因為這條引擎對不可見的 space 設 frame 與搬視窗都有效
    /// （CLAUDE.md 引擎那一節的實測）——yabai 那條路做不到這件事，所以以前沒有這個選項。
    public enum Scope: Equatable, Sendable {
        case visible
        case all
    }

    /// - Parameter mode: **沒有預設值**，三個組裝點各自明寫。與 `presence` 同一條
    ///   理由：預設值等於留著「忘了傳就靜默搬視窗」那個洞。
    /// - Parameter scope: 同樣**沒有預設值**。`__space-signal` 與選單的「重排目前可見」
    ///   一定是 `.visible`——切個 space 就把十個 space 全部重排一遍，那不是任何人的意圖。
    public func run(want: String, mode: Mode, scope: Scope) -> Outcome {
        let config: JSONValue
        let choice: ProfileChoice
        let location: String
        switch preamble.decide(want: want) {
        case let .ready(decided):
            config = decided.config
            choice = decided.choice
            location = decided.location
        case let .failed(failure):
            return Outcome(failure)
        }

        let spaceTrees = (try? reading.member(config, location, "profiles",
                                              choice.name, "spaceTrees")) ?? .null
        // 狀態檔在這裡讀一次：`resolveTargets` 要拿它算畫布（套 inset），而收尾
        // 寫回時也要以它為基準比對「值有沒有變」。
        let state = stateReader.read()
        let targets = resolveTargets(spaceTrees: spaceTrees, location: location,
                                     config: config, state: state, scope: scope)

        // 規則解析放在 targets 之後：要套的樹決定了 `keep`，而 `keep` 是「這一輪
        // 需不需要 Safari 的分頁」唯一的判準（那一趟實測 1.94 秒）。
        // 讀不出來就是空陣列＝`keep` 空字串，與這裡原本那個 `else ""` 同一件事。
        let labels = (try? treesOf(targets)) ?? []
        let keep = labels.map(renderRaw).joined(separator: "\n")

        // **在 `rules.resolve` 之前**，而且是在 Safari 的分頁 dump 之前：
        //   * 解析之後才發現沒視窗、再開、再解析一次，等於付兩次 dump 的 1.94 秒。
        //   * dump 那道閘門問的是「這些 space 上有沒有 Safari 視窗」，所以 Safari
        //     要開就得開在那個問題之前，不然它這一輪的分頁一定拿不到。
        // probe 不開 app：那條路徑上**一個會改變狀態的命令都不下**是它的定義，
        // 而 `open -a` 是會改變狀態的。`presence` 本來就是 nil 時這一行是 no-op，
        // 但 probe 不靠呼叫端傳對——那個保證要在這裡。
        if mode == .apply {
            launchApps(labels: labels, location: location, profile: choice.name, in: config)
        }

        let dump = needsSafariTabs(keep: keep, location: location, profile: choice.name,
                                   in: config, targets: targets)
            ? CommandSubstitution.capture((try? safari.tabDump()) ?? "")
            : ""
        let resolved = rules.resolve(
            rules: reading.windowRulesText(location: location, profile: choice.name, in: config),
            dump: dump, keep: keep
        )

        if mode == .probe {
            reporter.report(.probeBannerShown)
            positions.report(rules: resolved)
            // **到這裡一個會改變狀態的命令都沒下過**：上面只有 query 與（可能的）
            // Safari 分頁 dump，兩個都是讀。
            return .completed(location: location, profile: choice.name)
        }

        // **在 `applyTargets` 之前**：`--warp` 對最小化的視窗回「not managed」，
        // 所以還原必須先於排版，否則那個視窗只會被搬到對的 space 而仍然縮著。
        minimized.restore(map: resolved)

        rememberTopInsets(applyTargets(targets, resolved: resolved), state: state)
        return .completed(location: location, profile: choice.name)
    }

    /// `--launch`：把這一輪的樹引用到、而目前沒在跑的 app 開起來。
    ///
    /// `presence` 是 nil 就**一個 port 都不碰**——不是「查了發現不用開」，是連
    /// `AppQuery.isRunning` 都不問。那是預設的行為（見 `init` 的 doc）。
    ///
    /// `ensure` 的回傳值刻意不看，與 `ApplyLayout` 同一個理由：開不起來就讓那條規則
    /// 自己走「找不到視窗」，它已經有自己的訊息了。
    private func launchApps(labels: [JSONValue], location: String, profile: String,
                            in config: JSONValue)
    {
        guard let presence else { return }
        for app in LaunchableApps.named(labels: labels, location: location,
                                        profile: profile, in: config)
        {
            presence.ensure(app: app)
        }
    }

    /// 逐螢幕解析「這個角色現在該套哪一棵樹」。查不到就發事件並跳過。
    private func resolveTargets(spaceTrees: JSONValue, location: String,
                                config: JSONValue, state: String, scope: Scope) -> [Target]
    {
        // 兩個 query 在這裡而不是呼叫端：它們只有這支要用，而參數表已經是
        // swiftlint 的上限（5 個）。與 `ApplyLayout` 一樣沒有 `2>/dev/null`——
        // 失敗時後面每個角色都走「螢幕沒接上」，`.null` 是同一個下場。
        let displays = (try? yabai.query(.displays)) ?? .null
        let spaces = (try? yabai.query(.spaces)) ?? .null
        var out: [Target] = []
        for role in reading.roles(of: spaceTrees) {
            guard let uuid = reading.displayUUID(of: role, location: location, in: config) else {
                reporter.report(.space(.spaceRoleDisplayMissing(role: role)))
                continue
            }
            let indexText = reading.displayIndexText(forUUID: uuid, in: displays)
            guard !indexText.isEmpty, let index = try? parse(indexText),
                  let visible = (try? Displays.visibleSpaceObject(on: index, in: spaces)) ?? nil
            else {
                reporter.report(.space(indexText.isEmpty
                        ? .spaceRoleDisplayMissing(role: role)
                        : .spaceRoleHasNoVisibleSpace(role: role)))
                continue
            }
            // 沒有 frame 就沒有畫布。與「螢幕沒接上」同一個下場——半份 frame 排出來的
            // 樹會把視窗放到螢幕外，那比不動更糟。
            guard let frame = Displays.frame(ofIndexText: indexText, in: displays) else {
                reporter.report(.space(.spaceRoleDisplayMissing(role: role)))
                continue
            }
            let canvas = canvas(of: frame, display: uuid, state: state)
            if scope == .all {
                out += allTargets(at: RoleSite(role: role, display: uuid,
                                               displayIndex: index, canvas: canvas),
                                  spaces: spaces, spaceTrees: spaceTrees)
                continue
            }
            guard case let .string(spaceUUID)? = visible["uuid"] else {
                // uuid 不是字串＝ yabai 回了預期外的形狀。與「抓不到可見的 space」
                // 同一個下場：這個螢幕什麼都不做。
                reporter.report(.space(.spaceRoleHasNoVisibleSpace(role: role)))
                continue
            }
            guard let tree = SpaceNames.tree(role: role, uuid: spaceUUID, in: spaceTrees) else {
                reporter.report(.space(.spaceHasNoTree(role: role, uuid: spaceUUID)))
                continue
            }
            out.append(Target(role: role, uuid: spaceUUID, display: uuid, tree: tree,
                              spaceText: renderRaw(visible["index"] ?? .null),
                              canvas: canvas))
        }
        return out
    }

    /// 螢幕的 frame ＋ 已學到的頂端 inset ＝ 這棵樹真正排得進去的畫布。
    ///
    /// 少了這一步，頂端那一列的每個視窗都會被 macOS 往下推（實測 30pt，見 `TopInset`），
    /// 於是每一個都被誤報成 `frameRejected`，而且各自等滿 `setFrame` 的輪詢預算。
    ///
    /// 算式本體在 `LayoutCanvas`——`grid` 用同一支。
    private func canvas(of frame: Rect, display: String, state: String) -> FrameLayout.Canvas {
        LayoutCanvas.of(frame: frame, display: display, state: state)
    }

    /// 把這一輪學到的 inset 寫回狀態檔。值沒變就一個字都不寫（見 `TopInset.writing`）。
    private func rememberTopInsets(_ observed: [String: Double], state: String) {
        guard let next = TopInset.writing(observed, into: state) else { return }
        do {
            try files.write(next, toPath: statePath)
        } catch {
            reporter.report(.stateFileUnwritable(path: statePath))
        }
    }

    /// 這一輪需不需要 Safari 的分頁清單。**兩個條件都成立才付那 1.94 秒**
    /// （13 視窗／93 分頁實測，三次 1.94／1.94／1.96）。
    ///
    /// 1. 這一輪要套的樹引用到 url 類規則的 label（`fallback` **也算**——規則配不到
    ///    `match` 時會退到它，而它同樣可能是 url 類。漏掉 fallback 的症狀是
    ///    「這個視窗有時候排得到、有時候排不到」）。
    /// 2. 那些 space 上真的有 Safari 視窗。
    ///
    /// 兩個判斷加起來 0.01 秒級（`query --windows --space` 實測 0.01 秒）。
    /// `ApplyLayout` **沒有**這道閘門（`ApplyLayout.swift` 是無條件 dump），那是
    /// 因為它是使用者按了才跑；`--space` 之後會掛在 signal 上，每次切 space 兩秒
    /// 不能接受。
    private func needsSafariTabs(keep: String, location: String, profile: String,
                                 in config: JSONValue, targets: [Target]) -> Bool
    {
        let wanted = Set(keep.split(separator: "\n").map(String.init))
        var urlRuleInPlay = false
        try? LayoutQuery.windowRules(location: location, profile: profile, in: config) { rule in
            guard wanted.contains(renderRaw(rule.label)) else { return }
            for kind in [rule.matchKind, rule.fallbackKind] {
                if case let .string(text) = kind,
                   text == WindowMatching.Kind.urlExact.rawValue
                   || text == WindowMatching.Kind.urlContains.rawValue
                {
                    urlRuleInPlay = true
                }
            }
        }
        guard urlRuleInPlay else { return false }
        return targets.contains { hasSafari(onSpace: $0.spaceText) }
    }

    private func hasSafari(onSpace space: String) -> Bool {
        guard case let .array(windows)? = try? yabai.query(.windowsOnSpace(space))
        else { return false }
        return windows.contains { $0["app"] == .string("Safari") }
    }

    /// 只有**這一輪真的要套的**那些樹引用到的 label。`keep` 與 Safari 的閘門都吃它。
    private func treesOf(_ targets: [Target]) throws -> [JSONValue] {
        try LayoutTree.referencedLabels(.object(targets.enumerated().map { index, target in
            JSONMember(key: "\(index)", value: target.tree)
        }))
    }

    /// - Returns: display uuid → 這一輪量到的頂端 inset。同一台螢幕上有多個角色時
    ///   取較大的那個（`max`），理由與 `FrameLayout` 裡那個 `max` 相同：夾得最多的
    ///   那個樣本才是真正的下限。
    private func applyTargets(_ targets: [Target], resolved: String) -> [String: Double] {
        let live = reading.liveLabels(of: resolved)
        var observed: [String: Double] = [:]
        for target in targets {
            guard let pruned = (try? LayoutTree.prune(target.tree, live: live)) ?? nil,
                  let applied = frames.layout(space: target.spaceText, tree: pruned,
                                              in: target.canvas, map: resolved)
            else {
                reporter.report(.space(.spaceHasNoTree(role: target.role, uuid: target.uuid)))
                continue
            }
            if let inset = applied.observedTopInset {
                observed[target.display] = max(observed[target.display] ?? 0, inset)
            }
            reporter.report(.space(.spaceLaidOut(role: target.role, uuid: target.uuid)))
        }
        return observed
    }
}
