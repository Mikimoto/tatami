import Foundation
import WorkmodeCore

// `ProfileResolution.Source` 是 `modeChosen` 的欄位。
import WorkmodeDomain

// 一個 bash printf 站點 = 一個 case，而 case 分佈在 WorkmodeEvent 的巢狀 enum 上
// （見 WorkmodeCore/Reporter.swift 的約定 1 與 5）。這裡照那個形狀一層一支 switch：
// 每一支都窮舉、都沒有 default，所以少寫一個 case 是編譯錯誤而不是執行時的空字串。

/// 人看的輸出。每個 case 對應 workmode.sh 的一個 `printf`，格式字串逐字照抄。
///
/// 縮排的兩個空白也是照抄的：`main` 印的段落標題沒有縮排，函式內的細項有，
/// 所以那兩個空白帶的是「這是某個步驟的細項」這個資訊，不是排版裝飾。
public struct HumanEventRenderer: EventRenderer, Sendable {
    public init() {}

    public func render(_ event: WorkmodeEvent) -> String {
        switch event {
        case let .layout(event): render(layout: event)
        case let .rules(event): render(rules: event)
        case let .session(event): render(session: event)
        case let .switching(event): render(switching: event)
        case let .space(event): render(space: event)
        case let .save(event): render(save: event)
        case let .hotkey(event): render(hotkey: event)
        }
    }

    private func render(layout: LayoutEvent) -> String {
        switch layout {
        case let .restore(event): render(restore: event)
        case let .role(event): render(role: event)
        }
    }

    private func render(session: SessionEvent) -> String {
        switch session {
        // workmode.sh:109
        case let .layoutFileMissing(path):
            "! 找不到設定檔：\(path)\n"
        // workmode.sh:569
        case let .stateLocationNotInLayout(location):
            "  ! 狀態檔的 location 寫著「\(location)」，不在 layout.json 裡，忽略後改用自動偵測\n"
        case let .app(event): render(app: event)
        case let .mode(event): render(mode: event)
        case let .banner(event): render(banner: event)
        }
    }

    /// `--space` 那四句。**沒有 bash 對應**，所以沒有 oracle 釘著——語氣照既有慣例：
    /// 成功不加驚嘆號，沒做事的理由縮兩格（與 `treeRole*` 那組同一種）。
    private func render(hotkey: HotkeyEvent) -> String {
        switch hotkey {
        case .hotkeyNoFocusedWindow:
            "! 沒有焦點視窗（螢幕鎖著時 AX 讀不到任何視窗）\n"
        case let .hotkeyNoNeighbour(direction):
            "  \(direction) 沒有鄰居\n"
        case let .hotkeySpaceNotFound(target):
            "! 找不到 space「\(target)」\n"
        case let .hotkeyDisplayNotFound(target):
            "! 找不到螢幕「\(target)」\n"
        case let .hotkeyBindingRejected(detail):
            // 前綴由發事件的那一端給：同一個 case 也被 `tatami __hotkey <動作>`
            // 用，而那條路上沒有 hotkeys.json。
            "! \(detail)\n"
        case let .hotkeyConflict(key):
            "! 「\(key)」綁了兩次，只有第一條會生效\n"
        case let .hotkeyShellFailed(command, status):
            "! 命令失敗（rc=\(status)）：\(command)\n"
        case let .hotkeyMouseTapInstalled(modifier):
            "滑鼠拖曳：已裝上（修飾鍵 \(modifier)）\n"
        case .hotkeyMouseTapRefused:
            "! 裝不上滑鼠拖曳（系統拒絕了事件監聽）——其餘功能不受影響\n"
        case let .hotkeysRegistered(count, skipped):
            skipped == 0 ? "已註冊 \(count) 組快捷鍵\n"
                : "已註冊 \(count) 組快捷鍵，另有 \(skipped) 組被系統或別的 app 佔走\n"
        }
    }

    private func render(space: SpaceEvent) -> String {
        switch space {
        case let .spaceRoleDisplayMissing(role):
            "  \(role)：螢幕沒接上，跳過\n"
        case let .spaceRoleHasNoVisibleSpace(role):
            "  \(role)：找不到可見的 space，跳過\n"
        case let .spaceHasNoTree(role, uuid):
            "  \(role)：這個 space（\(uuid)）在這個 profile 底下還沒有版面，跳過\n"
        case let .spaceNotOnItsDisplay(role, uuid):
            "  \(role)：這個 space（\(uuid)）現在不在這台螢幕上（被刪了或跑到別台去），跳過\n"
        case let .spaceLaidOut(role, uuid):
            "\(role)：已套用 \(uuid) 的版面\n"
        case let .frameRejected(label, wanted, actual):
            "  ! 「\(label)」沒有接受指定的位置：要 \(describeRect(wanted))、實際 "
                + "\(actual.map(describeRect) ?? "設不下去")\n"
        }
    }

    /// `x,y w×h`，整數就好——這句話是給人對照畫面的，小數只會讓兩個數字看起來不同。
    private func describeRect(_ rect: Rect) -> String {
        "\(Int(rect.originX.rounded())),\(Int(rect.originY.rounded())) "
            + "\(Int(rect.width.rounded()))×\(Int(rect.height.rounded()))"
    }

    private func render(switching: SwitchEvent) -> String {
        switch switching {
        case let .rejected(event): render(switchRejection: event)
        case let .applied(event): render(switchOutcome: event)
        case let .picker(event): render(picker: event)
        }
    }

    private func render(save: SaveEvent) -> String {
        switch save {
        case let .rejected(event): render(saveRejection: event)
        case let .survey(event): render(saveSurvey: event)
        case let .naming(event): render(saveNaming: event)
        case let .shaping(event): render(saveShaping: event)
        case let .writing(event): render(saveWriting: event)
        }
    }

    private func render(app: AppEvent) -> String {
        switch app {
        // workmode.sh:624。結尾是刪節號 U+2026 一個字元，不是三個句點。
        case let .appNotRunning(app):
            "  \(app) 沒在跑，啟動中…\n"
        // workmode.sh:625
        case let .appLaunchFailed(app):
            "  ! 開不起來：\(app)\n"
        // workmode.sh:629
        case let .appLaunched(app, seconds):
            "  \(app) 已啟動（等了 \(seconds)s）\n"
        // workmode.sh:631。引數序是秒數先、app 後。
        case let .appLaunchTimedOut(app, seconds):
            "  ! 等了 \(seconds)s，\(app) 仍未啟動\n"
        }
    }

    private func render(mode: ModeEvent) -> String {
        switch mode {
        // workmode.sh:215
        case let .profileNotInLocation(want, location, available):
            return "! 「\(want)」不是 \(location) 底下的 profile。可用的有：\(available)\n"
        // 用法字串裡沒有 `%s`：不說是哪個旗標壞了（bash 的 workmode.sh:1262 也不說）。
        // 改名之後它不再對 bash，所以 tests/oracle/workmode-1262.line 那一列也拿掉了。
        case .usageRejected:
            // 開頭那個 `[profile]` 2026-09-07 拿掉了：裸的 `tatami <profile>` 已經
            // 退役，而這句話**就是**它被拒絕時印的那一句——留著等於用一句用法字串
            // 叫使用者去打一個會被自己拒絕的命令。
            return "用法：tatami [--probe [--all] [profile]]"
                + " [--switch [[地點]/[profile]]] [--save [--all] [profile]]"
                + " [--space [--launch] [--all]] [edit] [grid] [menu]\n"
        // 以下五句是 `echo` 不是 `printf`，所以那個換行是 echo 自己補的。
        // workmode.sh:1272
        case .locationUnrecognized:
            return "  ! 認不出這是哪個地點。當下接到的螢幕：\n"
        // workmode.sh:1274。**這一行是 jq 的字串插值印的**，與
        // `ruleWindowPositionReported` 同一種：`-r` 印完一個值補一個換行。
        case let .connectedDisplayListed(uuid, width, height):
            return "      \(uuid)  \(width)x\(height)\n"
        // workmode.sh:1275
        case .manualLocationHinted:
            return "      用 tatami --switch 手動指定，或把新地點加進 layout.json。\n"
        // workmode.sh:1294。兩個標記是 1280 與 1288-1292 的變數賦值（見下面兩支）。
        case let .modeChosen(location, desc, overridden, profile, source):
            // 兩個標記先落地成區域變數：全形括號緊接在插值後面時，編譯器的插值
            // 括號配對會誤讀（實測 `\(mark(overridden: x)）` 直接編不過）。
            let locationMark = mark(overridden: overridden)
            let profileMark = mark(of: source)
            return "== 地點：\(location)（\(desc)\(locationMark)）"
                + "· profile：\(profile)（\(profileMark)）==\n"
        // workmode.sh:1296
        case let .rememberedProfileGone(stale, location, profile):
            return "  ! 記住的 profile「\(stale)」在 \(location) 底下已經不存在，改用「\(profile)」\n"
        }
    }

    private func render(banner: BannerEvent) -> String {
        switch banner {
        // workmode.sh:1309
        case .probeBannerShown:
            "== probe：只辨識，不移動任何視窗 ==\n"
        }
    }

    private func render(switchRejection: SwitchRejection) -> String {
        switch switchRejection {
        // MARK: switch_setting／switch_interactive

        //
        // 961／969／982／988 那四句**不是 `printf` 站點**，是 `msgs="${msgs}…<換行>"`
        // 的多行字串賦值（workmode.sh 那幾行的字面換行就是訊息的結尾），所以它們
        // 沒有前導的兩個空白——那兩個空白是「某個步驟的細項」的記號，而這四句是
        // 對使用者說話的頂層訊息。
        // workmode.sh:949
        case let .switchArgumentEmpty(argument):
            "! 「\(argument)」沒有指定地點也沒有指定 profile。文法是 [地點]/[profile]。\n"
        // workmode.sh:964。字面的 ` auto` 是格式字串的一部分，不是 payload。
        case let .switchLocationUnknown(location, available):
            "! 沒有叫做「\(location)」的地點。可用的有：\(available) auto\n"
        // workmode.sh:976
        case .switchLocationUnresolved:
            "! 認不出當下的地點，無法決定要把 profile 記在哪裡。"
                + "先用 --switch <地點> 指定。\n"
        // workmode.sh:992。與 profileNotInLocation 差在尾巴這個 ` auto`。
        case let .switchProfileUnknown(want, location, available):
            "! 「\(want)」不是 \(location) 底下的 profile。可用的有：\(available) auto\n"
        // workmode.sh:1001
        case let .stateFileUnwritable(path):
            "! 寫不進狀態檔：\(path)\n"
        }
    }

    private func render(switchOutcome: SwitchOutcome) -> String {
        switch switchOutcome {
        // workmode.sh:1005
        case .switchHintShown:
            "跑 workmode.sh 套用佈局。\n"
        // workmode.sh:961
        case let .locationOverrideCleared(detected):
            "已清除地點覆寫，改回自動偵測（現在會選：\(detected)）\n"
        // workmode.sh:969
        case let .locationPinned(location):
            "已固定用地點 \(location)。\n"
        // workmode.sh:982
        case let .profileMemoryCleared(location):
            "已清除 \(location) 的 profile 記憶，之後會用該地點的預設。\n"
        // workmode.sh:988
        case let .profilePinned(location, profile):
            "已固定 \(location) 用 profile \(profile)。\n"
        }
    }

    private func render(picker: PickerEvent) -> String {
        switch picker {
        // workmode.sh:1017
        case .pickerMissing:
            "! 找不到 fzf。改用：workmode.sh --switch [地點]/[profile]\n"
        // workmode.sh:1018
        case let .pickerFallbackLocations(available):
            "  地點：\(available) auto\n"
        // workmode.sh:1039
        case .pickerLocationUnresolvedAfterAuto:
            "! 清掉覆寫之後認不出地點，只更新地點設定。\n"
        }
    }

    /// workmode.sh:1280 的 `loc_mark`。地點是自動偵測來的時候是空字串。
    func mark(overridden: Bool) -> String {
        overridden ? "，手動覆寫" : ""
    }

    /// workmode.sh:1288-1292 的 `prof_mark`。**四種來源收成三句**：`default` 與
    /// `first` 都印 `default`（bash 的 `*)` 分支），所以那個 case 不是可以省的。
    func mark(of source: ProfileResolution.Source) -> String {
        switch source {
        case .arg: "本次指定"
        case .memory: "記憶"
        case .default, .first: "default"
        }
    }
}
