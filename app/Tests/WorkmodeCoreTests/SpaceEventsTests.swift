import Testing
import WorkmodeCore
import WorkmodeDomain

// `channel` 沒有任何測試在看（2026-09-03 突變實測：`.frameRejected` 改成 `.stdout`
// 全套 1103 條全綠）。那個欄位的意義是「呼叫端 `2>/dev/null` 時哪些話會消失」，
// 改錯了在畫面上完全看不出來——這一條就是它的第二道網子。

@Test func frameRejectedGoesToStderr() {
    let rect = Rect(originX: 0, originY: 0, width: 1, height: 1)
    #expect(SpaceEvent.frameRejected(label: "A", wanted: rect, actual: nil).channel == .stderr)
}
