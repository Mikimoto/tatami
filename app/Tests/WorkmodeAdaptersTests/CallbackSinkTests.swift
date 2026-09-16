import Testing
import WorkmodeAdapters
import WorkmodeCore

// `CallbackSink` 是編輯器那條路徑的落點：事件文字進一個閉包而不是 `FileHandle`。
// 這裡驗的只有兩件事——兩個 channel 都收，以及順序沒被動過。

/// 兩個 channel 的文字**都要收**，而且**照發生順序**。
///
/// stdout／stderr 的分別在 bash 是有作用的（`save_layout` 用 `2>/dev/null` 壓掉
/// 一整批訊息），但編輯器兩種都要給使用者看——分成兩個陣列只會讓呼叫端猜要顯示
/// 哪一個。**順序**是這條測試的鑑別力所在：把 `append` 換成插到開頭就紅
/// （2026-08-20 實測：`["三\n", "二\n", "一\n"]`）。
@Test func itKeepsBothChannelsInOrder() {
    var seen: [String] = []
    let sink = CallbackSink { seen.append($0) }

    sink.write("一\n", to: .stdout)
    sink.write("二\n", to: .stderr)
    sink.write("三\n", to: .stdout)

    #expect(seen == ["一\n", "二\n", "三\n"])
}

/// 接上真的 reporter 也要收得到——`TextReporter` 持有 `any EventSink`，
/// 而 `CallbackSink` 是 struct，這條釘住它被複製一份之後閉包仍指向同一個 `seen`。
@Test func itCollectsWhatTheReporterRenders() {
    var seen: [String] = []
    let reporter = TextReporter(renderer: HumanEventRenderer(), sink: CallbackSink { seen.append($0) })

    reporter.report(.minimizedWindowRestored(label: "A"))

    #expect(seen == [HumanEventRenderer().render(.minimizedWindowRestored(label: "A"))])
}
