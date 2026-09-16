import Testing
import WorkmodeDomain
import WorkmodeEditorModel
import WorkmodeWire

@Suite("刪規則與改 label 時樹跟著走")
struct LabelSweepTests {
    // MARK: - 控制組

    //
    // 兩組都是為了證明後面的斷言看得見失敗。少了「必定失敗」那組，
    // 「掃除生效了」與「fixture 本來就過」在測試輸出上逐字相同。

    /// 正控制：fixture 本身合法。
    @Test func theFixtureItselfValidates() throws {
        #expect(try LayoutValidator.validate(sweepDocument().root).isEmpty)
    }

    /// 負控制：**只刪規則、不掃樹**就是使用者回報的那個 bug。
    /// 這裡手動做出那個狀態（繞過 `deletingRule`），確認 validator 真的會抱怨。
    /// 這兩句訊息就是 2026-08-26 使用者截圖上的那一類。
    @Test func deletingWithoutSweepingIsExactlyTheReportedBug() throws {
        let raw = try sweepDocument().root
        let stripped = try JSONPath.delete(raw, [.key("windows"), .index(0)])
        let problems = LayoutValidator.validate(stripped)
        #expect(problems == [
            .structural("office.開發.trees.main.0：window「共用甲」不在生效的 windows 清單裡"),
            .structural("home.開發.trees.main：window「共用甲」不在生效的 windows 清單裡"),
        ])
    }

    // MARK: - 刪除連帶掃除

    /// 刪掉共用層的規則 → 兩個地點的樹都跟著走。
    ///
    /// **逐點斷言，不比整段文字**：整段文字的斷言在這裡沒有鑑別力，因為
    /// 「塌一層」與「整棵刪掉」都會讓文字變短。
    @Test func deletingASharedRulePrunesEveryTreeThatUsedIt() throws {
        let after = try sweepDocument().deletingRule(.shared, index: 0)

        // 塌一層：父節點被那個內部分割整個取代，連它自己的 axis 一起丟。
        #expect(sweepNode(after, role: "main")?["axis"] == .string("horizontal"))
        #expect(sweepNode(after, role: "main", slots: [0])?["window"] == .number("7"))
        #expect(sweepNode(after, role: "main", slots: [1])?["window"] == .string("地點乙"))

        // 整棵被掃空 → 那個鍵不見，**不是**留一個空物件。
        #expect(JSONPath.get(after.root,
                             [.key("home"), .key("profiles"), .key("開發"),
                              .key("trees"), .key("main")]) == nil)
        #expect(JSONPath.get(after.root,
                             [.key("home"), .key("profiles"), .key("開發"),
                              .key("trees")]) == .object([]))
    }

    /// 沒被碰到的兄弟**原樣保留**，含 `ratio` 的字面值與使用者的自訂鍵。
    /// 這一條擋的是「整棵樹重建」——那種實作會把 `0.750` 印成 `0.75`、
    /// 把 `note` 靜默刪掉，而畫面上完全看不出來。
    @Test func theSweepLeavesUntouchedNodesByteForByte() throws {
        let after = try sweepDocument().deletingRule(.location("office"), index: 0)
        #expect(sweepNode(after, role: "main", slots: [0])?["ratio"] == .number("0.750"))
        #expect(sweepNode(after, role: "main", slots: [0])?["note"] == .string("自訂鍵"))
        #expect(sweepNode(after, role: "main", slots: [0])?["window"] == .string("共用甲"))
        // 內部分割掉了「地點乙」之後塌成剩下的那一葉。
        #expect(sweepNode(after, role: "main", slots: [1])?["window"] == .number("7"))
    }

    /// 只被 `spaceTrees` 引用的 label 也要掃得到。
    ///
    /// fixture 裡「只在分頁」在 `trees` 一次都沒出現——少了這一條，
    /// 一個只掃 `trees` 的實作會全綠，而使用者在分頁上畫的版面會讓 ⌘S 永遠被擋。
    @Test func theSweepReachesPerSpaceTreesToo() throws {
        let after = try sweepDocument().deletingRule(.shared, index: 2)
        #expect(JSONPath.get(after.root,
                             [.key("office"), .key("profiles"), .key("開發"),
                              .key("spaceTrees"), .key("second"), .key("SPACE-1")]) == nil)
        #expect(JSONPath.get(after.root,
                             [.key("office"), .key("profiles"), .key("開發"),
                              .key("spaceTrees"), .key("second")]) == .object([]))
        // `trees` 那半完全沒被碰到。
        #expect(sweepNode(after, role: "main", slots: [0])?["window"] == .string("共用甲"))
        #expect(sweepNode(after, role: "second")?["window"] == .string("地點乙"))
    }

    /// **真正的驗收條件**：掃完之後整份文件過得了 validate，也就是 ⌘S 不會被擋。
    /// 其餘每一條都是輔助——它們說明「怎麼變的」，這一條說明「有沒有用」。
    ///
    /// 四個 case 各打一種 scope，而 `只在分頁` 那個**只被 `spaceTrees` 引用**：
    /// 少了它，一個只掃 `trees` 的實作在這裡照樣全綠。那個漏洞的樣子實測過——
    /// 刪掉那條規則而不掃 `spaceTrees`，validator 回
    /// `office.開發.spaceTrees.second.SPACE-1：window「只在分頁」不在生效的 windows 清單裡`、rc=1。
    @Test func everySweepLeavesTheDocumentValid() throws {
        for item in Self.deleteCases {
            let after = try sweepDocument().deletingRule(item.scope, index: item.index)
            #expect(LayoutValidator.validate(after.root).isEmpty,
                    "刪掉 \(item.label) 之後不合法")
        }
    }

    /// 一個刪除案例。三個欄位裝成 struct 而不是 tuple：swiftlint 的 `large_tuple`
    /// 上限是**兩個**成員（`EditorControllerTests.swift` 的 `WriteRecord` 同一個理由）。
    private struct DeleteCase {
        let label: String
        let scope: RuleScope
        let index: Int
        /// 刪掉它會連帶拿掉幾個窗格。**每一個都是實測值**（2026-08-26 用 reference
        /// 實作跑過，結果各自餵給 `workmode validate` 都是 rc=0 零輸出）。
        let panes: Int
    }

    /// 每一種 scope 一個，外加一個只在 `spaceTrees` 裡被引用的。
    private static let deleteCases = [
        DeleteCase(label: "共用甲", scope: .shared, index: 0, panes: 2),
        DeleteCase(label: "7", scope: .shared, index: 1, panes: 1),
        DeleteCase(label: "只在分頁", scope: .shared, index: 2, panes: 1),
        DeleteCase(label: "地點乙", scope: .location("office"), index: 0, panes: 2),
        DeleteCase(label: "專屬丙",
                   scope: .profile(location: "office", profile: "會議"), index: 0,
                   panes: 1),
    ]

    /// 刪掉某個 profile 專屬的規則 → **其他 profile 逐位元組不變**。
    ///
    /// 這一條是「全檔掃同名 label」與「只掃受影響的 profile」唯一分得出來的地方。
    /// 斷言比的是整段序列化文字，不是計數——計數擋不住「保持大小不變」的突變。
    @Test func deletingAProfileOwnRuleLeavesEverybodyElseAlone() throws {
        let before = try sweepDocument()
        let after = before.deletingRule(
            .profile(location: "office", profile: "會議"), index: 0
        )

        // 會議的樹塌成剩下的那一葉——它自己那份 `windows` 也有「共用甲」。
        #expect(JSONPath.get(after.root,
                             [.key("office"), .key("profiles"), .key("會議"),
                              .key("trees"), .key("main"), .key("window")])
                == .string("共用甲"))

        // 其他兩個 profile 一個字都沒動。
        for (location, profile) in [("office", "開發"), ("home", "開發")] {
            let path: [JSONPath.Step] = [.key(location), .key("profiles"), .key(profile)]
            #expect(JSONPath.get(after.root, path) == JSONPath.get(before.root, path),
                    "\(location)/\(profile) 被動到了")
        }
    }

    /// 自己有 `windows` 的 profile **完全不受共用層影響**（實測：profile 層的
    /// `windows` 只要是真值就整組取代前兩層，`RuleScope` 檔頭有 `__diff windows_for`
    /// 的輸出）。所以刪共用層的規則時，它的樹不該被碰。
    ///
    /// 少了這一條，一個「刪共用層就掃全部」的實作會把會議的版面一起清掉。
    @Test func aProfileWithItsOwnWindowsIsNotSwept() throws {
        let before = try sweepDocument()
        let after = before.deletingRule(.shared, index: 0)
        let path: [JSONPath.Step] = [.key("office"), .key("profiles"), .key("會議")]
        #expect(JSONPath.get(after.root, path) == JSONPath.get(before.root, path))
    }

    // MARK: - 改名連動

    /// 改 label → 樹裡跟著改，**版面結構完全不動**。
    ///
    /// 斷言整份文字除了那幾個 `window` 值以外逐位元組相同。只驗「新名字在樹裡」
    /// 的話，一個順手重排全檔鍵序、或把 `0.750` 重印成 `0.75` 的實作也會綠。
    ///
    /// 用「只在分頁」而不是「共用甲」：後者在這份 fixture 裡有**四個**出處
    /// （共用層那條規則、`office/開發` 的樹、`office/會議` 自己那份 `windows`、
    /// 以及會議的樹），而會議那兩處**不該**跟著改，所以全檔字串替換算不出正確答案。
    /// 「只在分頁」只有兩個出處，兩個都該改。
    @Test func renamingALabelCarriesTheTreesWithIt() throws {
        let before = try sweepDocument()
        let after = before.settingRuleField(.shared, index: 2, field: .label,
                                            to: "新分頁")

        #expect(JSONPath.get(after.root,
                             [.key("office"), .key("profiles"), .key("開發"),
                              .key("spaceTrees"), .key("second"), .key("SPACE-1"),
                              .key("window")]) == .string("新分頁"))

        // 除了那兩處（規則的 label 與那棵 spaceTree 的 window）以外一個字都沒變。
        #expect(sweepText(of: after)
            == sweepText(of: before)
            .replacingOccurrences(of: "\"只在分頁\"", with: "\"新分頁\""))
    }

    /// 改共用層的 label **不動**自己有 `windows` 的 profile——它那份沒變，
    /// 樹裡的舊名字仍然生效。這是 `aProfileWithItsOwnWindowsIsNotSwept` 的改名側，
    /// 同時驗了「跨兩個地點都跟著改」。
    @Test func renamingASharedLabelSparesAProfileThatOwnsIt() throws {
        let before = try sweepDocument()
        let after = before.settingRuleField(.shared, index: 0, field: .label, to: "新甲")

        #expect(sweepNode(after, role: "main", slots: [0])?["window"] == .string("新甲"))
        #expect(JSONPath.get(after.root,
                             [.key("home"), .key("profiles"), .key("開發"),
                              .key("trees"), .key("main"), .key("window")])
                == .string("新甲"))

        let meeting: [JSONPath.Step] = [.key("office"), .key("profiles"), .key("會議")]
        #expect(JSONPath.get(after.root, meeting) == JSONPath.get(before.root, meeting))
    }

    /// 數字 label 改名：舊值用 jq `==` 找（`.number("7")`），
    /// 新值照 `settingRuleField` 的慣例寫成**字串**。
    ///
    /// 用 `JQPrint.interpolate` 的字串比較做的實作，在這裡會把 `{"window": "7"}`
    /// 也一起改掉——fixture 沒有那種節點，所以這一條驗的是**找得到**那一半。
    @Test func renamingANumericLabelFindsItByJqEquality() throws {
        let after = try sweepDocument()
            .settingRuleField(.shared, index: 1, field: .label, to: "8")
        #expect(sweepNode(after, role: "main", slots: [1, 0])?["window"] == .string("8"))
        #expect(JSONPath.get(after.root,
                             [.key("windows"), .index(1), .key("label")]) == .string("8"))
    }

    /// 改名之後整份文件仍然合法——與刪除同一條驗收條件。
    @Test func renamingLeavesTheDocumentValid() throws {
        let after = try sweepDocument()
            .settingRuleField(.shared, index: 0, field: .label, to: "新甲")
        #expect(LayoutValidator.validate(after.root).isEmpty)
    }

    /// 改 `match` 不動樹。label 清單沒變，沒有任何 profile 失效。
    @Test func editingTheMatchLeavesTheTreesAlone() throws {
        let before = try sweepDocument()
        let after = before.settingRuleField(.shared, index: 0,
                                            field: .matchValue, to: "Kitty")
        #expect(sweepText(of: after)
            == sweepText(of: before)
            .replacingOccurrences(of: "\"Ghostty\"", with: "\"Kitty\""))
    }

    // MARK: - 印起來一樣、jq `==` 不一樣

    /// 刪掉數字 label `7` **不會**動到樹裡字串的 `"7"`。
    ///
    /// 這一條是 `pruning` 那支 `labelEquals` 唯一的守衛。主 fixture 上把它換成
    /// `JQPrint.interpolate` 的字串比較是**全綠**的（2026-08-26 實測）——那裡沒有
    /// 任何一對「印起來相同、jq `==` 不同」的值。
    @Test func deletingANumericLabelSparesTheStringThatPrintsTheSame() throws {
        let after = try numericLabelDocument().deletingRule(.shared, index: 0)
        // 數字那個不見了，樹塌成剩下的字串那一葉。
        #expect(JSONPath.get(after.root,
                             [.key("home"), .key("profiles"), .key("開發"),
                              .key("trees"), .key("main"), .key("window")])
                == .string("7"))
    }

    /// 改名數字 label `7` 也只動數字那一個。`renaming` 那支 `labelEquals` 的守衛。
    @Test func renamingANumericLabelSparesTheStringThatPrintsTheSame() throws {
        let after = try numericLabelDocument()
            .settingRuleField(.shared, index: 0, field: .label, to: "8")
        let kids: [JSONPath.Step] = [.key("home"), .key("profiles"), .key("開發"),
                                     .key("trees"), .key("main"), .key("children")]
        #expect(JSONPath.get(after.root, kids + [.index(0), .key("window")])
            == .string("8"))
        #expect(JSONPath.get(after.root, kids + [.index(1), .key("window")])
            == .string("7"))
    }

    // MARK: - 出聲用的查詢

    /// 查詢與動作綁在一起：**回報的每一個窗格，刪完之後都真的不在了**，
    /// 而且數量相符。抄兩份判準的實作會在這裡分家。
    /// 先例是 `canSetRatio` / `settingRatio` 的
    /// `aDividerWhoseFirstChildIsASplitCannotHoldARatio`。
    @Test func theQueryAgreesWithWhatTheSweepActuallyRemoves() throws {
        let before = try sweepDocument()
        let total = sweepWindowValues(before).count
        for item in Self.deleteCases {
            let hit = before.panesAffectedByDeleting(item.scope, index: item.index)
            #expect(hit.count == item.panes,
                    "\(item.label) 回了 \(hit.count) 個，預期 \(item.panes)")
            let label = try #require(JSONPath.get(
                before.root,
                item.scope.windowsPath + [.index(item.index), .key("label")]
            ))

            // 回報的每一條路徑，在**刪之前**都真的指著一個引用那個 label 的窗格。
            for pane in hit {
                #expect(JSONPath.get(before.root, pane.steps)?["window"] == label,
                        "\(item.label) 回的 \(pane.role) slots \(pane.slots) 沒指著它")
            }

            let after = before.deletingRule(item.scope, index: item.index)
            let left = sweepWindowValues(after)

            // 掃完之後，**受影響的那些 profile** 裡再也沒有窗格引用它。
            // 不是全域的：自己有 `windows` 的 profile 會留著它自己那一份，那是對的。
            for pane in hit {
                #expect(!sweepWindowValues(after, location: pane.location,
                                           profile: pane.profile)
                        .contains { LayoutValidator.labelEquals($0, label) },
                    "\(item.label) 在 \(pane.location)/\(pane.profile) 掃完還有人引用")
            }

            // 而且**只**少了回報的那幾個：塌一層不會順手吃掉兄弟。
            #expect(total - left.count == hit.count,
                    "\(item.label) 實際少了 \(total - left.count) 個，回報 \(hit.count)")
        }
    }

    /// 沒有任何樹用到的規則 → 空清單，UI 據此決定不出聲。
    @Test func aRuleNoTreeUsesAffectsNoPanes() throws {
        var doc = try sweepDocument()
        doc = doc.insertingRule(.shared)
        let index = doc.allRules.filter { $0.scope == .shared }.count - 1
        #expect(doc.panesAffectedByDeleting(.shared, index: index).isEmpty)
    }

    /// 回報的路徑帶著分頁，不只是角色。少了 `space`，UI 那句話會把
    /// 分頁上的窗格說成「目前可見」那一棵的。
    @Test func theQueryNamesThePageAPaneLivesOn() throws {
        let hit = try sweepDocument().panesAffectedByDeleting(.shared, index: 2)
        #expect(hit.count == 1)
        #expect(hit.first?.role == "second")
        #expect(hit.first?.space == "SPACE-1")
    }
}
