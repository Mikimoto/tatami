import Testing
import WorkmodeCore
import WorkmodeEditorControl
import WorkmodeEditorModel

private let seamPath = "/x/scripts/layout.json"

/// 與 `EditorControllerTests` 的 `oneRule` 同一份：共用層真的有一條規則，所以
/// `settingRuleField` 走得通、controller 才進得了 dirty。空的 `windows` 會讓那次
/// 編輯不生效，`isDirty` 照樣是 false，`dirtyRefusesWithoutRunningAnything` 就變成
/// 在測 `notWired` 以外的另一條路。
private let seamLayout = #"{"windows":[{"label":"甲","match":["app","A"]}],"# +
    #""home":{"desc":"家","displays":{"main":"A"},"# +
    #""profiles":{"開發":{"trees":{}}}}}"#

/// 記錄每一次呼叫的 want。**`calls` 是這個 fake 存在的理由**——結果可以造假，
/// 「有沒有真的下命令」不行。
///
/// 2026-08-30 之前它記的是 `ApplyLayout.Mode`（那條路徑有 probe／apply 兩個 mode）。
/// `SpaceLayout` 沒有 mode，所以現在記的就是每一次呼叫本身。
private final class RecordingApply {
    var calls: [String] = []
    var outcome: SpaceLayout.Outcome = .completed(location: "office", profile: "開發")

    func run(_ want: String) -> ApplyRun {
        calls.append(want)
        return ApplyRun(outcome: outcome, lines: ["一行事件\n"])
    }
}

private func makeController(
    apply: ((String) -> ApplyRun)?
) throws -> EditorController {
    let controller = EditorController(files: ReadOnlyStore(text: seamLayout + "\n"),
                                      layoutPath: seamPath,
                                      runLayout: apply)
    try controller.load()
    return controller
}

/// 照 `EditorControllerTests` 的做法：改共用層第 0 條規則的 label。
private func makeDirty(_ controller: EditorController) {
    controller.apply { $0.settingRuleField(.shared, index: 0, field: .label, to: "改過") }
    #expect(controller.isDirty, "這個 fixture 要真的進得了 dirty，否則下面那條在測別的東西")
}

@Suite("套用的接縫")
struct ApplySeamTests {
    /// 乾淨且接上線就是可以套用。**不再問地點**：`SpaceLayout` 沒有 probe 模式，
    /// 而我們刻意不加一個（`ApplyReadiness` 的 doc 寫了為什麼）。
    @Test func readyWhenSavedAndWired() throws {
        let fake = RecordingApply()
        let controller = try makeController(apply: fake.run)
        #expect(controller.applyReadiness() == .ready)
    }

    /// **問「能不能套」的時候一個命令都不下。** 2026-08-30 之前這條叫
    /// `askingWhereWeAreUsesProbe`，斷言的是 `fake.calls == [.probe]`——那時
    /// `applyReadiness` 真的會跑一次 probe。現在它一個 port 都不碰，所以斷言反過來：
    /// 把 `applyNow` 的內容誤植到 `applyReadiness` 的實作在這條紅，而在真實世界
    /// 那個突變會在使用者確認之前搬動他的視窗。
    @Test func askingDoesNotRunAnything() throws {
        let fake = RecordingApply()
        let controller = try makeController(apply: fake.run)
        _ = controller.applyReadiness()
        #expect(fake.calls.isEmpty, "只是問能不能套，卻已經下了命令：\(fake.calls)")
    }

    /// 未存檔時**一個命令都不下**。
    ///
    /// 鑑別力在 `fake.calls.isEmpty` 而不是回傳值：把 guard 搬到跑 `--space` 之後，
    /// `== .notSaved` 那條**照樣綠**（2026-08-20 對舊版實測，把 isEmpty 那行註解掉
    /// 再跑一次，8 條全過）。回傳值對了不代表沒有多做事。
    @Test func dirtyRefusesWithoutRunningAnything() throws {
        let fake = RecordingApply()
        let controller = try makeController(apply: fake.run)
        makeDirty(controller)
        #expect(controller.applyReadiness() == .notSaved)
        #expect(fake.calls.isEmpty, "未存檔卻已經下了命令：\(fake.calls)")
    }

    @Test func withoutAnInjectedRunItIsNotWired() throws {
        let controller = try makeController(apply: nil)
        #expect(controller.applyReadiness() == .notWired)
    }

    /// 真的套用時 want 是**空字串**＝照設定決定 profile，與 `runSpaceLayout(want: "")`
    /// 一致。編輯器不再指定 profile：`--space` 那條路徑自己會從狀態檔決定。
    @Test func applyingPassesTheEmptyWant() throws {
        let fake = RecordingApply()
        let controller = try makeController(apply: fake.run)
        let run = controller.applyNow(.ready)
        #expect(fake.calls == [""])
        #expect(run?.lines == ["一行事件\n"])
    }

    /// **不是 ready 就一個 command 都不下。** `fake.calls.isEmpty` 是這條的鑑別力
    /// ——回 nil 但照樣呼叫過的實作在這裡紅，而那個實作在真實世界會搬視窗。
    @Test func applyingWithoutReadinessDoesNothing() throws {
        let fake = RecordingApply()
        let controller = try makeController(apply: fake.run)
        #expect(controller.applyNow(.notSaved) == nil)
        #expect(controller.applyNow(.notWired) == nil)
        #expect(fake.calls.isEmpty)
    }
}
