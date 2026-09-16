import Testing
import WorkmodeCore
import WorkmodeDomain

// `--save --all` 的測試。**與 `SaveLayoutTests.swift` 分檔的理由是 lint**：
// 那個檔加完這兩條是 477 行（`file_length` 上限 400，`.swiftlint.yml` 的檔頭
// 明文禁止調參數）。fixture 與 harness 留在原檔（同一個 target 看得到）。

// MARK: - `--save --all`

/// 三個 space 在同一台螢幕上，只有一個看得見。
private let threeSpacesOneVisible = JSONValue.array([
    .object([JSONMember(key: "display", value: .number("1")),
             JSONMember(key: "index", value: .number("1")),
             JSONMember(key: "uuid", value: .string("SPACE-A")),
             JSONMember(key: "is-visible", value: .bool(true))]),
    .object([JSONMember(key: "display", value: .number("1")),
             JSONMember(key: "index", value: .number("2")),
             JSONMember(key: "uuid", value: .string("SPACE-B")),
             JSONMember(key: "is-visible", value: .bool(false))]),
    // 第三個上面沒有視窗——`--all` 底下那是常態，要安靜跳過。
    .object([JSONMember(key: "display", value: .number("1")),
             JSONMember(key: "index", value: .number("3")),
             JSONMember(key: "uuid", value: .string("SPACE-C")),
             JSONMember(key: "is-visible", value: .bool(false))]),
])

/// `--all` 存的是**每一個有視窗的 space**，`--visible` 只存看得見的那一個。
///
/// 這條的鑑別力在「同一個角色的兩個 uuid 要落在**同一個**角色成員底下」：
/// 每個 space 各吐一個同名成員的話，`spaceTrees` 會有重複的角色鍵而
/// `ProfileMerge.mergeSpaceTrees` 只留一個——症狀是「存了兩個 space、
/// 只有一個進得去」，而存檔本身完全成功。
///
/// 兩個視窗都要在 `.windows` 裡而且都要有規則認得，否則第二個會被問名字、
/// 把覆寫提示的答案吃掉（第一版就是這樣紅的）。
@Test func savingAllSpacesGroupsThemUnderOneRole() {
    let first = window(id: "7", app: "Ghostty", title: "t", originX: 0, width: 100)
    let second = window(id: "8", app: "Zed", title: "t", originX: 0, width: 100)
    let scene = harness(
        config: config(catalog: [("Code", "Ghostty"), ("Edit", "Zed")]),
        windows: [first, second],
        answers: ["y"],
        spaces: threeSpacesOneVisible,
        // 第三個 space 上沒有視窗——`--all` 底下那是常態，要安靜跳過。
        windowsBySpace: ["1": [first], "2": [second], "3": []]
    )
    #expect(scene.runAll("") == .written(path: saveLayoutPath))
    #expect(shapeCount(scene) == 2)
    // 沒被寫到的 space 在 `--all` 底下不該被報成「因為看不見所以跳過」。
    let skipped = scene.reporter.events.filter { event in
        if case .save(.writing(.saveSkippedInvisibleSpaces)) = event {
            return true
        }
        return false
    }
    #expect(skipped.isEmpty)
}

/// 同一份畫面用 `--visible` 存，只會有一棵樹。這是上一條的對照組——
/// 少了它，「`--all` 存到兩個」與「這個 fixture 本來就會存到兩個」分不出來。
@Test func savingOnlyTheVisibleSpaceStillTakesOne() {
    let first = window(id: "7", app: "Ghostty", title: "t", originX: 0, width: 100)
    let second = window(id: "8", app: "Zed", title: "t", originX: 0, width: 100)
    let scene = harness(
        config: config(catalog: [("Code", "Ghostty"), ("Edit", "Zed")]),
        windows: [first, second],
        answers: ["y"],
        spaces: threeSpacesOneVisible,
        windowsBySpace: ["1": [first], "2": [second]]
    )
    #expect(scene.run("") == .written(path: saveLayoutPath))
    #expect(shapeCount(scene) == 1)
}

private func shapeCount(_ scene: SaveScene) -> Int {
    scene.reporter.events.filter {
        if case .save(.shaping(.saveRoleShape)) = $0 {
            return true
        }
        return false
    }.count
}

// MARK: - 選單列那條（`Interaction.automatic`）

/// 沒有 tty 也跑得起來——選單列沒有 tty，而那條路一個問題都不問。
/// **`--save` 從終端機跑仍然要 tty**，那個守衛只是不再套用到這條路上。
@Test func theAutomaticPathDoesNotNeedATerminal() {
    let first = window(id: "7", app: "Ghostty", title: "t", originX: 0, width: 100)
    let scene = harness(config: config(catalog: [("Code", "Ghostty")]),
                        windows: [first], hasTTY: false,
                        spaces: threeSpacesOneVisible,
                        windowsBySpace: ["1": [first]])
    #expect(scene.runAutomatic("開發", true) == .written(path: saveLayoutPath))
    // 對照組：同一份畫面從終端機那條跑會被 tty 守衛擋下。
    #expect(scene.run("") == .needsTerminal)
}

/// **推不出身分**的視窗跳過並說出來。不說的話使用者會以為它存進去了，
/// 而下次套用時它不會出現——那是查不出來的。
///
/// **fixture 2026-09-10 換過**：這條原本是「一個 Ghostty ＋ 一個沒有規則的 Zed」，
/// 而那個 Zed 現在推得出身分（`["app", "Zed"]`），所以它不再是這條測試的輸入。
/// 真的推不出來要滿足 `AutoWindowName` 的守衛：那個 app **已經有**一條 catch-all
/// 而這個視窗不是單分頁的 Safari，也就是「兩個 Zed 視窗、只有一條認得 Zed 的規則」
/// ——使用者回報的正是這個形狀（只是他那邊是 Safari）。
@Test func unnamedWindowsAreSkippedOutLoud() {
    let named = window(id: "7", app: "Ghostty", title: "t", originX: 0, width: 100)
    let claimed = window(id: "8", app: "Zed", title: "t", originX: 200, width: 100)
    let leftover = window(id: "9", app: "Zed", title: "t", originX: 400, width: 100)
    let scene = harness(config: config(catalog: [("Code", "Ghostty"), ("Edit", "Zed")]),
                        windows: [named, claimed, leftover], hasTTY: false,
                        spaces: threeSpacesOneVisible,
                        windowsBySpace: ["1": [named, claimed, leftover]])
    #expect(scene.runAutomatic("開發", true) == .written(path: saveLayoutPath))
    #expect(skippedCounts(scene) == [1])
    // 對照組：那一輪一條規則都沒推。少了它，「跳過了」與「推了一條又跳過一個」
    // 分不出來，而後者是 catch-all 那道守衛失效的樣子。
    #expect(inventedRules(scene).isEmpty)
}

/// 選單列那條**自己推規則**，不再靜默跳過。使用者回報的原句是「有一個不認識的
/// Safari 視窗，無法紀錄排版」，而這條測試就是那個視窗。
///
/// 這裡也是唯一驗到「dump 真的餵到 `AutoWindowName` 了」的地方：拿不到 dump 的話
/// 分頁數是 0，那條分支走不到，規則會變成 `app Safari`。
///
/// `.written` 本身就證明那條規則**進了設定**：樹引用的 label 不在生效的 windows
/// 清單裡時 `LayoutValidator` 會擋下來（`LayoutValidator.swift:298`），
/// 而 `format` 是 fake 的、看不到寫出去的內容。
@Test func theAutomaticPathInventsARuleForAWindowNobodyNamed() {
    let safari = window(id: "7", app: "Safari", title: "Meet", originX: 0, width: 100)
    let scene = harness(windows: [safari], hasTTY: false,
                        safariDump: "7\thttps://meet.google.com/abc\tMeet\t1")
    #expect(scene.runAutomatic("新", true) == .written(path: saveLayoutPath))
    #expect(inventedRules(scene) == ["Safari｜url-contains https://meet.google.com/abc"])
    #expect(skippedCounts(scene).isEmpty)
}

/// 同一次存檔的第二個視窗要看得見前面剛加的那一條。兩種記帳各驗一次
/// （`SaveAutoNames.remember`）：
///
/// * 兩個各只有一個分頁的 Safari 視窗都推得出規則，所以 label 不能撞——撞了的話
///   `LayoutValidator` 的重複 label 檢查會把整次存檔擋成 `.rejected`。
/// * 兩個 Zed 視窗只有第一個拿得到 `["app", "Zed"]`，第二個沒有身分可推：再加一條
///   一模一樣的 match，誰認到哪個視窗就由執行時的順序決定。
@Test func theSecondUnnamedWindowSeesWhatThisRunJustAdded() {
    let meet = window(id: "7", app: "Safari", title: "Meet", originX: 0, width: 100)
    let inbox = window(id: "8", app: "Safari", title: "Inbox", originX: 200, width: 100)
    let safaris = harness(windows: [meet, inbox], hasTTY: false,
                          safariDump: "7\thttps://meet.google.com/abc\tMeet\t1\n"
                              + "8\thttps://mail.example/inbox\tInbox\t1")
    #expect(safaris.runAutomatic("新", true) == .written(path: saveLayoutPath))
    #expect(inventedRules(safaris) == ["Safari｜url-contains https://meet.google.com/abc",
                                       "Safari 2｜url-contains https://mail.example/inbox"])

    let zeds = harness(windows: [window(id: "7", app: "Zed", title: "a",
                                        originX: 0, width: 100),
                                 window(id: "8", app: "Zed", title: "b",
                                        originX: 200, width: 100)],
                       hasTTY: false)
    #expect(zeds.runAutomatic("新", true) == .written(path: saveLayoutPath))
    #expect(inventedRules(zeds) == ["Zed｜app Zed"])
    #expect(skippedCounts(zeds) == [1])
}

/// 自動推出來的規則，一條一個字串（`<label>｜<match>`）。全形豎線是分隔符：
/// label 與 match 都可能含空白（`Safari 2`、`url-contains …`）。
private func inventedRules(_ scene: SaveScene) -> [String] {
    scene.reporter.events.compactMap { event -> String? in
        if case let .save(.writing(.saveRuleInvented(label, match))) = event {
            return "\(label)｜\(match)"
        }
        return nil
    }
}

private func skippedCounts(_ scene: SaveScene) -> [Int] {
    scene.reporter.events.compactMap { event -> Int? in
        if case let .save(.writing(.saveSkippedUnnamed(count))) = event {
            return count
        }
        return nil
    }
}

/// **`overwrite: false` 碰到既有的 profile 要擋下來**，而不是靜默覆蓋。
/// 「存成新 profile」那條路傳的就是 false——名字撞到既有的時，使用者要的
/// 顯然不是把它蓋掉。
@Test func savingIntoAnExistingProfileWithoutPermissionIsRefused() {
    let first = window(id: "7", app: "Ghostty", title: "t", originX: 0, width: 100)
    let scene = harness(config: config(catalog: [("Code", "Ghostty")]),
                        windows: [first], hasTTY: false,
                        spaces: threeSpacesOneVisible,
                        windowsBySpace: ["1": [first]])
    #expect(scene.runAutomatic("開發", false) == .cancelled)
    #expect(scene.files.writes.isEmpty)
    // 名字是新的就照寫，不必任何許可。
    #expect(scene.runAutomatic("新的", false) == .written(path: saveLayoutPath))
}

/// 一個 space 切不開成 bsp 樹，**不擋後面那些**。
///
/// 2026-09-08 實際發生：`main` 上有兩個沒在樹裡的 Finder 視窗擠在一起，
/// `RectTree.fromRects` 回 null，而當時那一行是 `return nil`——整趟 `--save --all`
/// 因此一個字都不寫，而訊息指的是使用者當下沒在看的那台螢幕。
/// 與 `SpaceLayoutTests` 那六條 `…DoesNotStopTheOnesAfterIt` 同一條規則。
@Test func anUnsplittableSpaceDoesNotStopTheOnesAfterIt() {
    // **部分重疊**才切不開（實測 `__diff rects_to_tree` 回 null）。完全相同的兩個
    // 矩形不行——`SpaceRects.compute` 會把它們去重成一個，於是那個 space 反而正常。
    let clash = [window(id: "7", app: "Ghostty", title: "t", originX: 0, width: 100),
                 window(id: "8", app: "Zed", title: "t", originX: 50, width: 100)]
    let clean = window(id: "9", app: "Mail", title: "t", originX: 0, width: 100)
    let scene = harness(
        config: config(catalog: [("Code", "Ghostty"), ("Edit", "Zed"), ("Mail", "Mail")]),
        windows: clash + [clean],
        answers: ["y"],
        spaces: threeSpacesOneVisible,
        windowsBySpace: ["1": clash, "2": [clean], "3": []]
    )
    #expect(scene.runAll("") == .written(path: saveLayoutPath))
    // 鑑別力在**這一行**：切不開的那個 space 沒有形狀，乾淨的那個有，所以恰好 1。
    // 只斷言 `.written` 的話，「兩個都存進去了」也會過。
    #expect(shapeCount(scene) == 1)
    let unsplittable = scene.reporter.events.filter { event in
        if case .save(.shaping(.saveRoleNotSplittable)) = event {
            return true
        }
        return false
    }
    #expect(unsplittable.count == 1)
}

/// 沒有名字的視窗**不參與幾何**，所以它擋不住存檔。
///
/// 2026-09-08 的使用者裁決。原本 `fromRects` 拿全部矩形切樹、`prune` 事後剪掉沒有
/// 名字的葉；bsp 退役之後畫面不再必定是一個可對切的分割，於是一個隨手擺的 Finder
/// 視窗就讓那個 space 存不下來——而它反正會被剪掉。
///
/// 鑑別力在**部分重疊**：疊在 Ghostty 上一半的那個，兩個一起餵給 `fromRects` 回 null。
/// 不重疊的話舊實作也切得開，這條測試就對那個順序沒有意見。
///
/// **fixture 2026-09-10 換過**（與 `unnamedWindowsAreSkippedOutLoud` 同一個理由）：
/// 原本那個沒有規則的 Zed 現在會被自動命名，於是它**變成有名字的視窗**而理當
/// 參與幾何。要讓它真的沒有名字，就得讓 Zed 已經有一條 catch-all 而畫面上有兩個
/// Zed 視窗——先到先得，第二個誰都認不出來（`RuleResolution.firstUnclaimed` 取的是
/// 視窗清單裡的第一個，所以被認領的是排在前面的那個）。
@Test func anUnnamedWindowDoesNotBlockTheSave() {
    let scene = harness(
        config: config(catalog: [("Code", "Ghostty"), ("Edit", "Zed")]),
        windows: [window(id: "7", app: "Ghostty", title: "t", originX: 0, width: 100),
                  window(id: "8", app: "Zed", title: "t", originX: 200, width: 100),
                  // 這一個沒人認得也推不出身分（Zed 已經有 catch-all），所以它
                  // 既不進樹也不該擋住存檔——即使它疊在 Ghostty 上一半。
                  window(id: "9", app: "Zed", title: "t", originX: 50, width: 100)]
    )
    #expect(scene.runAutomatic("", true) == .written(path: saveLayoutPath))
    #expect(shapes(scene) == ["(Code v Edit)"])
}

/// **自動命名的代價，以及它的退路。** 上一條的不變式是「**沒有名字的**視窗不參與
/// 幾何」，而自動命名改變的是「哪些視窗沒有名字」：一個隨手擺的陌生視窗現在推得出
/// 規則，於是它參與幾何，而畫面本來就不是一個可對切的分割時整個 space 就存不下來。
///
/// 2026-09-10 使用者裁決：**丟掉這一輪自己命名的那些再試一次**，其餘照存，並說出
/// 是哪一扇窗沒進去。所以這條的期望值換過兩次——原本是 `.written`（那個視窗被
/// 靜默丟掉、一句話都沒有），Task 4 之後是 `.rejected`（它參與幾何而擋住整個
/// space），現在是 `.written` 加一句話。三者的差別全在「有沒有告訴使用者」。
///
/// 鑑別力在後兩行：只斷言 `.written` 的話，「連 Ghostty 也沒存」與「Ghostty 存了、
/// Zed 沒進去」分不出來。而規則**仍然要加**——它無害（`LayoutValidator` 只查
/// 「樹的 label 都在生效清單裡」這一個方向），而下次那個視窗不重疊時就認得出來了。
@Test func aWindowThisRunNamedStepsAsideWhenTheSpaceCannotBeSplit() {
    let scene = harness(
        config: config(catalog: [("Code", "Ghostty")]),
        windows: [window(id: "7", app: "Ghostty", title: "t", originX: 0, width: 100),
                  window(id: "8", app: "Zed", title: "t", originX: 50, width: 100)]
    )
    #expect(scene.runAutomatic("", true) == .written(path: saveLayoutPath))
    #expect(shapes(scene) == ["Code"])
    #expect(overlapLosses(scene) == ["main｜Zed"])
    #expect(inventedRules(scene) == ["Zed｜app Zed"])
}

/// **對照組：切得開就照常全部進樹。** 少了它，「一律把這一輪命名的那些丟掉」
/// 與正確實作分不出來——而那等於整個自動命名功能沒做。
///
/// 與上一條的唯一差別是 Zed 的位置（50 → 200，不再疊在 Ghostty 上）。
@Test func aWindowThisRunNamedTakesPartInTheGeometryWhenItFits() {
    let scene = harness(
        config: config(catalog: [("Code", "Ghostty")]),
        windows: [window(id: "7", app: "Ghostty", title: "t", originX: 0, width: 100),
                  window(id: "8", app: "Zed", title: "t", originX: 200, width: 100)]
    )
    #expect(scene.runAutomatic("", true) == .written(path: saveLayoutPath))
    #expect(shapes(scene) == ["(Code v Zed)"])
    #expect(overlapLosses(scene).isEmpty)
}

/// 拿掉這一輪命名的那些**還是**切不開 → 照舊 `saveRoleNotSplittable`。
///
/// 這裡是**總表裡的兩條規則**各自認得的兩個視窗疊在一起（Ghostty 與 Zed），
/// 自動命名的 Mail 只是旁邊那個切得開的。丟掉 Mail 之後那對還在，所以整個角色不存。
///
/// **那時不報「某某沒能存進去」**：一棵樹都沒存，再點名一扇窗會讓人以為其餘的
/// 存進去了。少了最後那一行，把回報搬到重試**之前**也會過。
@Test func droppingWhatThisRunNamedIsNotAlwaysEnough() {
    let scene = harness(
        config: config(catalog: [("Code", "Ghostty"), ("Edit", "Zed")]),
        windows: [window(id: "7", app: "Ghostty", title: "t", originX: 0, width: 100),
                  window(id: "8", app: "Zed", title: "t", originX: 50, width: 100),
                  window(id: "9", app: "Mail", title: "t", originX: 200, width: 100)]
    )
    #expect(scene.runAutomatic("", true) == .rejected)
    #expect(scene.files.writes.isEmpty)
    #expect(inventedRules(scene) == ["Mail｜app Mail"])
    #expect(overlapLosses(scene).isEmpty)
}

/// **使用者親手打的名字丟不得。** 他剛剛才回答要存這個視窗，靜默扔掉是在推翻
/// 那個回答；終端機那條照舊整個角色不存，他看得見也改得動。
///
/// 這條是 `Named.invented` 存在的理由：`labels` 分不出兩者，拿它當退路的依據的話
/// 這份畫面會變成 `.written` 而 Zed 無聲消失。
@Test func aWindowTheUserNamedByHandIsNeverDroppedForOverlap() {
    let scene = harness(
        config: config(catalog: [("Code", "Ghostty")]),
        windows: [window(id: "7", app: "Ghostty", title: "t", originX: 0, width: 100),
                  window(id: "8", app: "Zed", title: "t", originX: 50, width: 100)],
        answers: ["手打的"]
    )
    #expect(scene.run("全新的") == .rejected)
    #expect(scene.files.writes.isEmpty)
    #expect(overlapLosses(scene).isEmpty)
}

/// 因為重疊而沒進樹的視窗，一個一個字串（`<角色>｜<label>`）。
private func overlapLosses(_ scene: SaveScene) -> [String] {
    scene.reporter.events.compactMap { event -> String? in
        if case let .save(.shaping(.saveWindowLostToOverlap(role, label))) = event {
            return "\(role)｜\(label)"
        }
        return nil
    }
}

private func shapes(_ scene: SaveScene) -> [String] {
    scene.reporter.events.compactMap { event -> String? in
        if case let .save(.shaping(.saveRoleShape(_, shape))) = event {
            return shape
        }
        return nil
    }
}
