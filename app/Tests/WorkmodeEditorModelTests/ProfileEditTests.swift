import Testing
import WorkmodeDomain
import WorkmodeEditorModel
import WorkmodeWire

@Suite("profile 的增刪改名")
struct ProfileEditTests {
    /// 改名的期望值。用 struct 而不是三元組：swiftlint 的 `large_tuple` 擋三元組，
    /// 而具名欄位在讀「哪一欄是拒絕、哪一欄是改變」時本來就比位置清楚。
    /// 巢狀在 suite 裡面：兩個 suite 各有一份，同一個 target 不能有兩個同名的
    /// 頂層型別，而讓其中一個去引用另一個檔案的型別是沒有必要的耦合。
    struct RenameCase {
        let name: String
        let shouldRefuse: Bool
        let shouldChange: Bool
    }

    /// 新增的形狀是 `{"trees": {}}`，與 `--save` 建新 profile 時相同（C3）。
    /// 而且接在既有的**後面**，不是前面。
    ///
    /// **守住形狀的是那條 `JSONPath.get`，不是 validate。** 2026-08-20 實測：
    /// 把 `trees` 的值改成 `.null`，只有形狀那條紅，validate 仍然是空的——
    /// `LayoutValidator.swift:230-238` 查的是**鍵存不存在**
    /// （`members.contains(where: { $0.key == "trees" })`），值是什麼它不看
    /// （只有整個 profile 值是 null 時才報缺 trees）。所以 validate 那條在這裡
    /// 沒有鑑別力，留著是因為它守的是另一件事：新增出來的文件整份仍然合法。
    @Test func addingMakesTheSameShapeSaveDoes() throws {
        let after = try settingsDocument().addingProfile("影音", to: "office")
        #expect(after.profiles(in: "office") == ["開發", "會議", "影音"])
        #expect(JSONPath.get(after.root, [.key("office"), .key("profiles"),
                                          .key("影音")]) == .object([
                JSONMember(key: "trees", value: .object([])),
            ]))
        #expect(LayoutValidator.validate(after.root).isEmpty)
    }

    /// 改名**保住位置**：`開發` 原本排第一，改名後仍排第一。
    /// 「delete ＋ set」的實作在這條紅（它會排到 `會議` 後面）。
    @Test func renamingKeepsThePosition() throws {
        let after = try settingsDocument().renamingProfile("開發", to: "主力", in: "office")
        #expect(after.profiles(in: "office") == ["主力", "會議"])
    }

    /// **改名要順手改 `default`**（C2）。不改的話 `default` 變成假指標，
    /// validate 報「office.default「開發」不是這個地點的 profile」。
    @Test func renamingFixesTheDefaultPointer() throws {
        let after = try settingsDocument().renamingProfile("開發", to: "主力", in: "office")
        #expect(JSONPath.get(after.root, [.key("office"), .key("default")])
            == .string("主力"))
        #expect(LayoutValidator.validate(after.root).isEmpty)
    }

    /// 改名一個**不是** default 的 profile，`default` 不動。
    @Test func renamingSomethingElseLeavesTheDefaultAlone() throws {
        let after = try settingsDocument().renamingProfile("會議", to: "討論", in: "office")
        #expect(JSONPath.get(after.root, [.key("office"), .key("default")])
            == .string("開發"))
    }

    /// 刪除：`會議` 不是 default、也不是最後一個，可以刪。
    @Test func deletingAnOrdinaryProfileWorks() throws {
        let after = try settingsDocument().deletingProfile("會議", in: "office")
        #expect(after.profiles(in: "office") == ["開發"])
        #expect(LayoutValidator.validate(after.root).isEmpty)
    }

    /// 兩個拒絕的理由**不同**，而且拒絕時文件一個位元組都不動。
    @Test func theTwoRefusalsAreDifferentAndBinding() throws {
        let before = try settingsDocument()
        let isDefault = before.profileDeletionRefusal("開發", in: "office")
        let isLast = before.profileDeletionRefusal("唯一", in: "home")
        #expect(isDefault != nil)
        #expect(isLast != nil)
        #expect(isDefault != isLast)
        #expect(before.profileDeletionRefusal("會議", in: "office") == nil)
        #expect(settingsText(of: before.deletingProfile("開發", in: "office"))
            == settingsText(of: before))
        #expect(settingsText(of: before.deletingProfile("唯一", in: "home"))
            == settingsText(of: before))
    }

    /// 守衛與動作是同一個條件。**`開發` 那一項是這條測試存在的理由**：
    /// 沒有守衛的話 `addingProfile("開發", to: "office")` 會把 `office.開發`
    /// 整個換成 `{"trees": {}}`（`JSONPath.set` 對既有的鍵是原地更新），
    /// 那個 profile 的樹靜默消失。
    ///
    /// `windows` 要**可以**：它只在地點層是保留字，profile 叫這個名字合法。
    @Test func addingAgreesWithTheNameRefusal() throws {
        let doc = try settingsDocument()
        for name in ["", "auto", "有 空白", "windows", "開發", "影音"] {
            let refused = doc.profileNameRefusal(name, in: "office") != nil
            let changed = settingsText(of: doc.addingProfile(name, to: "office"))
                != settingsText(of: doc)
            #expect(refused != changed, "「\(name)」：refused=\(refused) changed=\(changed)")
        }
    }

    /// 改名同樣走 `profileNameRefusal`，改成自己要允許。形狀與地點那條相同：
    /// 「改成自己」不拒絕也不改變，所以逐項寫出兩個期望值。
    @Test func renamingAgreesWithTheNameRefusal() throws {
        let doc = try settingsDocument()
        let cases: [RenameCase] = [
            RenameCase(name: "", shouldRefuse: true, shouldChange: false),
            RenameCase(name: "auto", shouldRefuse: true, shouldChange: false),
            RenameCase(name: "有 空白", shouldRefuse: true, shouldChange: false),
            RenameCase(name: "開發", shouldRefuse: true, shouldChange: false),
            RenameCase(name: "會議", shouldRefuse: false, shouldChange: false),
            RenameCase(name: "windows", shouldRefuse: false, shouldChange: true),
            RenameCase(name: "討論", shouldRefuse: false, shouldChange: true),
        ]
        for item in cases {
            let (name, shouldRefuse, shouldChange) =
                (item.name, item.shouldRefuse, item.shouldChange)
            let refused = doc.profileNameRefusal(name, in: "office",
                                                 excluding: "會議") != nil
            let changed = settingsText(of: doc.renamingProfile("會議", to: name,
                                                               in: "office"))
                != settingsText(of: doc)
            #expect(refused == shouldRefuse, "「\(name)」refused=\(refused)")
            #expect(changed == shouldChange, "「\(name)」changed=\(changed)")
        }
    }

    /// 走不通的路徑回原文件（與 2a／2b 的 C8 同一條）。
    @Test func anUnknownLocationChangesNothing() throws {
        let before = try settingsDocument()
        #expect(settingsText(of: before.addingProfile("X", to: "沒有這個地點"))
            == settingsText(of: before))
    }
}
