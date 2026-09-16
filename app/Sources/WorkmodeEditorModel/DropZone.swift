/// 一次放下落在窗格的哪一區。
///
/// 中央是正中間的五分之一見方（0.3…0.7）；其餘照「偏離中心較多的那個軸」決定方向。
/// 兩個偏移相等時橫向贏——四個角落要有定義好的行為，否則那是實作巧合。
public enum DropZone: Equatable, Sendable {
    case leading, trailing, top, bottom, center

    /// `x`／`y` 是窗格內的正規化座標（左上是 0,0）。非有限回 nil：UI 據此整個忽略
    /// 那次放下，因為每一個替代選擇都會改到使用者沒有瞄準的東西。
    public static func at(x fractionX: Double, y fractionY: Double) -> DropZone? {
        guard fractionX.isFinite, fractionY.isFinite else { return nil }
        let offsetX = fractionX - 0.5, offsetY = fractionY - 0.5
        if abs(offsetX) < 0.2, abs(offsetY) < 0.2 {
            return .center
        }
        if abs(offsetX) >= abs(offsetY) {
            return offsetX < 0 ? .leading : .trailing
        }
        return offsetY < 0 ? .top : .bottom
    }

    /// 這一區要產生的 `axis`。`vertical` 是**左右分**（`LayoutTree.swift:6`）。
    /// `center` 不分割所以沒有 axis。
    public var axis: String? {
        switch self {
        case .leading, .trailing: "vertical"
        case .top, .bottom: "horizontal"
        case .center: nil
        }
    }

    /// 新的葉是不是排在 `children[0]`。
    public var putsNewNodeFirst: Bool {
        switch self {
        case .leading, .top: true
        case .trailing, .bottom, .center: false
        }
    }
}

/// 預覽色塊蓋住的範圍，四個 0…1 的比例。UI 乘上格子尺寸。
///
/// **不用 tuple**：swiftlint 的 `large_tuple` 上限是兩個成員。
///
/// 左上角那兩個存的是 `originX`／`originY` 而外部標籤仍是 `x:`／`y:`：swiftlint 的
/// `identifier_name` 最短三個字元，而那條參數一律不調（`.swiftlint.yml` 檔頭）。
/// `DropZone.at(x fractionX:)` 是同一個做法的先例。
public struct PreviewFraction: Equatable, Sendable {
    public let originX: Double
    public let originY: Double
    public let width: Double
    public let height: Double

    public init(x originX: Double, y originY: Double, width: Double, height: Double) {
        self.originX = originX
        self.originY = originY
        self.width = width
        self.height = height
    }
}

public extension DropZone {
    /// 這一區的預覽色塊蓋住哪裡。
    ///
    /// **是矩形近似，不是 `at` 的判定範圍。** `at` 的分界是「偏離較多的軸勝出」，
    /// 畫出來是中央方塊加四個梯形；使用者要看的是「左半還是右半」，畫梯形只會讓
    /// 那個問題更難回答。`thePreviewContainsThePointThatChoseIt` 釘住兩者不會矛盾
    /// ——選了某一區的那個點一定在那一區的色塊裡。
    var previewFraction: PreviewFraction {
        switch self {
        case .leading: PreviewFraction(x: 0, y: 0, width: 0.5, height: 1)
        case .trailing: PreviewFraction(x: 0.5, y: 0, width: 0.5, height: 1)
        case .top: PreviewFraction(x: 0, y: 0, width: 1, height: 0.5)
        case .bottom: PreviewFraction(x: 0, y: 0.5, width: 1, height: 0.5)
        case .center: PreviewFraction(x: 0, y: 0, width: 1, height: 1)
        }
    }
}
