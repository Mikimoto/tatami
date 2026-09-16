import Testing
import WorkmodeAdapters
import WorkmodeCore
import WorkmodeDomain

// 送到哪個流由事件自己決定，不是 renderer 決定。這件事有作用而不是排版：
// `save_layout` 用 `2>/dev/null` 壓掉整批訊息（workmode.sh:1106），而 `main`
// 呼叫同一支時沒有（1306）。
//
// **fixture 2026-09-07 換過**：原本三條全用 `strangersExiled` 那組（`StrangerExile`
// 隨 `ApplyLayout` 一起退役），而那三個事件**都走 stdout**——所以整份測試對
// 「TextReporter 把 channel 寫死成 `.stdout`」這個突變**完全沒有鑑別力**。
// 現在的一對是混的：`minimizedWindowRestored` 走 stdout、`frameRejected` 走 stderr。

private final class RecordingSink: EventSink {
    private(set) var written: [(text: String, channel: OutputChannel)] = []

    func write(_ text: String, to channel: OutputChannel) {
        written.append((text, channel))
    }
}

/// 送出去的兩個事件各自落在自己宣告的流。
///
/// 鑑別值是 `[.stdout, .stderr]`：寫死任一個值的實作回兩個相同的元素。
@Test func writesEachEventToTheChannelTheEventItselfNames() {
    let sink = RecordingSink()
    let reporter = TextReporter(renderer: HumanEventRenderer(), sink: sink)
    // `frameRejected` **沒有** `EventFactories` 的一行建構子（它是 `--space` 引擎
    // 新增的，不是從 bash 移植過來的 printf 站點），所以這裡寫完整路徑。
    let rejected = WorkmodeEvent.space(.frameRejected(
        label: "Code",
        wanted: Rect(originX: 0, originY: 0, width: 10, height: 10),
        actual: nil
    ))

    reporter.report(.minimizedWindowRestored(label: "Chat"))
    reporter.report(rejected)

    #expect(sink.written.map(\.channel) == [.stdout, .stderr])
    #expect(sink.written.map(\.text) == [
        HumanEventRenderer().render(.minimizedWindowRestored(label: "Chat")),
        HumanEventRenderer().render(rejected),
    ])
}

/// 失敗訊息不一定走 stderr——`workmode.sh` 的慣例是失敗路徑用 `!` 開頭。
///
/// `minimizedWindowRestoreFailed` 是那個慣例活著的例子：它是一句失敗訊息而走
/// **stdout**。這條釘住它，免得有人「順手把失敗的都改成 stderr」。
@Test func aFailureMessageCanStillGoToStdout() {
    #expect(WorkmodeEvent.minimizedWindowRestoreFailed(label: "A").channel == .stdout)
    #expect(WorkmodeEvent.minimizedWindowRestored(label: "A").channel == .stdout)
}

/// 同一個 reporter 接哪個 renderer 都行，而流的決定不隨 renderer 改變。
///
/// 用走 **stderr** 的那個事件問：拿 stdout 的問，「renderer 決定 channel」與
/// 「事件決定 channel」在這條上會給同一個答案。
@Test func theJSONRendererUsesTheSameChannelDecision() {
    let sink = RecordingSink()

    TextReporter(renderer: JSONEventRenderer(), sink: sink)
        .report(.space(.frameRejected(
            label: "Code",
            wanted: Rect(originX: 0, originY: 0, width: 10, height: 10),
            actual: nil
        )))

    #expect(sink.written.count == 1)
    #expect(sink.written[0].channel == .stderr)
    #expect(sink.written[0].text.hasPrefix("{"))
}
