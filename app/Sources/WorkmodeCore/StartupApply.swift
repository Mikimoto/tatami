/// 啟動時套版的重試判斷。
///
/// `yabai/yabairc` 檔尾原本是一段手寫的 shell：把 `tatami --space --launch --all`
/// 丟到背景、最多重試 10 次每次隔 3 秒、第一次成功就停。這個型別是那段 shell 的
/// 移植，而**它是純的**——寫在 `runMenuBar` 裡的話那三行判斷（還要不要試、
/// 這次算不算成功）沒有任何東西測得到，而它們決定的是「開機之後版面到底排不排」。
///
/// **窗口 30 秒的理由是外接螢幕**：登入當下螢幕可能還沒接齊，而兩個地點的 `main`
/// 都是外接螢幕（`match_location` 只比 `main`），沒接到就是認不出這是哪個地點
/// ——rc=1、實測 0.03 秒、什麼都不動。所以失敗是乾淨且可偵測的。
public struct StartupApply: Equatable, Sendable {
    /// 最多試幾次。10 × 3 秒 ＝ 30 秒，與那段 shell 逐字相同。
    public static let attempts = 10
    /// 兩次之間隔多久。
    public static let interval = 3.0

    /// 已經試過幾次。
    public private(set) var tried = 0
    /// 成功過了沒有。成功之後就不再試——那段 shell 的 `&& break`。
    public private(set) var succeeded = false

    public init() {}

    /// 還要不要再試一次。
    public var shouldTry: Bool {
        !succeeded && tried < Self.attempts
    }

    /// 記一次結果。
    ///
    /// 只有 `.completed` 算成功，與 CLI 那側的 exit code 對齊
    /// （`SpaceCommand.swift:84` 的 `guard case .completed = outcome else { exit(1) }`）
    /// ——分歧的話「重試到什麼時候停」在兩條路上會不一樣，而那件事只有開機時看得出來。
    public mutating func record(_ outcome: SpaceLayout.Outcome) {
        tried += 1
        if case .completed = outcome {
            succeeded = true
        }
    }
}
