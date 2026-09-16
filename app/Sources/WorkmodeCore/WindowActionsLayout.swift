import WorkmodeDomain

/// `WindowActions` 裡「不只設一個 frame」的那幾個：跨 space／跨螢幕、全螢幕切換、
/// 以及三個走樹的（balance／rotate／gaps）。
///
/// 拆檔的理由是 `file_length`（上限 400，不准調參數）。
extension WindowActions {
    // MARK: - 跨 space 與跨螢幕

    func move(toSpace target: HotkeyAction.Target, _ scene: WindowScene) {
        let onSameDisplay = scene.spaces.filter { $0.display == scene.displayIndex }
        guard let destination = resolve(target, among: onSameDisplay.map(\.index),
                                        current: scene.spaceIndex)
        else {
            reporter.report(.hotkeySpaceNotFound(target: target.text))
            return
        }
        try? yabai.run(.moveToSpace(window: scene.focused, space: destination))
        // 搬完把焦點給它——macOS 會跟著切過去，那正是 skhdrc 那條
        // `window --space N; space --focus N` 的第二半。這條路沒有
        // 「focus 一個 space」的命令，但 focus 一個視窗做得到同一件事。
        try? control.focus(window: scene.focused)
    }

    /// 搬到另一台螢幕：先落到那台**目前可見**的 space，再照原本在畫布上的比例
    /// 放到新畫布的同一個相對位置。
    ///
    /// 不保留絕對座標：兩台螢幕的解析度與原點都不同，照抄座標會把視窗放到
    /// 畫面外，而那與「沒搬過去」在使用者眼裡是同一件事。
    func move(toDisplay target: HotkeyAction.Target, _ scene: WindowScene,
              _ state: String)
    {
        let indices = scene.displays.map(\.index)
        guard let destination = resolve(target, among: indices, current: scene.displayIndex),
              let display = scene.displays.first(where: { $0.index == destination }),
              let space = scene.spaces.first(where: { $0.display == destination && $0.isVisible })
        else {
            reporter.report(.hotkeyDisplayNotFound(target: target.text))
            return
        }
        try? yabai.run(.moveToSpace(window: scene.focused, space: space.index))
        try? control.focus(window: scene.focused)
        // 目的地也要走 `LayoutCanvas`：那台螢幕自己學到的頂端 inset 與來源那台
        // 未必相同，拿原始 frame 當目的地會讓視窗的上緣落進選單列底下。
        let destinationCanvas = LayoutCanvas.of(frame: display.frame, display: display.uuid,
                                                state: state).frame
        place(proportional(scene.frame, from: scene.canvas, to: destinationCanvas),
              scene.focused)
    }

    /// 絕對編號就照收（不在清單裡是找不到），`next`／`prev` 在清單上繞一圈。
    /// 清單本身是查詢回來的順序，也就是 mission control 的順序。
    private func resolve(_ target: HotkeyAction.Target, among indices: [String],
                         current: String) -> String?
    {
        switch target {
        case let .index(value):
            let text = String(value)
            return indices.contains(text) ? text : nil
        case .next, .previous:
            guard let position = indices.firstIndex(of: current), indices.count > 1 else {
                return nil
            }
            let step = target == .next ? 1 : indices.count - 1
            return indices[(position + step) % indices.count]
        }
    }

    private func proportional(_ frame: Rect, from source: Rect, to destination: Rect) -> Rect {
        guard source.width > 0, source.height > 0 else { return destination }
        let scaleX = destination.width / source.width, scaleY = destination.height / source.height
        return Rect(originX: destination.originX + (frame.originX - source.originX) * scaleX,
                    originY: destination.originY + (frame.originY - source.originY) * scaleY,
                    width: frame.width * scaleX, height: frame.height * scaleY)
    }

    // MARK: - 全螢幕

    /// 已經填滿畫布就還原，否則記下現在的 frame 再填滿。
    ///
    /// 「上一個 frame」寫進狀態檔而不是留在記憶體：快捷鍵每次都可能是**新的行程**
    /// （skhd 那條路是這樣，選單列 app 那條不是），記在記憶體的話從終端機按一次
    /// 就再也還原不回去。key 帶 window id，所以同時全螢幕兩個視窗互不影響。
    func toggleFullscreen(_ scene: WindowScene, _ state: String) {
        let key = "fullscreen.\(scene.focused)"
        let saved = StateFile.value(forKey: key, in: state)
        if scene.frame.isClose(to: scene.canvas, within: 4), let restored = decode(saved) {
            place(restored, scene.focused)
            write(state: StateFile.set(state, key: key, value: ""))
            return
        }
        write(state: StateFile.set(state, key: key, value: encode(scene.frame)))
        place(scene.canvas, scene.focused)
    }

    /// `x,y,w,h`。逗號分隔而不是 JSON：狀態檔一行一個 `key=value`，塞 JSON 進去
    /// 會讓那個檔再也不能用 `grep` 讀。
    ///
    /// 用 Swift 自己的 `description` 而不是 `JQNumber`（它是 Domain 的 internal，
    /// 而且它模擬的是 jq 的印法——那條紀律屬於差分基準，這個值沒有基準要對）。
    /// Double 的 `description` 是往返精確的，寫出去讀回來是同一個值。
    private func encode(_ frame: Rect) -> String {
        [frame.originX, frame.originY, frame.width, frame.height]
            .map { "\($0)" }.joined(separator: ",")
    }

    private func decode(_ text: String) -> Rect? {
        let parts = text.split(separator: ",").compactMap { Double($0) }
        guard parts.count == 4, parts[2] > 0, parts[3] > 0 else { return nil }
        return Rect(originX: parts[0], originY: parts[1], width: parts[2], height: parts[3])
    }

    // MARK: - 走樹的三個

    /// 把這個 space 上的視窗矩形反推成一棵樹，改完再排回去。
    ///
    /// `flipAxes` 為真＝rotate（每個 axis 橫縱對調），為假＝balance（拿掉每個
    /// ratio）。兩者共用同一條路，因為它們的差別只有中間那一步。
    func relayout(_ scene: WindowScene, _ state: String, flipAxes: Bool) {
        guard let tree = try? RectTree.fromRects(WindowGeometry.rects(of: candidates(scene))),
              tree != .null
        else { return }
        let edited = flipAxes ? WindowGeometry.withFlippedAxes(tree)
            : WindowGeometry.withoutRatios(tree)
        apply(edited, scene.canvas, gapsAreOn(state) ? config(scene).gap : 0)
    }

    /// 切換間隙再重排一次。**保留 ratio**——使用者按的是「加間隙」不是「重新均分」。
    ///
    /// 重排前用的是**未加間隙**的畫布，所以連按兩次不會愈縮愈小：樹是從現在的
    /// 矩形推回來的，而切線位置不受間隙影響（間隙只是把每個矩形往內縮，
    /// 相對順序與可切開性都不變）。
    func toggleGaps(_ scene: WindowScene, _ state: String) {
        let next = gapsAreOn(state) ? "off" : "on"
        let updated = StateFile.set(state, key: Self.gapsKey, value: next)
        write(state: updated)
        guard let tree = try? RectTree.fromRects(WindowGeometry.rects(of: candidates(scene))),
              tree != .null
        else { return }
        apply(tree, scene.canvas, next == "on" ? config(scene).gap : 0)
    }

    /// balance／rotate／gaps 可以動的視窗：不在 float 清單、也沒有最小化。
    ///
    /// 這三個動作掃**整個 space**，是唯一沒有「使用者指著誰」的路徑，所以
    /// yabai 的 `manage=off` 在守的東西只有它們需要——`--space` 的樹是明確
    /// 加入的，focus／swap／stack 是指著一個視窗做的。
    private func candidates(_ scene: WindowScene) -> [WindowGeometry.Placed] {
        scene.onSpace.filter { placed in
            if floatApps.contains(scene.appsByID[placed.id] ?? "") {
                return false
            }
            return !isMinimized(placed.id)
        }
    }

    /// `.windows` 不回報 `is-minimized`（要每個視窗問一次 AX，整份清單是秒級），
    /// 所以只對這個 space 上的候選逐一問 `.window(id)`。查不到、或 deep 資訊裡
    /// 沒有那個欄位，都當**沒有**最小化——把視窗多排進版面是看得見的錯，
    /// 把它踢出去是靜默的。
    ///
    /// 成本：一個候選一次 AX 往返（可見 space 上走的是 `kAXWindowsAttribute`
    /// 的快路徑），balance 一次按鍵付個位數毫秒級 × 視窗數。
    private func isMinimized(_ id: String) -> Bool {
        guard let deep = try? yabai.query(.window(id)),
              case .bool(true)? = deep["is-minimized"]
        else { return false }
        return true
    }

    /// 排一棵樹並套上間隙。
    ///
    /// **兩處各縮一半**：畫布縮 `gap/2`、每個葉再縮 `gap/2`，於是外緣的留白與
    /// 兩個視窗之間的縫都恰好是 `gap`。只縮其中一邊的話兩者會差一倍，而畫面上
    /// 那看起來只是「邊緣怪怪的」。
    private func apply(_ tree: JSONValue, _ canvas: Rect, _ gapSize: Double) {
        let board = GapInset.rect(canvas, by: gapSize / 2)
        guard let leaves = try? TreeRects.leaves(of: tree, in: board) else { return }
        for leaf in leaves {
            guard case let .string(id) = leaf.window else { continue }
            place(GapInset.rect(leaf.rect, by: gapSize / 2), id)
        }
    }

    static let gapsKey = "gaps"

    private func gapsAreOn(_ state: String) -> Bool {
        StateFile.value(forKey: Self.gapsKey, in: state) == "on"
    }

    /// 焦點視窗那台螢幕的格線設定。`displayIndex` → uuid → 查表。
    ///
    /// **那個 `?? ""` 在產品路徑走不到。** `WindowScene.read`
    /// （`WindowScene.swift:53`）用**逐字相同**的比對當 guard，查不到就整支回 nil、
    /// 這個動作根本不會執行。留著是因為 `first(where:)` 回 Optional 而總得接住它，
    /// 而空字串正好落進 `GridConfig.forDisplay` 已經在守的那條路（空 uuid 不算命中）。
    ///
    /// 這裡原本寫「查不到 uuid（螢幕剛被拔掉…）就是預設」——那是假的：拔掉螢幕
    /// 走的是 `read` 的 `return nil`，不是這一行。
    func config(_ scene: WindowScene) -> GridConfig {
        let uuid = scene.displays.first(where: { $0.index == scene.displayIndex })?.uuid ?? ""
        return GridConfig.forDisplay(uuid, in: grids)
    }
}
