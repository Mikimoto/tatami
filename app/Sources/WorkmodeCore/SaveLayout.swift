import WorkmodeDomain

/// `save_layout`（workmode.sh:1064-1254）。把當下畫面上的版面存回 profile。
///
/// **只寫 windows 與 spaceTrees**，不動 exile／default／displays。沒接到的螢幕角色
/// 保留舊 profile 那棵樹——單螢幕存一次不該把另一台的設定洗掉。
///
/// **2026-08-30 之前寫的是 `trees`。** 現在每個角色底下多一層 space uuid：量得準的
/// 只有**目前可見**的那個 space（不可見的 space 上 yabai 更新樹但不套 frame，而這支
/// 是量 frame 再反推成樹），所以一次 `--save` 只換掉那幾個 uuid 的樹，同一個角色底下
/// 其他 space 的樹原封不動——`ProfileMerge.mergeSpaceTrees` 的兩層合併就是為了這件事（**不是 `merge`**——那一支是淺層的，只給 `__diff` 用）。
///
/// 這一支是整個移植裡唯一會**覆寫使用者設定檔**的東西，所以它的每一條失敗路徑都
/// 必須在寫檔**之前**就 return，而測試對每一條都要斷言 `writes` 是空的。
public struct SaveLayout {
    public enum Outcome: Equatable, Sendable {
        /// 寫進去了。
        case written(path: String)
        /// 使用者在覆寫確認那步說不。bash 這條是 **rc=0**（不是失敗）。
        case cancelled
        /// 任何一條「不寫檔」的路徑（rc=1）。
        case rejected
        /// 沒有 controlling tty。實測（2026-08-08）在那種情境下互動不是失敗而是
        /// **無聲卡住**（`timeout 3` 兩分鐘都收不掉），所以擋在最前面，
        /// 也因此這個指令不進 skhdrc。
        case needsTerminal
        case layoutUnavailable(LayoutLoadFailure)
    }

    // 不是 private：`SaveLayoutParts.swift` 的 `collectRects` 要用它，而
    // Swift 的 private 是**檔案**範圍（那個檔的檔頭記著同一個代價）。
    let yabai: any YabaiClient
    private let safari: any SafariClient
    // 不是 private：`SaveLayoutParts.swift` 的 `granted` 要用它（同一個檔頭記著
    // 的代價——Swift 的 private 是檔案範圍）。
    let terminal: any Terminal
    private let files: any FileStore
    private let loader: LayoutLoader
    private let stateReader: StateReader
    private let active: ActiveLocation
    let rules: RuleResolution
    private let layoutPath: String
    let renderRaw: (JSONValue) -> String
    /// `jq .` 的縮排格式。與 `renderRaw` 分開注入：一個是「印一個值」、一個是
    /// 「產生要寫回檔案的整份文字」，而後者要 Wire 的 writer（保留鍵序與數字字面值）。
    private let format: (JSONValue) -> String
    let reporter: any Reporter
    let reading: LayoutReading

    public init(yabai: any YabaiClient,
                safari: any SafariClient,
                terminal: any Terminal,
                files: any FileStore,
                layoutPath: String,
                statePath: String,
                parse: @escaping (String) throws -> JSONValue,
                renderRaw: @escaping (JSONValue) -> String,
                format: @escaping (JSONValue) -> String,
                reporter: any Reporter)
    {
        self.yabai = yabai
        self.safari = safari
        self.terminal = terminal
        self.files = files
        loader = LayoutLoader(files: files, path: layoutPath, parse: parse,
                              reporter: reporter)
        stateReader = StateReader(files: files, path: statePath)
        active = ActiveLocation(yabai: yabai, reporter: reporter)
        rules = RuleResolution(yabai: yabai, reporter: reporter)
        self.layoutPath = layoutPath
        self.renderRaw = renderRaw
        self.format = format
        self.reporter = reporter
        reading = LayoutReading(renderRaw: renderRaw)
    }

    /// 這一輪能不能問使用者。
    ///
    /// **`--save` 一直是互動式的**：它會逐一問「這個視窗要叫什麼」，最後問一次
    /// 要不要覆寫。選單列沒有 tty，所以那條路要另一個模式——而它必須是**明講的
    /// 兩種**，不是「有 tty 就問、沒有就不問」：後者會讓一個從快捷鍵誤觸的
    /// `--save` 安靜地把設定覆寫掉。
    public enum Interaction: Equatable, Sendable {
        /// 從終端機跑：先擋沒有 tty 的情況，逐一問名字，最後問覆寫。
        case terminal
        /// 沒有人可以問（選單列）：認不出名字的視窗**自己推一條規則**
        /// （`AutoWindowName`，接線在 `SaveAutoNames.swift`），推不出**穩定身分**的
        /// 才跳過（不進樹，發 `saveSkippedUnnamed`）。覆寫與否由呼叫端決定
        /// ——那個決定它已經在畫面上問過了。
        ///
        /// 2026-09-10 之前這條路是無條件跳過，而那正是使用者回報的症狀
        /// （「有一個不認識的 Safari 視窗，無法紀錄排版」）。
        case automatic(overwrite: Bool)
    }

    /// 要存哪些 space。**沒有預設值**（與 `SpaceLayout.Scope` 同一條）：
    /// `--save` 一直以來只存目前可見的那幾個，而 `--all` 會覆寫每一個有視窗的
    /// space 的樹——哪一個都不該是「忘了寫就得到的那個」。
    public enum Scope: Equatable, Sendable {
        /// 每個角色目前可見的那一個 space。
        case visible
        /// 那個角色的螢幕上**每一個有視窗的** space。
        case all
    }

    public func run(want: String, scope: Scope, interaction: Interaction) -> Outcome {
        // 這個守衛在**最前面**，在 load_layout 之前：沒有 tty 的話後面每一個問句都
        // 會無聲卡住，而不是失敗。
        // 這個守衛只在互動模式成立。選單列那條沒有 tty 也不需要——它不問任何問題。
        if interaction == .terminal, !terminal.hasControllingTTY {
            reporter.report(.saveNeedsTerminal)
            return .needsTerminal
        }

        let loaded: LayoutLoader.Loaded
        do {
            loaded = try loader.load()
        } catch let failure as LayoutLoadFailure {
            return .layoutUnavailable(failure)
        } catch {
            return .layoutUnavailable(.unreadable(path: ""))
        }
        let config = loaded.config
        let state = CommandSubstitution.capture(stateReader.read())

        guard let here = active.resolve(state: state, config: config) else {
            reporter.report(.saveLocationUnrecognized)
            return .rejected
        }
        let location = here.location
        let desc = reading.describe(location, in: config)

        let profile: String
        if !want.isEmpty {
            profile = want
        } else {
            // `resolve_profile "$location" "" "$state" "$json" || return 1`：這裡的
            // want 永遠是空字串，所以「指定的 profile 不存在」那條走不到；會失敗的
            // 只有設定本身壞掉那種。
            guard let chosen = try? ProfileResolution.resolve(location: location, want: "",
                                                              state: state, in: config,
                                                              renderRaw: renderRaw)
            else { return .rejected }
            profile = chosen.name
        }

        // 先擋掉必定過不了 validate_layout 的名字。不是多餘的：不擋的話使用者會先被
        // 問完一輪視窗名稱，最後才在驗證那步被打回票。
        if profile == reservedAuto {
            reporter.report(.saveProfileNameReserved)
            return .rejected
        }
        if profile.unicodeScalars.contains(where: isPOSIXSpace) {
            reporter.report(.saveProfileNameHasSpace(profile: profile))
            return .rejected
        }

        reporter.report(.saveBannerShown(location: location, desc: desc, profile: profile))
        return collect(config: config, location: location, profile: profile,
                       scope: scope, interaction: interaction)
    }

    // MARK: - 盤點畫面

    private func collect(config: JSONValue, location: String, profile: String,
                         scope: Scope, interaction: Interaction) -> Outcome
    {
        // keep 放**整份總表**的 label 而不是這次樹引用到的那些：存版面時整份總表都
        // 要拿來認。stderr 壓掉——總表本來就含這次沒開的視窗，「找不到」在這裡是
        // 正常的（workmode.sh:1102 的註解）。
        let catalog = reading.windowRulesText(location: location, profile: profile, in: config)
        let dump = CommandSubstitution.capture((try? safari.tabDump()) ?? "")
        let quiet = SilencedChannelReporter(dropping: .stderr, into: reporter)
        let resolved = RuleResolution(yabai: yabai, reporter: quiet)
            .resolve(rules: catalog, dump: dump, keep: labels(of: catalog))
        let idmap = idmapObject(from: resolved)

        let displays = (try? yabai.query(.displays)) ?? .null
        let spaces = (try? yabai.query(.spaces)) ?? .null

        // 接上但不在這個地點的 displays 裡的螢幕：講出來，不要靜默略過。
        let known = knownUUIDs(location: location, in: config)
        for uuid in connectedUUIDs(in: displays) where !known.contains(uuid) {
            reporter.report(.saveDisplayNotInLayout(uuid: uuid))
        }

        let roleRects = collectRects(
            config: config, location: location, scope: scope,
            snapshot: Snapshot(displays: displays, spaces: spaces, idmap: idmap)
        )

        let all = roleRects.flatMap { rectArray($0.rects) }
        if all.isEmpty {
            reporter.report(.saveNothingToStore)
            return .rejected
        }

        let named: Named
        switch interaction {
        case .terminal:
            guard let asked = askForNames(unnamed: all, catalog: catalog, dump: dump) else {
                return .rejected
            }
            named = asked
        case .automatic:
            // 認不出名字的視窗自己推一條規則；推不出身分的才跳過並說出來。
            // `catalog` 與 `existingAppRules` 讀的是同一份生效規則，只是一個要
            // label、一個要 catch-all 的 app。
            named = invent(unnamed: all, catalog: catalog, dump: dump,
                           appRules: existingAppRules(location: location,
                                                      profile: profile, in: config))
        }
        return build(config: config, location: location, profile: profile,
                     survey: Survey(rects: roleRects, scope: scope, interaction: interaction),
                     named: named)
    }

    /// 一個角色這一輪量到的東西：它自己、它**目前可見**的那個 space 的 uuid、
    /// 以及那個 space 上的矩形。uuid 一路帶到 `buildTrees`，因為
    /// `spaceTrees[角色][uuid]` 的第二層鍵只有這裡知道。
    struct RoleRects {
        let role: String
        let uuid: String
        let rects: JSONValue
    }

    struct Named {
        /// 帶著 app，因為決定落點的 `RulePlacement` 需要它而規則本身讀不出來
        /// （理由在 `NewRule` 的 doc）。
        let rules: [NewRule]
        let labels: [String: String]
        /// 這一輪**自己推**出來的那幾個 window id（`invent`）。
        ///
        /// `labels` 分不出「使用者打的」與「自己推的」，而 `splittable` 的退路只准
        /// 丟掉後者——丟掉前者等於把使用者剛剛回答過的東西靜默扔了。
        let invented: Set<String>
    }

    // MARK: - 組樹並寫檔

    /// `roleRects` 與 `scope` 包成一個：`build` 原本就有五個參數，
    /// 而 swiftlint 的 `function_parameter_count` 上限是 5（不准調參數）。
    struct Survey {
        let rects: [RoleRects]
        let scope: Scope
        let interaction: Interaction
    }

    private func build(config: JSONValue, location: String, profile: String,
                       survey: Survey,
                       named: Named) -> Outcome
    {
        guard let trees = buildTrees(roleRects: survey.rects, named: named) else {
            return .rejected
        }

        if trees.isEmpty {
            reporter.report(.saveNoTreeStored)
            return .rejected
        }

        // 先放位置再合併：插得進 catch-all 前面的那幾條這一步就寫好了，剩下的才
        // 交給 `mergeSpaceTrees` 接到落點尾端。反過來做的話那幾條會先被接到尾端，
        // 而「加了卻永遠不生效」與「沒加」在畫面上完全相同。
        let seated = seat(named.rules, location: location, profile: profile, in: config)
        guard let merged = try? ProfileMerge.mergeSpaceTrees(seated.config,
                                                             location: location,
                                                             profile: profile,
                                                             spaceTrees: .object(trees),
                                                             rules: .array(seated.remaining))
        else { return .rejected }

        let problems = LayoutValidator.validate(merged)
        if !problems.isEmpty {
            reporter.report(.layoutValidationFailed(problems: problems))
            reporter.report(.saveMergedInvalid)
            return .rejected
        }

        if profileExists(profile, location: location, in: config) {
            reporter.report(.saveOverwritePrompt(profile: profile))
            guard granted(survey.interaction) else {
                reporter.report(.saveCancelled)
                // bash 這條是 `return 0`——取消不是失敗。
                return .cancelled
            }
        }

        // 先寫暫存檔再換上去：中途失敗不會留下半份設定。
        do {
            try files.writeAtomically(format(merged), toPath: layoutPath)
        } catch {
            reporter.report(.saveWriteFailed)
            return .rejected
        }
        reporter.report(.saveWritten(path: layoutPath))
        // **`--all` 底下不報這句**：沒被寫到的 space 是「上面沒有視窗」，
        // 不是「因為看不見所以量不到」。照報的話那句話會叫使用者去切過去再存一次，
        // 而那件事什麼都不會改變。
        if survey.scope == .visible {
            let skipped = untouchedSpaceCount(config: config, location: location,
                                              profile: profile, written: trees)
            if skipped > 0 {
                reporter.report(.saveSkippedInvisibleSpaces(count: skipped))
            }
        }
        return .written(path: layoutPath)
    }
}

/// `case "$profile" in *[[:space:]]*)`。POSIX 的空白類，不是 Unicode 的——
/// 全形空白 U+3000 過得了這一關（而 `validate_layout` 用的 `\s` 擋得掉它，
/// 那兩個判斷的寬度不同是既有行為）。
func isPOSIXSpace(_ scalar: Unicode.Scalar) -> Bool {
    scalar == " " || scalar == "\t" || scalar == "\n"
        || scalar == "\r" || scalar == "\u{0B}" || scalar == "\u{0C}"
}
