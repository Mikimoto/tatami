import Foundation
import WorkmodeCore
import WorkmodeDomain

/// `--json` 模式下的事件流：一行一個事件。
///
/// 刻意最小——只有 `kind` 加上那個事件的欄位。完整的封套（schema／ok／command）與
/// exit code 的形狀是 CLI 那個 task 的事，這裡先把「每個事件都有結構化表示」立起來。
/// 用 `.sortedKeys` 與 `JSONEnvelope` 一致，好做逐位元組斷言。
public struct JSONEventRenderer: EventRenderer, Sendable {
    public init() {}

    private func fields(of event: WorkmodeEvent) -> [String: Any] {
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

    private func render(layout: LayoutEvent) -> [String: Any] {
        switch layout {
        case let .restore(event): render(restore: event)
        case let .role(event): render(role: event)
        }
    }

    private func render(session: SessionEvent) -> [String: Any] {
        switch session {
        case let .layoutFileMissing(path):
            ["kind": "layoutFileMissing", "path": path]
        case let .stateLocationNotInLayout(location):
            ["kind": "stateLocationNotInLayout", "location": location]
        case let .app(event): render(app: event)
        case let .mode(event): render(mode: event)
        case let .banner(event): render(banner: event)
        }
    }

    private func render(hotkey: HotkeyEvent) -> [String: Any] {
        switch hotkey {
        case .hotkeyNoFocusedWindow:
            ["kind": "hotkeyNoFocusedWindow"]
        case let .hotkeyNoNeighbour(direction):
            ["kind": "hotkeyNoNeighbour", "direction": direction]
        case let .hotkeySpaceNotFound(target):
            ["kind": "hotkeySpaceNotFound", "target": target]
        case let .hotkeyDisplayNotFound(target):
            ["kind": "hotkeyDisplayNotFound", "target": target]
        case let .hotkeyBindingRejected(detail):
            ["kind": "hotkeyBindingRejected", "detail": detail]
        case let .hotkeyConflict(key):
            ["kind": "hotkeyConflict", "key": key]
        case let .hotkeyShellFailed(command, status):
            ["kind": "hotkeyShellFailed", "command": command, "status": Int(status)]
        case let .hotkeyMouseTapInstalled(modifier):
            ["kind": "hotkeyMouseTapInstalled", "modifier": modifier]
        case .hotkeyMouseTapRefused:
            ["kind": "hotkeyMouseTapRefused"]
        case let .hotkeysRegistered(count, skipped):
            ["kind": "hotkeysRegistered", "count": count, "skipped": skipped]
        }
    }

    private func render(space: SpaceEvent) -> [String: Any] {
        switch space {
        case let .spaceRoleDisplayMissing(role):
            ["kind": "spaceRoleDisplayMissing", "role": role]
        case let .spaceRoleHasNoVisibleSpace(role):
            ["kind": "spaceRoleHasNoVisibleSpace", "role": role]
        case let .spaceHasNoTree(role, uuid):
            ["kind": "spaceHasNoTree", "role": role, "uuid": uuid]
        case let .spaceNotOnItsDisplay(role, uuid):
            ["kind": "spaceNotOnItsDisplay", "role": role, "uuid": uuid]
        case let .spaceLaidOut(role, uuid):
            ["kind": "spaceLaidOut", "role": role, "uuid": uuid]
        case let .frameRejected(label, wanted, actual):
            ["kind": "frameRejected", "label": label,
             "wanted": fields(wanted), "actual": actual.map(fields) as Any]
        }
    }

    private func fields(_ rect: Rect) -> [String: Any] {
        ["x": rect.originX, "y": rect.originY, "w": rect.width, "h": rect.height]
    }

    private func render(switching: SwitchEvent) -> [String: Any] {
        switch switching {
        case let .rejected(event): render(switchRejection: event)
        case let .applied(event): render(switchOutcome: event)
        case let .picker(event): render(picker: event)
        }
    }

    private func render(save: SaveEvent) -> [String: Any] {
        switch save {
        case let .rejected(event): render(saveRejection: event)
        case let .survey(event): render(saveSurvey: event)
        case let .naming(event): render(saveNaming: event)
        case let .shaping(event): render(saveShaping: event)
        case let .writing(event): render(saveWriting: event)
        }
    }

    private func render(app: AppEvent) -> [String: Any] {
        switch app {
        case let .appNotRunning(app):
            ["kind": "appNotRunning", "app": app]
        case let .appLaunchFailed(app):
            ["kind": "appLaunchFailed", "app": app]
        // 秒數是 JSON 的數字而不是 `10s` 那串文字：`s` 是人看的表示法。
        case let .appLaunched(app, seconds):
            ["kind": "appLaunched", "app": app, "waitedSeconds": seconds]
        case let .appLaunchTimedOut(app, seconds):
            ["kind": "appLaunchTimedOut", "app": app, "seconds": seconds]
        }
    }

    private func render(mode: ModeEvent) -> [String: Any] {
        switch mode {
        case let .profileNotInLocation(want, location, available):
            ["kind": "profileNotInLocation", "want": want,
             "location": location, "available": available]
        case .usageRejected:
            ["kind": "usageRejected"]
        case .locationUnrecognized:
            ["kind": "locationUnrecognized"]
        // 三個欄位都是字串，與 `ruleWindowPositionReported` 同一個理由：它們是 jq
        // 印出來的文字，`1.7976931348623157e+308` 與字面的 `null` 都是資料的一部分。
        case let .connectedDisplayListed(uuid, width, height):
            ["kind": "connectedDisplayListed", "uuid": uuid,
             "width": width, "height": height]
        case .manualLocationHinted:
            ["kind": "manualLocationHinted"]
        // `overridden` 是布林、`profileSource` 是那四個 rawValue，都不是人看的那句
        // 中文：`default` 與 `first` 在人看的輸出裡同文，消費端要分得出來。
        case let .modeChosen(location, desc, overridden, profile, source):
            ["kind": "modeChosen", "location": location, "desc": desc,
             "overridden": overridden, "profile": profile,
             "profileSource": source.rawValue]
        case let .rememberedProfileGone(stale, location, profile):
            ["kind": "rememberedProfileGone", "stale": stale,
             "location": location, "profile": profile]
        }
    }

    private func render(banner: BannerEvent) -> [String: Any] {
        switch banner {
        case .probeBannerShown:
            ["kind": "probeBannerShown"]
        }
    }

    private func render(switchRejection: SwitchRejection) -> [String: Any] {
        switch switchRejection {
        case let .switchArgumentEmpty(argument):
            ["kind": "switchArgumentEmpty", "argument": argument]
        case let .switchLocationUnknown(location, available):
            ["kind": "switchLocationUnknown",
             "location": location, "available": available]
        case .switchLocationUnresolved:
            ["kind": "switchLocationUnresolved"]
        case let .switchProfileUnknown(want, location, available):
            ["kind": "switchProfileUnknown",
             "want": want, "location": location, "available": available]
        case let .stateFileUnwritable(path):
            ["kind": "stateFileUnwritable", "path": path]
        }
    }

    private func render(switchOutcome: SwitchOutcome) -> [String: Any] {
        switch switchOutcome {
        case .switchHintShown:
            ["kind": "switchHintShown"]
        case let .locationOverrideCleared(detected):
            ["kind": "locationOverrideCleared", "detected": detected]
        case let .locationPinned(location):
            ["kind": "locationPinned", "location": location]
        case let .profileMemoryCleared(location):
            ["kind": "profileMemoryCleared", "location": location]
        case let .profilePinned(location, profile):
            ["kind": "profilePinned", "location": location, "profile": profile]
        }
    }

    private func render(picker: PickerEvent) -> [String: Any] {
        switch picker {
        case .pickerMissing:
            ["kind": "pickerMissing"]
        case let .pickerFallbackLocations(available):
            ["kind": "pickerFallbackLocations", "available": available]
        case .pickerLocationUnresolvedAfterAuto:
            ["kind": "pickerLocationUnresolvedAfterAuto"]
        }
    }

    public func render(_ event: WorkmodeEvent) -> String {
        let fields = fields(of: event)
        // 這裡的字典只由上面的 switch 產生（全是 String／Int），序列化不可能失敗；
        // 真的失敗就吐一個看得出來壞了的東西，而不是無聲丟掉一句話。
        guard let data = try? JSONSerialization.data(
            withJSONObject: fields, options: [.sortedKeys, .withoutEscapingSlashes]
        ) else {
            return "{\"kind\":\"unrenderable\"}\n"
        }
        return String(decoding: data, as: UTF8.self) + "\n"
    }
}
