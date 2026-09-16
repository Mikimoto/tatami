import Testing
import WorkmodeDomain
import WorkmodeEditorModel

@Suite("放置區與路徑")
struct DropZoneTests {
    @Test func centreIsTheMiddleFifth() {
        #expect(DropZone.at(x: 0.5, y: 0.5) == .center)
        #expect(DropZone.at(x: 0.69, y: 0.69) == .center)
    }

    @Test func theLowBoundaryIsWhereLessThanAndLessOrEqualDiffer() {
        #expect(DropZone.at(x: 0.30, y: 0.50) == .leading)
        #expect(DropZone.at(x: 0.50, y: 0.30) == .top)
    }

    /// 0.70 落在**中央**，不是外側。這不是缺陷也不加 epsilon 去矯正它：
    /// 一格 900px 寬時 0.2 與 0.19999999999999996 差不到一個像素，而在產品碼裡塞一個
    /// 容差只為了讓一個測不到的點對稱，是拿實作去湊測試。
    ///
    /// 這一條的價值在於**釘住那個不對稱**：之後有人「順手」加 epsilon 讓它對稱，
    /// 這一條會紅，而他就會讀到上面那段為什麼。
    @Test func theHighBoundaryFallsInsideBecauseOfDoubleRounding() {
        #expect(DropZone.at(x: 0.70, y: 0.50) == .center)
        #expect(DropZone.at(x: 0.50, y: 0.70) == .center)
        // 外側從 0.71 起算。
        #expect(DropZone.at(x: 0.71, y: 0.50) == .trailing)
        #expect(DropZone.at(x: 0.50, y: 0.71) == .bottom)
    }

    /// 四個角：兩個偏移相等時**橫向贏**。這是刻意的選擇（左右分比上下分常用），
    /// 沒有它角落的行為就是實作巧合。
    @Test func cornersTieToHorizontal() {
        #expect(DropZone.at(x: 0.1, y: 0.1) == .leading)
        #expect(DropZone.at(x: 0.9, y: 0.1) == .trailing)
        #expect(DropZone.at(x: 0.1, y: 0.9) == .leading)
        #expect(DropZone.at(x: 0.9, y: 0.9) == .trailing)
    }

    /// 非有限座標回 nil，UI 據此整個忽略那次放下。回 `.center` 的話那次放下會
    /// **換掉**一個視窗，而使用者根本沒瞄準任何地方。
    @Test func nonFiniteIsRefused() {
        #expect(DropZone.at(x: .nan, y: 0.5) == nil)
        #expect(DropZone.at(x: 0.5, y: .infinity) == nil)
    }

    @Test func zoneAxisAndSide() {
        #expect(DropZone.leading.axis == "vertical")
        #expect(DropZone.trailing.axis == "vertical")
        #expect(DropZone.top.axis == "horizontal")
        #expect(DropZone.bottom.axis == "horizontal")
        #expect(DropZone.center.axis == nil)
        #expect(DropZone.leading.putsNewNodeFirst == true)
        #expect(DropZone.bottom.putsNewNodeFirst == false)
    }

    /// 五個 case 的值。**逐個寫死**而不是從 `at` 反推：這一條與下面那條是互補的
    /// ——下面那條對「把某一區改成蓋滿整格」沒有鑑別力（`center` 的矩形含所有點）。
    @Test func previewCoversTheHalfThatWillChange() {
        #expect(DropZone.leading.previewFraction
            == PreviewFraction(x: 0, y: 0, width: 0.5, height: 1))
        #expect(DropZone.trailing.previewFraction
            == PreviewFraction(x: 0.5, y: 0, width: 0.5, height: 1))
        #expect(DropZone.top.previewFraction
            == PreviewFraction(x: 0, y: 0, width: 1, height: 0.5))
        #expect(DropZone.bottom.previewFraction
            == PreviewFraction(x: 0, y: 0.5, width: 1, height: 0.5))
        // 中央的語意是「換掉這個視窗」不是「插進來」，所以蓋滿整格。
        #expect(DropZone.center.previewFraction
            == PreviewFraction(x: 0, y: 0, width: 1, height: 1))
    }

    /// 預覽與落點不可以各算一份。**亮在左邊、放到右邊**在畫面上兩邊都正常，
    /// 沒有任何東西會發現——所以這一條拿一組代表點問 `at`，再要求它回的那一區的
    /// 矩形真的包含那個點。
    @Test func thePreviewContainsThePointThatChoseIt() throws {
        let points: [(Double, Double)] = [
            (0.1, 0.5), (0.9, 0.5), (0.5, 0.1), (0.5, 0.9), (0.5, 0.5),
            // 四個角。偏移相等時橫向贏，所以它們落在左右兩區。
            (0.1, 0.1), (0.9, 0.9),
        ]
        for (fractionX, fractionY) in points {
            // `try #require` 而不是 `try!`：swiftlint 的 `force_try` 會出聲，
            // 而 `mise run lint` 是收尾閘門的一部分。
            let zone = try #require(DropZone.at(x: fractionX, y: fractionY))
            let box = zone.previewFraction
            #expect(fractionX >= box.originX && fractionX <= box.originX + box.width,
                    "x=\(fractionX) 落在 \(zone) 之外：\(box)")
            #expect(fractionY >= box.originY && fractionY <= box.originY + box.height,
                    "y=\(fractionY) 落在 \(zone) 之外：\(box)")
        }
    }

    @Test func panePathWalksDownAndBackUp() {
        let root = PanePath(location: "office", profile: "開發", role: "main",
                            space: "S-1", slots: [])
        let deep = root.child(1).child(0)
        #expect(deep.slots == [1, 0])
        #expect(deep.parent?.slots == [1])
        #expect(root.parent == nil)
        #expect(deep.siblingSlot == 1)
        #expect(root.siblingSlot == nil)
    }

    /// 路徑要逐步對，不是只對長度。
    @Test func panePathBecomesJSONSteps() {
        let path = PanePath(location: "office", profile: "開發", role: "main",
                            space: "S-1", slots: [1, 0])
        #expect(path.steps == [.key("office"), .key("profiles"), .key("開發"),
                               .key("spaceTrees"), .key("main"), .key("S-1"),
                               .key("children"), .index(1),
                               .key("children"), .index(0)])
    }

    /// 與 `RectTree.stamp` 同形：兩位小數、逢五遠離零。
    /// `0.665` 那條是實測值不是規格：`0.665` 在 double 裡實際是
    /// `0.66500000000000003552713678800500929355621337890625`，乘以 100 之後
    /// 剛好收斂成精確的 `66.5`（不是浮點誤差），`.toNearestOrAwayFromZero` 對
    /// 這個恰好的平局逢五遠離零，給 `67`。
    @Test func ratioLiteralMatchesStamp() {
        #expect(RectTree.ratioLiteral(0.7512) == "0.75")
        #expect(RectTree.ratioLiteral(0.665) == "0.67")
        #expect(RectTree.ratioLiteral(0.5) == "0.5")
        #expect(RectTree.ratioLiteral(.nan) == nil)
        #expect(RectTree.ratioLiteral(.infinity) == nil)
    }
}
