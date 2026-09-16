import Testing
import WorkmodeCore
import WorkmodeDomain

// `workmode --space` 的編排。與 ApplyLayoutTests 同一種立場：這支自己不算任何東西，
// 所以驗的全是**分支與順序**——**三種**「查不到就跳過這個螢幕」（螢幕沒接上、
// 抓不到可見的 space、這個 uuid 沒有樹）、每一種都不擋後面的角色，
// 以及**不流放陌生視窗**。
//
// 2026-08-30 之前是四種：名字那一層拿掉之後，「space 沒命名」與「名字沒有樹」
// 併成同一件事——這個 uuid 在 `spaceTrees` 裡沒有樹。
//
// 每條斷言都打在 `yabai.commandArgv`（真的下了什麼命令）與 `server.calls`（真的設了
// 什麼 frame）而不是回傳值：回傳值在「什麼都沒做」與「做對了」兩種情況下都是
// `.completed`，證明不了任何事。
//
// 2026-09-03 換引擎（`TreeLayout` → `FrameLayout`）之後，`yabai.commandArgv` 只剩
// `--space` 與 `--deminimize`；擺位那半移到 `server.calls`。所以「什麼都沒做」的護欄
// 有兩個可觀測量，兩個都要看——只看 argv 的話，一個把 frame 設到 0×0 畫布上的實作
// 照樣通過。

@Test func aVisibleSpaceWithATreeGetsIt() {
    let scene = spaceHarness()
    #expect(scene.run("") == .completed(location: "home", profile: "開發"))
    // 單葉樹＝搬到那個 space（**2**，可見的那個，不是 1）然後填滿整台螢幕。
    #expect(scene.yabai.commandArgv == [["window", "7", "--space", "2"]])
    #expect(scene.server.calls == [.init(window: "7", frame: spcCanvas)])
    #expect(scene.reporter.events.contains(.space(.spaceLaidOut(role: "main", uuid: "U-1"))))
}

/// `displays` 的 frame 讀不到（缺欄位）→ 那個角色走「螢幕沒接上」，不下任何命令。
///
/// 鑑別值：`server.calls` 是空的——用 0×0 的畫布硬排會下一次 setFrame，而那個實作
/// 的 `commandArgv` 與正確的實作一模一樣（`moveToSpace` 不看畫布）。
@Test func aDisplayWithoutAFrameIsTreatedAsMissing() {
    let broken = JSONValue.array([.object([
        JSONMember(key: "uuid", value: .string("A")),
        JSONMember(key: "index", value: .number("1")),
    ])])
    let scene = spaceHarness(displays: broken)
    _ = scene.run("")
    #expect(scene.server.calls.isEmpty)
    #expect(scene.yabai.commandArgv.isEmpty)
    #expect(scene.reporter.events.contains(.space(.spaceRoleDisplayMissing(role: "main"))))
}

/// **最小化的視窗要先還原，再排版。**
///
/// 2026-08-29 使用者回報「把 Tower 縮小，切過去時它沒出現」。實機重現：`moveToSpace`
/// 對最小化的視窗**有效**（space 2 → 1），但 `--warp` 對不在 bsp 樹裡的視窗回
/// 「not managed」——所以它被搬到對的 space 卻仍然縮著，唯一的訊號是一句 warp 警告。
///
/// 斷言整份 `commandArgv` 而不只是「有沒有 deminimize」：**順序就是這條的全部內容**。
/// 把 `minimized.restore` 挪到 `applyTargets` 之後，fake 的 warp 不會因此失敗（真的
/// yabai 才會），所以只查「有沒有下過」的斷言在那個突變下照樣綠。
@Test func aMinimizedWindowIsRestoredBeforeTheTreeIsLaidOut() {
    let scene = spaceHarness()
    // 第一次查是 true（觸發還原），之後回 `spcStub` 那個 sticky 的 false（輪詢成功）。
    scene.yabai.stub(.window("7"), [.object([
        JSONMember(key: "id", value: .number("7")),
        JSONMember(key: "is-minimized", value: .bool(true)),
    ])])
    _ = scene.run("")
    #expect(scene.yabai.commandArgv == [
        ["window", "--deminimize", "7"],
        ["window", "7", "--space", "2"],
    ], "還原必須排在排版之前：\(scene.yabai.commandArgv)")
}

/// **可見的 space 的 `uuid` 不是字串** → 那個螢幕什麼都不做，而且不擋後面的角色。
///
/// 這條 2026-08-30 補上：那個 guard 是同一天新增的（把「uuid 不是字串」從「沒有名字」
/// 那條分出來），而**當時沒有任何輸入踩得到它**——把它的 `continue` 改成 `return out`，
/// `WorkmodeCoreTests` 158 條全綠。同一批突變裡另外三個 `continue` 各紅 2／1／1 條。
///
/// **兩台螢幕不是排場**：第一版的 fixture 只有一台，而「uuid 不是字串」來自
/// yabai 回的同一份 `--spaces`，所以同一台上的每個角色都會走進那個 guard，
/// 後面根本沒有正常的角色可以被擋——補完那條測試，同一個突變**還是全綠**。
/// 這與 2026-08-22 verifier 抓到的是同一個形狀（見下面那條護欄的 doc）。
///
/// uuid 是數字的 space 直接建 `JSONValue`：`spcSpace` 的 uuid 參數是 `String`，造不出來。
@Test func aVisibleSpaceWhoseUUIDIsNotAStringDoesNotStopTheOnesAfterIt() {
    let scene = spaceHarness(
        config: spcConfig(
            displays: [("壞掉", "A"), ("main", "B")],
            spaceTrees: [("壞掉", [("U-1", leaf("Code"))]), ("main", [("U-1", leaf("Code"))])]
        ),
        spaces: .array([
            // display 1 可見的那個：uuid 是數字，走那個 guard。
            .object([
                JSONMember(key: "display", value: .number("1")),
                JSONMember(key: "index", value: .number("2")),
                JSONMember(key: "uuid", value: .number("42")),
                JSONMember(key: "is-visible", value: .bool(true)),
            ]),
            // display 2 可見的那個：正常，`main` 要照樣被排。
            spcSpace(5, display: 2, uuid: "U-1", visible: true),
        ]),
        // 兩台都要帶完整的 frame：缺欄位的螢幕會被 `Displays.frame` 判成讀不到，
        // 而那個下場是「螢幕沒接上」——那會把這條要驗的分支整個繞過去。
        displays: .array([
            spcDisplay(uuid: "A", index: 1),
            spcDisplay(uuid: "B", index: 2),
        ])
    )
    _ = scene.run("")
    #expect(scene.reporter.events.contains(.space(.spaceRoleHasNoVisibleSpace(role: "壞掉"))))
    #expect(scene.yabai.commandArgv == [["window", "7", "--space", "5"]],
            "壞掉的 uuid 之後 main 沒有被排：\(scene.yabai.commandArgv)")
    #expect(scene.server.calls.count == 1, "壞掉的角色也被排了：\(scene.server.calls)")
}

/// 可見的 space 的 uuid 在 `spaceTrees` 裡沒有樹 → 那個螢幕一個命令都不下。
///
/// 鑑別力在 `commandArgv.isEmpty`：`spaceTrees` 照樣定義了 `U-1` 那棵樹，所以
/// 「跳過 uuid 比對、直接拿第一棵樹」的實作會在這裡下命令。
@Test func aVisibleSpaceWithNoTreeIsLeftAlone() {
    let scene = spaceHarness(spaces: JSONValue.array([
        spcSpace(2, display: 1, uuid: "U-其他", visible: true),
    ]))
    #expect(scene.run("") == .completed(location: "home", profile: "開發"))
    #expect(scene.yabai.commandArgv.isEmpty, "沒有樹的 space 不該被動：\(scene.yabai.commandArgv)")
    #expect(scene.reporter.events.contains(.space(.spaceHasNoTree(role: "main", uuid: "U-其他"))))
}

/// **兩棵樹，各查各的。** 只有一棵的話「拿第一個」與「查對的那個」同值，
/// 而那個突變正是這條要擋的。
@Test func eachSpaceGetsItsOwnTree() {
    let config = spcConfig(spaceTrees: [("main", [
        ("U-0", leaf("Code")),
        ("U-1", leaf("Chat")),
    ])])
    let scene = spaceHarness(config: config, extraWindows: [
        .object([
            JSONMember(key: "app", value: .string("Chat")),
            JSONMember(key: "id", value: .number("9")),
        ]),
    ])
    _ = scene.run("")
    // 可見的是 uuid `U-1`（spcSpaces 的 index 2），所以要套的是 `Chat` 那棵。
    #expect(scene.yabai.commandArgv == [["window", "9", "--space", "2"]],
            "查到的是別棵樹：\(scene.yabai.commandArgv)")
}

/// 一個角色查不到不該讓後面的角色跟著不動——迴圈是 `continue` 不是 `return`。
///
/// `second` 這個角色在 `displays` 裡沒有，所以它先發 `spaceRoleDisplayMissing`；
/// `main` 排在它後面（來源鍵序）而且照樣要排到。
@Test func oneBrokenRoleDoesNotStopTheOthers() {
    let scene = spaceHarness(config: spcConfig(
        spaceTrees: [("second", [("U-1", leaf("Code"))]), ("main", [("U-1", leaf("Code"))])]
    ))
    _ = scene.run("")
    #expect(scene.reporter.events.contains(.space(.spaceRoleDisplayMissing(role: "second"))))
    #expect(scene.yabai.commandArgv == [["window", "7", "--space", "2"]],
            "第一個角色壞掉之後 main 沒有被排：\(scene.yabai.commandArgv)")
}

/// spec 的 D1：`--space` **不流放**陌生視窗。
///
/// fixture 刻意在那個 space 上放一個不在樹裡的視窗（id 9、app `Mail`）——沒有它的話
/// 抄不抄 `ApplyLayout` 的 exile 那段都不會有 `--space` 命令，這條就恆真。
/// 唯一該出現的 `--space` 是把 id 7 搬進去那一次。
@Test func strangersAreNeverExiled() {
    let stranger = JSONValue.object([
        JSONMember(key: "app", value: .string("Mail")),
        JSONMember(key: "id", value: .number("9")),
    ])
    let scene = spaceHarness(extraWindows: [stranger])
    _ = scene.run("")
    #expect(!scene.yabai.commandArgv.contains { $0.contains("9") },
            "陌生視窗被動了：\(scene.yabai.commandArgv)")
    #expect(scene.yabai.commandArgv == [["window", "7", "--space", "2"]])
}

// MARK: - Safari 的 1.94 秒

// 這三條的鑑別力**完全**在 `safari.callCount`，不在回傳值：樹裡沒有 url label 時，
// dump 的內容根本不影響比對結果，所以只斷言結果等於沒有驗。
//
// 三條缺一不可——只有第一條的話「把整個 dump 呼叫拿掉」也會全綠。

/// 沒有 url 類規則 → 不問 Safari。
@Test func noURLRuleMeansNoSafariDump() {
    let scene = spaceHarness(safariOnSpace: true)
    _ = scene.run("")
    #expect(scene.safari.callCount == 0, "沒有 url 規則卻去 dump 了分頁")
}

/// 有 url 類規則、而且那個 space 上有 Safari → 問，而且只問一次。
@Test func aURLRuleWithSafariOnThatSpaceDoesDump() {
    let scene = spaceHarness(config: spcURLConfig(), safariOnSpace: true)
    _ = scene.run("")
    #expect(scene.safari.callCount == 1)
}

/// 有 url 類規則，但那個 space 上沒有 Safari → 不問。
@Test func aURLRuleWithNoSafariOnThatSpaceSkipsTheDump() {
    let scene = spaceHarness(config: spcURLConfig(), safariOnSpace: false)
    _ = scene.run("")
    #expect(scene.safari.callCount == 0, "那個 space 上沒有 Safari 卻去 dump 了分頁")
}

/// `fallback` 也算 url 類。`match` 是 app、`fallback` 是 url-contains——
/// 只看 `match` 的實作在這裡會判成「不需要」。
@Test func aURLFallbackAlsoCountsAsNeedingTheTabs() {
    let scene = spaceHarness(config: spcURLConfig(asFallback: true), safariOnSpace: true)
    _ = scene.run("")
    #expect(scene.safari.callCount == 1, "fallback 是 url 類卻沒去 dump")
}

// MARK: - 剩下兩種「跳過」

/// 螢幕在，但那台螢幕沒有任何可見的 space。
///
/// 2026-08-22 的 verifier 抓到這個 case **零測試覆蓋**——它的 `continue` 與那句
/// 中文都沒有任何斷言在守。
@Test func aDisplayWithNoVisibleSpaceIsLeftAlone() {
    let scene = spaceHarness(spaces: spcNoVisibleSpaces)
    _ = scene.run("")
    #expect(scene.yabai.commandArgv.isEmpty)
    #expect(scene.reporter.events.contains(.space(.spaceRoleHasNoVisibleSpace(role: "main"))))
}

/// 「這個 uuid 沒有樹」也不能擋住後面的角色。
///
/// 2026-08-22 的 verifier 實測：把那個分支的 `continue` 改成 `return out`，
/// **850 條全綠**——當時那條測試的 fixture 只有 `main` 一個角色，後面根本沒有
/// 第二個。三種跳過各要一條這樣的護欄。
@Test func aTreelessSpaceDoesNotStopTheOnesAfterIt() {
    let scene = spaceHarness(config: spcConfig(
        displays: [("main", "A"), ("second", "A")],
        // second 的可見 space 也是 U-1，但它的 spaceTrees 只定義了 U-9。
        spaceTrees: [("second", [("U-9", leaf("Code"))]), ("main", [("U-1", leaf("Code"))])]
    ))
    _ = scene.run("")
    #expect(scene.reporter.events.contains(.space(.spaceHasNoTree(role: "second", uuid: "U-1"))))
    #expect(scene.yabai.commandArgv == [["window", "7", "--space", "2"]],
            "second 沒有樹之後 main 沒有被排：\(scene.yabai.commandArgv)")
}

/// 「樹被剪光了」也不能擋住後面的角色。
///
/// 這是 `applyTargets` 裡的那個 `continue`（`SpaceLayout.swift:231`），與
/// `resolveTargets` 的四個是**不同的迴圈**。2026-08-30 由 fresh-context verifier
/// 量到它當時**沒有護欄**：把它改成 `return`，1085 條全綠。
///
/// 剪光的成因是「這棵樹引用的 label 一個都沒**解到視窗**」。`Chat` 那條規則存在
/// （所以 `validate` 過得了——樹只能引用生效的 label，引用不存在的 label 會被
/// `treeChecks` 擋在 `LayoutPreamble` 那一關，連迴圈都進不去），但 `spcStub` 的視窗
/// 清單只有 Ghostty，所以 `Chat` 解不到視窗、不在 `live` 裡，`prune` 於是回 nil。
@Test func aFullyPrunedTreeDoesNotStopTheOnesAfterIt() {
    let scene = spaceHarness(config: spcConfig(
        displays: [("main", "A"), ("second", "A")],
        spaceTrees: [("second", [("U-1", leaf("Chat"))]), ("main", [("U-1", leaf("Code"))])]
    ))
    _ = scene.run("")
    #expect(scene.reporter.events.contains(.space(.spaceHasNoTree(role: "second", uuid: "U-1"))))
    #expect(scene.yabai.commandArgv == [["window", "7", "--space", "2"]],
            "second 的樹被剪光之後 main 沒有被排：\(scene.yabai.commandArgv)")
}

/// **「frame 讀不到」也不能擋後面的角色**——它是「螢幕沒接上」的第二個入口，走的是
/// `resolveTargets` 裡另一個 `continue`（`Displays.frame` 那道 guard）。
///
/// 2026-09-03 實測：只有 `aDisplayWithoutAFrameIsTreatedAsMissing` 的時候，把那個
/// `continue` 改成 `return out` **1105 條全綠**——那條的 fixture 只有一台螢幕，
/// 後面根本沒有第二個角色可以被擋。這是 CLAUDE.md 記過兩次（2026-08-22、2026-08-30）
/// 的同一個形狀：護欄要驗的是「不擋後面」，就一定要有後面。
///
/// 鑑別值在 `server.calls` 非空——`main` 那台的 frame 是好的，只有它該被排。
@Test func aRoleWhoseDisplayHasNoFrameDoesNotStopTheOnesAfterIt() {
    let scene = spaceHarness(
        config: spcConfig(
            displays: [("壞掉", "A"), ("main", "B")],
            spaceTrees: [("壞掉", [("U-1", leaf("Code"))]), ("main", [("U-1", leaf("Code"))])]
        ),
        spaces: .array([
            spcSpace(2, display: 1, uuid: "U-1", visible: true),
            spcSpace(5, display: 2, uuid: "U-1", visible: true),
        ]),
        // A（index 1）**沒有 frame**；B（index 2）正常。
        displays: .array([
            .object([
                JSONMember(key: "uuid", value: .string("A")),
                JSONMember(key: "index", value: .number("1")),
            ]),
            spcDisplay(uuid: "B", index: 2),
        ])
    )
    _ = scene.run("")
    #expect(scene.reporter.events.contains(.space(.spaceRoleDisplayMissing(role: "壞掉"))))
    #expect(scene.server.calls == [.init(window: "7", frame: spcCanvas)],
            "frame 讀不到的螢幕之後 main 沒有被排：\(scene.server.calls)")
    #expect(scene.yabai.commandArgv == [["window", "7", "--space", "5"]])
}

/// 「螢幕沒接上」也不能擋後面（`nope` 這個角色在 `displays` 裡根本沒有）。
@Test func aDisplaylessRoleDoesNotStopTheOnesAfterIt() {
    let scene = spaceHarness(config: spcConfig(
        spaceTrees: [("nope", [("U-1", leaf("Code"))]), ("main", [("U-1", leaf("Code"))])]
    ))
    _ = scene.run("")
    #expect(scene.reporter.events.contains(.space(.spaceRoleDisplayMissing(role: "nope"))))
    #expect(scene.yabai.commandArgv == [["window", "7", "--space", "2"]])
}

/// 第四種：**螢幕接著、但它一個 space 都沒有**。與上面那條是不同的分支——
/// 那條在 `displays` 就查不到 uuid，這條查得到 index 卻在 `spaces` 裡沒有任何一筆。
///
/// 這是三種跳過裡最後一條護欄。2026-08-22 實測：只有前三條時，把這個分支的
/// `continue` 改成 `return out` **全綠**。
@Test func aRoleWhoseDisplayHasNoSpacesDoesNotStopTheOnesAfterIt() {
    let scene = spaceHarness(
        config: spcConfig(
            displays: [("main", "A"), ("second", "B")],
            spaceTrees: [("second", [("U-7", leaf("Code"))]), ("main", [("U-1", leaf("Code"))])]
        ),
        displays: spcTwoDisplays
    )
    _ = scene.run("")
    #expect(scene.reporter.events.contains(.space(.spaceRoleHasNoVisibleSpace(role: "second"))))
    #expect(scene.yabai.commandArgv == [["window", "7", "--space", "2"]],
            "second 沒有可見的 space 之後 main 沒有被排：\(scene.yabai.commandArgv)")
}
