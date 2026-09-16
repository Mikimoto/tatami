import WorkmodeDomain

/// `--space` 的套版動作：`TreeRects` 算出每個葉的矩形，逐一搬到那個 space 再設 frame。
///
/// 取代 `TreeLayout` 在這條路上的位置。那一支翻成 `--warp`／`--swap`／`--ratio`
/// 再事後量測修正，因為 yabai 的插入方向不固定；直接設座標沒有那個問題，
/// 但多了一件 yabai 沒有的事：**AX 設 frame 是請求**，app 可以夾、可以不回應，
/// 所以每個都設完重讀一次，差超過 1pt 就說出來。
public struct FrameLayout {
    /// 半點的誤差是常態（AX 回來的座標未必整數），1pt 以上才是 app 沒照做。
    static let tolerance = 1.0

    /// 這棵樹要被排進去的畫布。
    ///
    /// 兩個欄位不是冗餘：`frame` 是**已經套過**已學到的頂端 inset 的可視區（葉矩形
    /// 從它算），`rawTop` 是那台螢幕原始 frame 的 y——校準時要拿它當基準，否則
    /// 學到的值會在每一輪疊上去（第二輪會學成 60）。
    public struct Canvas: Equatable, Sendable {
        public let frame: Rect
        public let rawTop: Double

        public init(frame: Rect, rawTop: Double) {
            self.frame = frame
            self.rawTop = rawTop
        }
    }

    /// 一次套版的結果。`observedTopInset` 是這一輪量到的頂端 inset（nil ＝沒有樣本）。
    ///
    /// macOS **不讓任何視窗的 y 小於「螢幕 frame 頂端 ＋ 那台螢幕的選單列高」**：
    /// 實測 2026-09-03，display 2（BenQ）的 frame 是 `(1728, -1026, 3008, 1692)`，
    /// 與 `yabai -m query --displays` 逐字相同，而對它上面的視窗設 y = -1026，
    /// AX 讀回來就是 **-996**——差 30pt。AppKit 完全不吐這個數字
    /// （`NSScreen.visibleFrame`、`safeAreaInsets`、`auxiliaryTopLeftArea` 對兩台外接
    /// 螢幕全是 0，`NSStatusBar.system.thickness` 是 22 不是 30），所以只能量。
    public struct Applied: Equatable, Sendable {
        public let observedTopInset: Double?
    }

    private let yabai: any YabaiClient
    private let server: any WindowServer
    private let reporter: any Reporter

    public init(yabai: any YabaiClient, server: any WindowServer, reporter: any Reporter) {
        self.yabai = yabai
        self.server = server
        self.reporter = reporter
    }

    /// - Parameters:
    ///   - tree: **已剪枝**的樹（`LayoutTree.prune`），所以每個葉都解得到 id。
    ///   - map: `resolve_rules` 的輸出，每行 `<label>\t<id>`。
    /// - Returns: nil ＝ 樹的形狀不對，什麼都沒做；呼叫端拿它去發 `spaceHasNoTree`。
    public func layout(space: String, tree: JSONValue,
                       in canvas: Canvas, map: String) -> Applied?
    {
        guard let leaves = try? TreeRects.leaves(of: tree, in: canvas.frame) else { return nil }
        var observed: Double?
        for leaf in leaves {
            let label = JQPrint.raw(leaf.window)
            // 剪枝之後不會是空的；空的話跳過而不是報錯，與 `TreeLayout` 對根解不到
            // 視窗的態度相同（bash 那行沒有檢查回傳值）。
            guard let id = WindowMatching.idForLabel(label, in: map), !id.isEmpty else { continue }
            // 搬過去的失敗交給 setFrame 去發現：視窗還在別的 space 時 AX 照樣設得動，
            // 只是使用者切過去看不到它——那會以 frameRejected 以外的形式出現在下一輪。
            try? yabai.run(.moveToSpace(window: id, space: space))
            guard let actual = try? server.setFrame(window: id, leaf.rect) else {
                reporter.report(.space(.frameRejected(label: label, wanted: leaf.rect, actual: nil)))
                continue
            }
            if isTopInsetSample(wanted: leaf.rect, actual: actual, canvas: canvas) {
                observed = max(observed ?? 0, actual.originY - canvas.rawTop)
                // 這一次的 y 已經被解釋掉了，所以**只**豁免 y——x 或寬高也對不上時
                // 那仍然是 app 自己夾的，照報。
                let forgiven = Rect(originX: actual.originX, originY: leaf.rect.originY,
                                    width: actual.width, height: actual.height)
                if !forgiven.isClose(to: leaf.rect, within: Self.tolerance) {
                    reporter.report(.space(.frameRejected(label: label,
                                                          wanted: leaf.rect, actual: actual)))
                }
                continue
            }
            if !actual.isClose(to: leaf.rect, within: Self.tolerance) {
                reporter.report(.space(.frameRejected(label: label, wanted: leaf.rect, actual: actual)))
            }
        }
        return Applied(observedTopInset: observed)
    }

    /// 這個葉能不能拿來校準頂端 inset。
    ///
    /// **三個條件缺一不可，而且不能放寬**：它要求的 y 就是畫布頂端（也就是它是頂端
    /// 那一列）、實際落點被往下推、而且**橫向已經到位**。任何視窗都可能因為別的理由
    /// 被夾（app 有最小尺寸、使用者正拖到一半），拿那種樣本去校準會把畫布弄壞，
    /// 而症狀是「版面每次都不一樣」——沒有人會把它連回這裡。
    ///
    /// **第三個條件是 2026-09-03 用一份壞掉的線上狀態檔換來的**，原本只有前兩個。
    /// 那一輪 `space_changed` signal 跑 `--space` 時，有個視窗**沒有搬到目標螢幕**、
    /// 還留在內建螢幕的 `y=34`，而它要求的 y 是 display 3 的畫布頂端 `-1026`：前兩個
    /// 條件都成立，於是它教出 `34 − (−1026) = 1060` 並寫進了狀態檔。1060pt 的 inset
    /// 會把那台螢幕的畫布砍掉四分之三，而下一輪讀到它時不會有任何訊號說它是垃圾。
    ///
    /// 用 x 而不是「算出來的值合不合理」當關卡，是因為前者是語意（「它去了我叫它去的
    /// 那一欄，只有頂端被推下來」），而後者要挑一個門檻值——1060 對一台 1440 高的螢幕
    /// 來說並不出格，門檻擋不掉它。
    private func isTopInsetSample(wanted: Rect, actual: Rect, canvas: Canvas) -> Bool {
        abs(wanted.originY - canvas.frame.originY) <= Self.tolerance
            && actual.originY > wanted.originY + Self.tolerance
            && abs(actual.originX - wanted.originX) <= Self.tolerance
    }
}
