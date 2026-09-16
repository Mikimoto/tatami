import WorkmodeDomain

/// ⌥ 拖曳時把吸附區畫出來的那一層。
///
/// **是 protocol 而不是具體型別**，理由與 `SpaceLayout` 的 `presence` 相同：
/// 畫面那半住在 CLI（它要 AppKit 的 `NSPanel` 與 activation policy），而
/// `MouseTap` 住在 Adapters。傳 nil ＝不顯示吸附區，拖到哪就放到哪。
public protocol SnapPresenter {
    /// 游標在這一點時的畫布與吸附區。回 nil ＝那一點不在任何螢幕上。
    func zones(at point: MouseDrag.Point) -> (canvas: Rect, zones: [SnapZone])?
    func show(zones: [SnapZone], canvas: Rect)
    /// 標起來的那一區。nil ＝都不在（游標拖到螢幕外）。
    func highlight(_ zone: SnapZone?)
    func hide()
}
