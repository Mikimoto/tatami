import Testing
import WorkmodeDomain
import WorkmodeEditorModel
import WorkmodeWire

@Suite("螢幕角色")
struct DisplayEditTests {
    @Test func addingARoleAppendsIt() throws {
        let after = try settingsDocument().addingDisplayRole("third", uuid: "UUID-9",
                                                             to: "office")
        #expect(after.displayRoles(in: "office") == ["main", "second", "third"])
        #expect(after.displayUUID(location: "office", role: "third") == "UUID-9")
        #expect(LayoutValidator.validate(after.root).isEmpty)
    }

    /// 撞名不覆蓋既有的 UUID——那會靜默改掉另一台螢幕的身分。
    @Test func addingAnExistingRoleChangesNothing() throws {
        let before = try settingsDocument()
        #expect(settingsText(of: before.addingDisplayRole("main", uuid: "UUID-9",
                                                          to: "office"))
                == settingsText(of: before))
    }

    /// 改 UUID 只動那一個值。
    @Test func settingTheUUIDTouchesOnlyThatValue() throws {
        let after = try settingsDocument().settingDisplayUUID("second", to: "UUID-9",
                                                              in: "office")
        #expect(after.displayUUID(location: "office", role: "second") == "UUID-9")
        #expect(after.displayUUID(location: "office", role: "main") == "UUID-1")
    }

    /// **`main` 刪不掉**：`displays` 是物件時 validate 要求它存在
    /// （`LayoutValidator.swift:75-76`）。
    @Test func mainCannotBeRemoved() throws {
        let before = try settingsDocument()
        #expect(before.displayRoleRemovalRefusal("main", in: "office") != nil)
        #expect(before.displayRoleRemovalRefusal("second", in: "office") == nil)
        #expect(settingsText(of: before.removingDisplayRole("main", in: "office"))
            == settingsText(of: before))
    }

    /// 刪掉一個角色**不會**連帶刪掉它的樹——那棵樹變成「有 tree 沒 display」，
    /// 畫布照樣畫它並標橘字（`CanvasRole` 的聯集第二段）。這是刻意的：
    /// 靜默刪掉一棵樹比留一個看得見的警告糟。
    ///
    /// **fixture 的 `office.開發` 底下沒有 `second` 的樹**，所以測試自己先種一棵
    /// （`placing` 對不存在的 `spaceTrees.<角色>.<uuid>` 會建出來，見
    /// `TreeEdit.placing` 的檔頭）。沒有這一步的話「刪角色連帶刪樹」這個突變
    /// 不會有任何值不同——`second` 在兩種實作下都不出現在 `canvasRoles` 裡。
    @Test func removingARoleLeavesItsTreeVisible() throws {
        let seeded = try settingsDocument().placing(
            LabelChoice(value: .string("甲")),
            at: PanePath(location: "office", profile: "開發", role: "second",
                         space: "S-1", slots: []),
            zone: .center
        )
        #expect(seeded.spaceTreeRoles(location: "office", profile: "開發") == ["second"])

        let after = seeded.removingDisplayRole("second", in: "office")
        #expect(after.displayRoles(in: "office") == ["main"])
        #expect(after.spaceTreeRoles(location: "office", profile: "開發") == ["second"])
        #expect(after.canvasRoles(location: "office", profile: "開發")
            == [CanvasRole(role: "main", hasDisplay: true),
                CanvasRole(role: "second", hasDisplay: false)])
    }
}
