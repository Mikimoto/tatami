import CoreGraphics
import WorkmodeDomain

/// 滑鼠拖曳要的兩支：游標下是哪個視窗、以及「設 frame 但不等它追上」。
///
/// 拆成獨立檔只有一個理由：`WindowServerClient.swift` 撞到 swiftlint 的
/// `file_length`（上限 400，不准調參數）。`WindowServerShape.swift` 與
/// `WindowControlClient.swift` 是同一個先例。
extension WindowServerClient {
    /// 游標下最上面那個視窗，加上它現在的 frame。
    ///
    /// **不走 `windows()`**：那條完整的漏斗一次 0.78 秒（它對每個 pid 都問一輪 AX），
    /// 而這支要在滑鼠按下的那一刻回答。`.optionOnScreenOnly` 給的就是「螢幕上、
    /// 由前到後」的順序，所以第一個框住那一點的 `layer == 0` 視窗就是游標下那個。
    ///
    /// 少掉的是 subrole allowlist 與「剛好屬於一個 space」那兩關。代價可以接受：
    /// 游標**壓在上面**的東西本來就在螢幕上，而拖到一個彈出視窗的後果是它動一下，
    /// 不是版面壞掉。
    func window(at point: MouseDrag.Point) -> (id: String, frame: Rect)? {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        let raw = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] ?? []
        for entry in raw {
            guard (entry[kCGWindowLayer as String] as? Int) == 0,
                  let id = entry[kCGWindowNumber as String] as? CGWindowID,
                  let bounds = entry[kCGWindowBounds as String] as? [String: Double],
                  let originX = bounds["X"], let originY = bounds["Y"],
                  let width = bounds["Width"], let height = bounds["Height"],
                  point.posX >= originX, point.posX < originX + width,
                  point.posY >= originY, point.posY < originY + height
            else { continue }
            return (String(id), Rect(originX: originX, originY: originY,
                                     width: width, height: height))
        }
        return nil
    }

    /// 設 frame，**不等它追上**。
    ///
    /// `setFrame` 會輪詢到 server bounds 對上為止（預算 1 秒），理由是套版那條路
    /// 要回報「app 沒接受這個位置」。拖曳時每一格都要設，那個預算會讓視窗完全跟不上
    /// 滑鼠——所以這條只送不讀。回報也不需要：使用者正看著視窗跟不跟得上。
    func place(window: String, _ frame: Rect) throws {
        try axWindow(window).setFrame(frame)
    }
}
