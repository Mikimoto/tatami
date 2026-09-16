import WorkmodeDomain

// 一行一個建構子，讓發事件的那一端維持扁平的寫法。
//
// 數量取決於怎麼數，所以把命令記在這裡而不是抄一個會漂掉的數字：
// `/usr/bin/grep -cE '^    static (func|var) ' EventFactories.swift` 現在是 **62**
// （2026-09-07 隨 `ApplyLayout` 退役刪掉 18 個之後；刪之前是 80，而這裡原本寫著
// 79——那個數字在刪除之前就已經漂掉一個了）。
//
// 巢狀 enum 給的是編譯期的窮舉保證（renderer 每一層都不准有 default），
// 但它會讓呼叫端寫成 `.layout(.restore(.minimizedWindowRestored(label:)))`。
// 那個分組是 renderer 的需要，不是呼叫端的——`ApplyLayout` 不該知道某句話
// 被歸在哪一組。所以分組留在型別裡，呼叫端照舊寫 `.minimizedWindowRestored(label:)`。
//
// 新增事件時這裡要跟著加一行。忘了加不會靜默：呼叫端根本叫不到。

public extension WorkmodeEvent {
    static func minimizedWindowRestored(label: String) -> WorkmodeEvent {
        .layout(.restore(.minimizedWindowRestored(label: label)))
    }

    static func minimizedWindowRestoreFailed(label: String) -> WorkmodeEvent {
        .layout(.restore(.minimizedWindowRestoreFailed(label: label)))
    }

    static func treeRoleHasNoDisplay(role: String) -> WorkmodeEvent {
        .layout(.role(.treeRoleHasNoDisplay(role: role)))
    }

    static var noRulesResolved: WorkmodeEvent {
        .rules(.noRulesResolved)
    }

    static func ruleWindowPositionReported(label: String, id: String, display: String,
                                           space: String,
                                           frame: ReportedFrame) -> WorkmodeEvent
    {
        .rules(.ruleWindowPositionReported(label: label, id: id, display: display,
                                           space: space, frame: frame))
    }

    static func ruleMatchedMultipleWindows(label: String,
                                           count: Int,
                                           candidates: [String]) -> WorkmodeEvent
    {
        .rules(.ruleMatchedMultipleWindows(label: label, count: count, candidates: candidates))
    }

    static func ruleCandidatesAllClaimed(label: String) -> WorkmodeEvent {
        .rules(.ruleCandidatesAllClaimed(label: label))
    }

    static func ruleWindowNotFound(label: String,
                                   matchType: String,
                                   matchValue: String) -> WorkmodeEvent
    {
        .rules(.ruleWindowNotFound(label: label, matchType: matchType, matchValue: matchValue))
    }

    static func appNotRunning(app: String) -> WorkmodeEvent {
        .session(.app(.appNotRunning(app: app)))
    }

    static func appLaunchFailed(app: String) -> WorkmodeEvent {
        .session(.app(.appLaunchFailed(app: app)))
    }

    static func appLaunched(app: String, waitedSeconds: Int) -> WorkmodeEvent {
        .session(.app(.appLaunched(app: app, waitedSeconds: waitedSeconds)))
    }

    static func appLaunchTimedOut(app: String, seconds: Int) -> WorkmodeEvent {
        .session(.app(.appLaunchTimedOut(app: app, seconds: seconds)))
    }

    static func profileNotInLocation(want: String,
                                     location: String,
                                     available: String) -> WorkmodeEvent
    {
        .session(.mode(.profileNotInLocation(want: want, location: location, available: available)))
    }

    static var usageRejected: WorkmodeEvent {
        .session(.mode(.usageRejected))
    }

    static var locationUnrecognized: WorkmodeEvent {
        .session(.mode(.locationUnrecognized))
    }

    static func connectedDisplayListed(uuid: String,
                                       width: String,
                                       height: String) -> WorkmodeEvent
    {
        .session(.mode(.connectedDisplayListed(uuid: uuid, width: width, height: height)))
    }

    static var manualLocationHinted: WorkmodeEvent {
        .session(.mode(.manualLocationHinted))
    }

    static func modeChosen(location: String,
                           desc: String,
                           overridden: Bool,
                           profile: String,
                           profileSource: ProfileResolution.Source) -> WorkmodeEvent
    {
        .session(.mode(.modeChosen(location: location, desc: desc, overridden: overridden,
                                   profile: profile, profileSource: profileSource)))
    }

    static func rememberedProfileGone(stale: String,
                                      location: String,
                                      profile: String) -> WorkmodeEvent
    {
        .session(.mode(.rememberedProfileGone(stale: stale, location: location, profile: profile)))
    }

    static var probeBannerShown: WorkmodeEvent {
        .session(.banner(.probeBannerShown))
    }

    static func layoutFileMissing(path: String) -> WorkmodeEvent {
        .session(.layoutFileMissing(path: path))
    }

    static func stateLocationNotInLayout(location: String) -> WorkmodeEvent {
        .session(.stateLocationNotInLayout(location: location))
    }

    static func switchArgumentEmpty(argument: String) -> WorkmodeEvent {
        .switching(.rejected(.switchArgumentEmpty(argument: argument)))
    }

    static func switchLocationUnknown(location: String, available: String) -> WorkmodeEvent {
        .switching(.rejected(.switchLocationUnknown(location: location, available: available)))
    }

    static var switchLocationUnresolved: WorkmodeEvent {
        .switching(.rejected(.switchLocationUnresolved))
    }

    static func switchProfileUnknown(want: String,
                                     location: String,
                                     available: String) -> WorkmodeEvent
    {
        .switching(.rejected(.switchProfileUnknown(want: want, location: location, available: available)))
    }

    static func stateFileUnwritable(path: String) -> WorkmodeEvent {
        .switching(.rejected(.stateFileUnwritable(path: path)))
    }

    static var switchHintShown: WorkmodeEvent {
        .switching(.applied(.switchHintShown))
    }

    static func locationOverrideCleared(detected: String) -> WorkmodeEvent {
        .switching(.applied(.locationOverrideCleared(detected: detected)))
    }

    static func locationPinned(location: String) -> WorkmodeEvent {
        .switching(.applied(.locationPinned(location: location)))
    }

    static func profileMemoryCleared(location: String) -> WorkmodeEvent {
        .switching(.applied(.profileMemoryCleared(location: location)))
    }

    static func profilePinned(location: String, profile: String) -> WorkmodeEvent {
        .switching(.applied(.profilePinned(location: location, profile: profile)))
    }

    static var pickerMissing: WorkmodeEvent {
        .switching(.picker(.pickerMissing))
    }

    static func pickerFallbackLocations(available: String) -> WorkmodeEvent {
        .switching(.picker(.pickerFallbackLocations(available: available)))
    }

    static var pickerLocationUnresolvedAfterAuto: WorkmodeEvent {
        .switching(.picker(.pickerLocationUnresolvedAfterAuto))
    }

    static var saveNeedsTerminal: WorkmodeEvent {
        .save(.rejected(.saveNeedsTerminal))
    }

    static var saveLocationUnrecognized: WorkmodeEvent {
        .save(.rejected(.saveLocationUnrecognized))
    }

    static var saveProfileNameReserved: WorkmodeEvent {
        .save(.rejected(.saveProfileNameReserved))
    }

    static func saveProfileNameHasSpace(profile: String) -> WorkmodeEvent {
        .save(.rejected(.saveProfileNameHasSpace(profile: profile)))
    }

    static func saveBannerShown(location: String, desc: String, profile: String) -> WorkmodeEvent {
        .save(.survey(.saveBannerShown(location: location, desc: desc, profile: profile)))
    }

    static func saveDisplayNotInLayout(uuid: String) -> WorkmodeEvent {
        .save(.survey(.saveDisplayNotInLayout(uuid: uuid)))
    }

    static func saveRoleDisplayNotConnected(role: String) -> WorkmodeEvent {
        .save(.survey(.saveRoleDisplayNotConnected(role: role)))
    }

    static func saveRoleHasNoVisibleSpace(role: String) -> WorkmodeEvent {
        .save(.survey(.saveRoleHasNoVisibleSpace(role: role)))
    }

    static var saveNothingToStore: WorkmodeEvent {
        .save(.survey(.saveNothingToStore))
    }

    static func saveWindowIntroduced(app: String, title: String) -> WorkmodeEvent {
        .save(.survey(.saveWindowIntroduced(app: app, title: title)))
    }

    static func saveWindowPosition(role: String, position: String) -> WorkmodeEvent {
        .save(.survey(.saveWindowPosition(role: role, position: position)))
    }

    static func saveLabelPrompt(app: String) -> WorkmodeEvent {
        .save(.naming(.saveLabelPrompt(app: app)))
    }

    static var saveLabelHasTab: WorkmodeEvent {
        .save(.naming(.saveLabelHasTab))
    }

    static func saveLabelTaken(label: String) -> WorkmodeEvent {
        .save(.naming(.saveLabelTaken(label: label)))
    }

    static func saveTitleRuleIsExact(pattern: String) -> WorkmodeEvent {
        .save(.naming(.saveTitleRuleIsExact(pattern: pattern)))
    }

    static func saveRoleNotSplittable(role: String) -> WorkmodeEvent {
        .save(.shaping(.saveRoleNotSplittable(role: role)))
    }

    static func saveRoleHasNoNamedWindow(role: String) -> WorkmodeEvent {
        .save(.shaping(.saveRoleHasNoNamedWindow(role: role)))
    }

    static func saveRatioTooSmall(label: String, ratio: String) -> WorkmodeEvent {
        .save(.shaping(.saveRatioTooSmall(label: label, ratio: ratio)))
    }

    static func saveRoleShape(role: String, shape: String) -> WorkmodeEvent {
        .save(.shaping(.saveRoleShape(role: role, shape: shape)))
    }

    static func saveWindowLostToOverlap(role: String, label: String) -> WorkmodeEvent {
        .save(.shaping(.saveWindowLostToOverlap(role: role, label: label)))
    }

    static var saveNoTreeStored: WorkmodeEvent {
        .save(.shaping(.saveNoTreeStored))
    }

    static func layoutValidationFailed(problems: [LayoutProblem]) -> WorkmodeEvent {
        .save(.writing(.layoutValidationFailed(problems: problems)))
    }

    static var saveMergedInvalid: WorkmodeEvent {
        .save(.writing(.saveMergedInvalid))
    }

    static func saveOverwritePrompt(profile: String) -> WorkmodeEvent {
        .save(.writing(.saveOverwritePrompt(profile: profile)))
    }

    static var saveCancelled: WorkmodeEvent {
        .save(.writing(.saveCancelled))
    }

    static var saveWriteFailed: WorkmodeEvent {
        .save(.writing(.saveWriteFailed))
    }

    static func saveRuleInvented(label: String, match: String) -> WorkmodeEvent {
        .save(.writing(.saveRuleInvented(label: label, match: match)))
    }

    static func saveSkippedUnnamed(count: Int) -> WorkmodeEvent {
        .save(.writing(.saveSkippedUnnamed(count: count)))
    }

    static func saveSkippedInvisibleSpaces(count: Int) -> WorkmodeEvent {
        .save(.writing(.saveSkippedInvisibleSpaces(count: count)))
    }

    static func saveWritten(path: String) -> WorkmodeEvent {
        .save(.writing(.saveWritten(path: path)))
    }
}

// MARK: - 快捷鍵（`HotkeyEvents.swift`）

public extension WorkmodeEvent {
    static var hotkeyNoFocusedWindow: WorkmodeEvent {
        .hotkey(.hotkeyNoFocusedWindow)
    }

    static func hotkeyNoNeighbour(direction: String) -> WorkmodeEvent {
        .hotkey(.hotkeyNoNeighbour(direction: direction))
    }

    static func hotkeySpaceNotFound(target: String) -> WorkmodeEvent {
        .hotkey(.hotkeySpaceNotFound(target: target))
    }

    static func hotkeyDisplayNotFound(target: String) -> WorkmodeEvent {
        .hotkey(.hotkeyDisplayNotFound(target: target))
    }

    static func hotkeyBindingRejected(detail: String) -> WorkmodeEvent {
        .hotkey(.hotkeyBindingRejected(detail: detail))
    }

    static func hotkeyConflict(key: String) -> WorkmodeEvent {
        .hotkey(.hotkeyConflict(key: key))
    }

    static func hotkeyShellFailed(command: String, status: Int32) -> WorkmodeEvent {
        .hotkey(.hotkeyShellFailed(command: command, status: status))
    }

    static func hotkeyMouseTapInstalled(modifier: String) -> WorkmodeEvent {
        .hotkey(.hotkeyMouseTapInstalled(modifier: modifier))
    }

    static var hotkeyMouseTapRefused: WorkmodeEvent {
        .hotkey(.hotkeyMouseTapRefused)
    }

    static func hotkeysRegistered(count: Int, skipped: Int) -> WorkmodeEvent {
        .hotkey(.hotkeysRegistered(count: count, skipped: skipped))
    }
}
