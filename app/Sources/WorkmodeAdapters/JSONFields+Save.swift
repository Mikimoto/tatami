import Foundation
import WorkmodeCore
import WorkmodeDomain

// `--save` 的欄位。

extension JSONEventRenderer {
    func render(saveRejection: SaveRejection) -> [String: Any] {
        switch saveRejection {
        case .saveNeedsTerminal:
            ["kind": "saveNeedsTerminal"]
        case .saveLocationUnrecognized:
            ["kind": "saveLocationUnrecognized"]
        case .saveProfileNameReserved:
            ["kind": "saveProfileNameReserved"]
        case let .saveProfileNameHasSpace(profile):
            ["kind": "saveProfileNameHasSpace", "profile": profile]
        }
    }

    func render(saveSurvey: SaveSurvey) -> [String: Any] {
        switch saveSurvey {
        case let .saveBannerShown(location, desc, profile):
            ["kind": "saveBannerShown",
             "location": location, "desc": desc, "profile": profile]
        case let .saveDisplayNotInLayout(uuid):
            ["kind": "saveDisplayNotInLayout", "uuid": uuid]
        case let .saveRoleDisplayNotConnected(role):
            ["kind": "saveRoleDisplayNotConnected", "role": role]
        case let .saveRoleHasNoVisibleSpace(role):
            ["kind": "saveRoleHasNoVisibleSpace", "role": role]
        case .saveNothingToStore:
            ["kind": "saveNothingToStore"]
        case let .saveWindowIntroduced(app, title):
            ["kind": "saveWindowIntroduced", "app": app, "title": title]
        case let .saveWindowPosition(role, position):
            ["kind": "saveWindowPosition", "role": role, "position": position]
        }
    }

    func render(saveNaming: SaveNaming) -> [String: Any] {
        switch saveNaming {
        case let .saveLabelPrompt(app):
            ["kind": "saveLabelPrompt", "app": app]
        case .saveLabelHasTab:
            ["kind": "saveLabelHasTab"]
        case let .saveLabelTaken(label):
            ["kind": "saveLabelTaken", "label": label]
        case let .saveTitleRuleIsExact(pattern):
            ["kind": "saveTitleRuleIsExact", "pattern": pattern]
        }
    }

    func render(saveShaping: SaveShaping) -> [String: Any] {
        switch saveShaping {
        case let .saveRoleNotSplittable(role):
            ["kind": "saveRoleNotSplittable", "role": role]
        case let .saveRoleHasNoNamedWindow(role):
            ["kind": "saveRoleHasNoNamedWindow", "role": role]
        case let .saveRatioTooSmall(label, ratio):
            ["kind": "saveRatioTooSmall", "label": label, "ratio": ratio]
        case let .saveRoleShape(role, shape):
            ["kind": "saveRoleShape", "role": role, "shape": shape]
        case .saveNoTreeStored:
            ["kind": "saveNoTreeStored"]
        case let .saveWindowLostToOverlap(role, label):
            ["kind": "saveWindowLostToOverlap", "role": role, "label": label]
        }
    }

    func render(saveWriting: SaveWriting) -> [String: Any] {
        switch saveWriting {
        case let .layoutValidationFailed(problems):
            ["kind": "layoutValidationFailed", "problems": problems.map(payload)]
        case .saveMergedInvalid:
            ["kind": "saveMergedInvalid"]
        case let .saveOverwritePrompt(profile):
            ["kind": "saveOverwritePrompt", "profile": profile]
        case .saveCancelled:
            ["kind": "saveCancelled"]
        case .saveWriteFailed:
            ["kind": "saveWriteFailed"]
        case let .saveWritten(path):
            ["kind": "saveWritten", "path": path]
        case let .saveRuleInvented(label, match):
            ["kind": "saveRuleInvented", "label": label, "match": match]
        case let .saveSkippedUnnamed(count):
            ["kind": "saveSkippedUnnamed", "count": count]
        case let .saveSkippedInvisibleSpaces(count):
            ["kind": "saveSkippedInvisibleSpaces", "count": count]
        }
    }
}
