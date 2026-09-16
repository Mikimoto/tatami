import Foundation
import WorkmodeCore

/// 真的睡。對應 workmode.sh:627 的 `sleep 1` 與 653 的 `sleep 0.1`。
///
/// 這個型別沒有任何邏輯可測，它整個存在的價值在於**它不是** Core 的一部分：
/// 有了這個 port，`restore_minimized` 與 `ensure_app` 的輪詢測試不必真的睡。
public struct SystemClock: Clock, Sendable {
    public init() {}

    /// 負值與零不睡（`Thread.sleep` 對它們本來就立刻返回）——`sleep -1` 在 bash
    /// 是錯誤，但沒有呼叫點會傳負值，複製那個錯誤沒有意義。
    public func sleep(seconds: Double) {
        guard seconds > 0 else { return }
        Thread.sleep(forTimeInterval: seconds)
    }
}
