import Testing
import WorkmodeCore

// 「這個行程要不要自己聽 space 切換」。
//
// 2026-09-15 之前這裡還有第二個問題——「yabai 的 signal 還裝著嗎」——因為兩個來源
// 同時開著就是每次切 space 排兩次。yabai 退場之後那個問題連同 `SignalBlock` 一起
// 沒了，所以這一組只剩「開關開了沒」，而它唯一有鑑別力的地方是**哪些字算開**。

@Test func theAppObservesWhenTheSwitchIsOn() {
    #expect(SpaceWatchDecision.decide(state: "autospace=on\n") == .observe)
}

@Test func theSwitchOffMeansDisabled() {
    #expect(SpaceWatchDecision.decide(state: "") == .disabled)
    #expect(SpaceWatchDecision.decide(state: "autospace=off\n") == .disabled)
}

/// `on` 以外的值都是關——包含 `true`／`1`／`ON`。
///
/// 收窄成單一字面值是刻意的：狀態檔是人手改得到的，而「哪些字算開」那份清單
/// 本身就是新的錯誤來源。**這條是這一組唯一有牙齒的**：把 `== "on"` 換成
/// 「非空就算開」的實作只有它會紅。
@Test func onlyTheLiteralOnCountsAsOn() {
    for value in ["true", "1", "ON", "yes"] {
        #expect(SpaceWatchDecision.decide(state: "autospace=\(value)\n") == .disabled,
                "「\(value)」被當成開了")
    }
}
