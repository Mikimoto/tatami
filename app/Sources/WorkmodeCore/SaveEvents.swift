import WorkmodeDomain

// `save_layout`（workmode.sh:1064-1254）。26 個站點，是全部事件裡最大的一組，
// 依這支函式自己的五個階段切開：先擋掉不該存的、盤點畫面上有什麼、問視窗的名字、
// 把矩形反推成樹、最後寫檔。

/// 還沒開始盤點就退出。
public enum SaveRejection: Equatable, Sendable {
    /// workmode.sh:1071。沒有 controlling tty。
    case saveNeedsTerminal

    /// workmode.sh:1078。
    case saveLocationUnrecognized

    /// workmode.sh:1094。
    case saveProfileNameReserved

    /// workmode.sh:1095。
    case saveProfileNameHasSpace(profile: String)

    public var channel: OutputChannel {
        switch self {
        case .saveLocationUnrecognized, .saveNeedsTerminal, .saveProfileNameHasSpace,
             .saveProfileNameReserved:
            .stderr
        }
    }
}

/// 盤點畫面：哪些螢幕算數、上面有什麼視窗。
public enum SaveSurvey: Equatable, Sendable {
    /// workmode.sh:1098。
    case saveBannerShown(location: String, desc: String, profile: String)

    /// workmode.sh:1118。接上的螢幕不在這個地點的 displays 裡。
    case saveDisplayNotInLayout(uuid: String)

    /// workmode.sh:1127。
    case saveRoleDisplayNotConnected(role: String)

    /// workmode.sh:1132。
    case saveRoleHasNoVisibleSpace(role: String)

    /// workmode.sh:1144。
    case saveNothingToStore

    /// workmode.sh:1158。**這一句前面有一個空行**（格式字串以 `\n` 開頭），
    /// 那個空行是把一個個待命名的視窗隔開的。
    case saveWindowIntroduced(app: String, title: String)

    /// workmode.sh:1159。與上一句是兩個 `printf` 站點，所以是兩個 case（約定 1）。
    case saveWindowPosition(role: String, position: String)

    public var channel: OutputChannel {
        switch self {
        case .saveBannerShown, .saveDisplayNotInLayout, .saveRoleDisplayNotConnected,
             .saveRoleHasNoVisibleSpace, .saveWindowIntroduced, .saveWindowPosition:
            .stdout
        case .saveNothingToStore:
            .stderr
        }
    }
}

/// 問使用者這個視窗叫什麼。
public enum SaveNaming: Equatable, Sendable {
    /// workmode.sh:1160。**沒有結尾換行**——它是一個提示符，游標要停在同一行。
    case saveLabelPrompt(app: String)

    /// workmode.sh:1167。
    case saveLabelHasTab

    /// workmode.sh:1171。
    case saveLabelTaken(label: String)

    /// workmode.sh:1182。
    case saveTitleRuleIsExact(pattern: String)

    public var channel: OutputChannel {
        switch self {
        case .saveLabelHasTab, .saveLabelPrompt, .saveLabelTaken, .saveTitleRuleIsExact:
            .stdout
        }
    }
}

/// 把矩形反推成樹（`rects_to_tree`）時的回報。
public enum SaveShaping: Equatable, Sendable {
    /// workmode.sh:1194。
    case saveRoleNotSplittable(role: String)

    /// workmode.sh:1200。
    case saveRoleHasNoNamedWindow(role: String)

    /// workmode.sh:1209-1210。這一句是 **awk** 印的不是 printf，格式字串在那段
    /// awk 程式裡（`printf "  「%s」的比例 %s 存不下來…"`）。
    case saveRatioTooSmall(label: String, ratio: String)

    /// workmode.sh:1216。
    case saveRoleShape(role: String, shape: String)

    /// workmode.sh:1221。
    case saveNoTreeStored

    /// **沒有 bash 對應**（2026-09-10）。這個視窗與別人重疊，切不開，所以它被拿掉
    /// 讓同一個 space 上其餘的存得下來（`SaveLayout.splittable`）。
    ///
    /// **要點名是哪一個視窗**：只說「這個 space 有東西被丟掉」的話，使用者不知道
    /// 要去整理哪一扇窗。角色也帶著——`--save --all` 一趟會走過好幾個螢幕。
    ///
    /// 只在**拿掉之後真的存成了**才發。拿掉還是切不開的那條走
    /// `saveRoleNotSplittable`，那時整個角色一棵樹都沒存。
    case saveWindowLostToOverlap(role: String, label: String)

    public var channel: OutputChannel {
        switch self {
        case .saveRatioTooSmall, .saveRoleHasNoNamedWindow, .saveRoleShape,
             .saveWindowLostToOverlap:
            .stdout
        case .saveNoTreeStored, .saveRoleNotSplittable:
            .stderr
        }
    }
}

/// 驗證與寫檔。
public enum SaveWriting: Equatable, Sendable {
    /// `validate_layout` 對合併後的設定印的那整段（workmode.sh:1227 呼叫它）。
    ///
    /// 帶的是 `[LayoutProblem]` 而不是已經排好的文字：那段格式的唯一一份在
    /// Adapters 的 `renderProblems`，`workmode validate` 走的是同一份。
    case layoutValidationFailed(problems: [LayoutProblem])

    /// workmode.sh:1228。
    case saveMergedInvalid

    /// workmode.sh:1235。**沒有結尾換行**，同樣是提示符。
    case saveOverwritePrompt(profile: String)

    /// workmode.sh:1239。使用者說不。bash 這條是 rc=0。
    case saveCancelled

    /// workmode.sh:1249。
    case saveWriteFailed

    /// workmode.sh:1253。
    case saveWritten(path: String)

    /// **沒有 bash 對應**（2026-08-30 新增）。這一輪沒有被重新量過的 space 有幾個。
    ///
    /// `--save` 只量得準**目前可見**的那幾個 space：不可見的 space 上，yabai 更新樹
    /// 但不套 frame（實測 2026-08-30：對不可見的 space 下 swap，`split-child` 對調
    /// 而 `frame` 一動也不動），而 `--save` 是量 frame 再推回樹。
    ///
    /// 所以要說出來——不說的話使用者會以為整個 profile 都存了。**count 為 0 時
    /// 不發**（沒有東西沒動就不必說）。
    case saveSkippedInvisibleSpaces(count: Int)

    /// 選單列那條路（`Interaction.automatic`）替一個視窗自己推了一條規則。
    ///
    /// **不帶位置**。2026-09-10 早先這句話寫著「接在生效清單的尾端」，那是當時
    /// 唯一的落點；同一天 `RulePlacement` 接上去之後它就成了假的，而
    /// **這個事件在放位置之前就發出去了**（`invent` 只決定名字，落點在 `build`）。
    /// 要讓它講位置就得把整個迴圈搬到 `seat` 之後——而位置本來就不是可行動的資訊，
    /// 兩種落點使用者都不必做任何事。
    ///
    /// 與 `saveSkippedUnnamed` 放同一組（而不是 `SaveNaming`）：兩者是同一個迴圈
    /// 的兩種結果，拆到兩組去讀的人會以為它們是不同階段的事。
    case saveRuleInvented(label: String, match: String)

    /// 選單列那條路連 `AutoWindowName` 都推不出身分、因此沒進樹的視窗數。
    ///
    /// **要說出來**：不說的話使用者會以為那個視窗存進去了，而下次套用時它不會
    /// 出現——那是查不出來的。從終端機跑 `--save` 會逐一問名字，所以沒有這一句。
    case saveSkippedUnnamed(count: Int)

    public var channel: OutputChannel {
        switch self {
        case .saveCancelled, .saveOverwritePrompt, .saveRuleInvented,
             .saveSkippedInvisibleSpaces, .saveSkippedUnnamed, .saveWritten:
            .stdout
        case .layoutValidationFailed, .saveMergedInvalid, .saveWriteFailed:
            .stderr
        }
    }
}

/// `workmode --save` 的事件。
public enum SaveEvent: Equatable, Sendable {
    /// 不會寫檔了。
    case rejected(SaveRejection)

    /// 盤點畫面。
    case survey(SaveSurvey)

    /// 問名字。
    case naming(SaveNaming)

    /// 反推樹。
    case shaping(SaveShaping)

    /// 驗證與寫檔。
    case writing(SaveWriting)

    public var channel: OutputChannel {
        switch self {
        case let .rejected(event): event.channel
        case let .survey(event): event.channel
        case let .naming(event): event.channel
        case let .shaping(event): event.channel
        case let .writing(event): event.channel
        }
    }
}
