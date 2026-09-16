import Foundation
import Testing
import WorkmodeDomain
import WorkmodeEditorModel
import WorkmodeWire

@Suite("地點的增刪改名")
struct LocationEditTests {
    /// 改名的期望值。用 struct 而不是三元組：swiftlint 的 `large_tuple` 擋三元組，
    /// 而具名欄位在讀「哪一欄是拒絕、哪一欄是改變」時本來就比位置清楚。
    /// 巢狀在 suite 裡面：兩個 suite 各有一份，同一個 target 不能有兩個同名的
    /// 頂層型別，而讓其中一個去引用另一個檔案的型別是沒有必要的耦合。
    struct RenameCase {
        let name: String
        let shouldRefuse: Bool
        let shouldChange: Bool
    }

    /// 新增的地點**必須自己就合法**：desc 非空、displays 有 main、
    /// profiles 不是空的（C1 那四條）。
    @Test func aNewLocationIsValidOnItsOwn() throws {
        let after = try settingsDocument().addingLocation("咖啡廳", desc: "那間咖啡廳",
                                                          firstProfile: "預設")
        #expect(after.locations == ["office", "home", "咖啡廳"])
        #expect(after.profiles(in: "咖啡廳") == ["預設"])
        #expect(after.displayRoles(in: "咖啡廳") == ["main"])
        #expect(LayoutValidator.validate(after.root).isEmpty)
    }

    /// **main 的 UUID 是空字串**，那是一個看得見的洞而不是猜一個值。
    /// validate 不會抱怨（它只查鍵存不存在），所以 UI 要自己標出來。
    @Test func theNewLocationsMainUUIDIsAnEmptyHole() throws {
        let after = try settingsDocument().addingLocation("咖啡廳", desc: "那間",
                                                          firstProfile: "預設")
        #expect(after.displayUUID(location: "咖啡廳", role: "main") == "")
        #expect(LayoutValidator.validate(after.root).isEmpty)
    }

    /// 改名保住位置：`office` 原本排第一。
    @Test func renamingKeepsThePosition() throws {
        let after = try settingsDocument().renamingLocation("office", to: "辦公室")
        #expect(after.locations == ["辦公室", "home"])
    }

    /// 改 desc 只動那一個值，其餘位元組不變。
    @Test func settingDescTouchesOnlyThatValue() throws {
        let before = try settingsDocument()
        let after = before.settingLocationDesc("home", to: "家裡")
        #expect(JSONPath.get(after.root, [.key("home"), .key("desc")]) == .string("家裡"))
        #expect(settingsText(of: after).replacingOccurrences(of: "\"家裡\"", with: "\"家\"")
            == settingsText(of: before))
    }

    @Test func deletingALocationWorks() throws {
        let after = try settingsDocument().deletingLocation("home")
        #expect(after.locations == ["office"])
        #expect(LayoutValidator.validate(after.root).isEmpty)
    }

    /// 拒絕刪掉最後一個地點。**這條要刪兩次才到得了**——fixture 有兩個地點。
    @Test func theLastLocationCannotGo() throws {
        let one = try settingsDocument().deletingLocation("home")
        #expect(one.locationDeletionRefusal("office") != nil)
        #expect(settingsText(of: one.deletingLocation("office")) == settingsText(of: one))
        #expect(try settingsDocument().locationDeletionRefusal("office") == nil)
    }

    /// 守衛與動作是同一個條件。**`office` 那一項是這條測試存在的理由**：
    /// 沒有守衛的話 `addingLocation("office", …)` 會靜默覆蓋掉整個 office
    /// （`JSONPath.set` 對既有的鍵是原地更新），連同它的兩個 profile 與樹。
    @Test func addingAgreesWithTheNameRefusal() throws {
        let doc = try settingsDocument()
        for name in ["", "auto", "有 空白", "windows", "office", "咖啡廳"] {
            let refused = doc.locationNameRefusal(name) != nil
            let changed = settingsText(of: doc.addingLocation(name, desc: "說明",
                                                              firstProfile: "預設"))
                != settingsText(of: doc)
            #expect(refused != changed, "「\(name)」：refused=\(refused) changed=\(changed)")
        }
    }

    /// 改名同樣走 `locationNameRefusal`，而且**改成自己要允許**（`excluding`）。
    /// 「改成自己」是唯一「不拒絕但也不改變」的一項，所以這條不能用
    /// `refused != changed` 的形狀，要逐項寫出兩個期望值。
    ///
    /// `home` 那一項是資料遺失的另一面：`JSONPath.renameKey` 自己會擋撞名
    /// （`from == newName || !members.contains(newName)`），但擋下來時使用者
    /// 看到的是 `lastRejection` 的固定措辭，講的是別的事。
    @Test func renamingAgreesWithTheNameRefusal() throws {
        let doc = try settingsDocument()
        let cases: [RenameCase] = [
            RenameCase(name: "", shouldRefuse: true, shouldChange: false),
            RenameCase(name: "auto", shouldRefuse: true, shouldChange: false),
            RenameCase(name: "有 空白", shouldRefuse: true, shouldChange: false),
            RenameCase(name: "windows", shouldRefuse: true, shouldChange: false),
            RenameCase(name: "home", shouldRefuse: true, shouldChange: false),
            RenameCase(name: "office", shouldRefuse: false, shouldChange: false),
            RenameCase(name: "辦公室", shouldRefuse: false, shouldChange: true),
        ]
        for item in cases {
            let (name, shouldRefuse, shouldChange) =
                (item.name, item.shouldRefuse, item.shouldChange)
            let refused = doc.locationNameRefusal(name, excluding: "office") != nil
            let changed = settingsText(of: doc.renamingLocation("office", to: name))
                != settingsText(of: doc)
            #expect(refused == shouldRefuse, "「\(name)」refused=\(refused)")
            #expect(changed == shouldChange, "「\(name)」changed=\(changed)")
        }
    }

    /// `windows` 是保留字不是地點（`LayoutQuery.reservedKey`）。拿它當地點名
    /// 會蓋掉共用規則總表——`locations` 本來就把它濾掉，這裡也要擋。
    @Test func theReservedKeyIsNotALocationName() throws {
        let before = try settingsDocument()
        #expect(settingsText(of: before.addingLocation("windows", desc: "壞",
                                                       firstProfile: "預設"))
                == settingsText(of: before))
        #expect(settingsText(of: before.renamingLocation("home", to: "windows"))
            == settingsText(of: before))
    }
}
