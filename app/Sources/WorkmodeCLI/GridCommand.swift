import AppKit
import WorkmodeAdapters
import WorkmodeCore
import WorkmodeDomain
import WorkmodeWire

/// `tatami grid [--columns N] [--rows N]`：Divvy 式的滑鼠格線。
///
/// 一次性的行程，不是常駐的選單列 app——按下 hotkey 才起來，放開滑鼠就套用並結束。
/// 這個形狀有兩個好處，第二個是今天才學到的：
///
///   * 少一個常駐行程、少一個 LaunchAgent、少一個要維護的狀態；
///   * **AX 權限跟著父行程**。skhd 起的子行程歸給 skhd，而 skhd 本來就有權限；
///     自己包成一個 .app 由 launchd 起就要自己拿一份授權（2026-09-07 實測，
///     見 CLAUDE.md 的「登入時把版面排好」）。
///
/// 幾何全部在 Domain（`GridSelection` 與 `GapInset`，都有測試）。這一層只做四件事：
/// 找出要排的視窗、算出畫布、把畫布蓋上一層透明視窗、把放開滑鼠那一刻的格子交回去。
///
/// **畫布與 `--space` 用的是同一個**（螢幕 frame ＋ 學到的頂端 inset），所以格線
/// 排出來的上緣與存下來的版面對得起來。各算一份的話，同一個位置用兩條路會差 30pt，
/// 而那個差在畫面上看起來就只是「格線有點不準」。
@MainActor
func runGrid(columns: Int?, rows: Int?, json: Bool) -> Never {
    let engine: WindowServerClient
    do {
        engine = try WindowServerClient()
    } catch {
        emitError(command: "grid", json: json, kind: "engine_unavailable", message: "\(error)")
    }

    let target: GridTarget
    do {
        target = try GridTarget(engine: engine)
    } catch {
        emitError(command: "grid", json: json, kind: "no_target", message: "\(error)")
    }

    // 旗標**明講的贏**（與規則上的 `launch` 欄位同一條）；沒給就讀那台螢幕的
    // 設定，沒設過就是 6×4。
    let document = HotkeyFile.load(from: TatamiPaths().hotkeys, files: FileManagerStore(),
                                   reporter: makeReporter(json: json))
    let config = GridConfig.forDisplay(target.uuid, in: document.grids)
    let grid = GridSelection(canvas: target.canvas,
                             columns: columns ?? config.columns,
                             rows: rows ?? config.rows)
    let screen = nsRect(fromCG: target.canvas)
    reportCoordinates(target: target, screen: screen)

    // 選取換算成矩形只有**這一支**：面板的預覽與放開滑鼠那一刻走同一個閉包，
    // 所以「亮起來的那一塊」就是「會被套上去的那一塊」。抄第二份的症狀是
    // 「亮在這裡、視窗排到隔壁」，而畫面上兩邊都正常。
    //
    // 間距在這裡而不是對 `GridSelection.rect` 的結果硬縮：`GapInset.cell` 是
    // 「畫布先縮 gap/2、那一格再縮 gap/2」，於是外緣與中縫都恰好是一個 gap；
    // 對結果硬縮的話外緣只剩一半，而那看起來只是「邊緣怪怪的」。
    let place: (WindowGeometry.GridSpec) -> Rect = {
        GapInset.cell(config, spec: $0, canvas: target.canvas)
    }
    GridOverlay.present(GridPanelRequest(
        grid: grid, display: screen,
        headline: GridHeadline.text(app: target.app, displayIndex: target.display,
                                    columns: grid.columns, rows: grid.rows),
        zones: document.zones,
        place: place,
        apply: { applyGrid(engine: engine, window: target.window,
                           rect: place($0), json: json) },
        // 縮圖牆那條**不 exit**：一格套完面板要留著讓使用者試下一格，而一次被拒
        // 更不該把面板收掉——那是「我按了沒反應」最難查的一種。
        pick: { spec in
            do {
                try placeGrid(engine: engine, window: target.window,
                              rect: place(spec), json: json)
            } catch {
                FileHandle.standardError.write(Data("  ! 排不上去：\(error)\n".utf8))
            }
        },
        record: { spec in
            writeZones { document in
                document.addingZone(named: document.nextZoneName, spec: spec)
            }
        },
        delete: { zone in writeZones { $0.removingZone(named: zone.name) } }
    ))
    exit(0)
}

/// 兩組座標印到 stderr：座標系轉換是這一段唯一不能靠讀程式碼確認的東西
/// （CG 原點在主螢幕左上、y 往下；NS 原點在主螢幕左下、y 往上），而它錯了的樣子
/// 是「面板出現在別的螢幕上」——看得出來，但看不出差多少。
@MainActor
private func reportCoordinates(target: GridTarget, screen: NSRect) {
    FileHandle.standardError.write(Data("""
    grid：視窗 \(target.window)（display \(target.display)）
      畫布(CG) \(fields(target.canvas))
      螢幕(NS) x=\(screen.origin.x) y=\(screen.origin.y) \
    w=\(screen.size.width) h=\(screen.size.height)

    """.utf8))
}

/// 位置庫的寫檔，回**寫完之後**那份 zones。
///
/// **重讀整份再寫回去**，不是拿面板啟動時那一份：編輯器的「快捷鍵」頁與「格線」頁
/// 都寫同一個檔，而面板可能開著好幾秒。寫的是 `HotkeyFile.save`——原子寫，
/// 中途失敗不會留下半份設定。
///
/// **看不懂就整個不寫**（`readable` 回 nil）：那份檔可能只是被打錯一個逗號，
/// 而拿內建預設值覆蓋掉使用者 45 條綁定是這個 branch 已經修過兩次的資料遺失
/// （`HotkeyFile.readable` 的 doc 有那張四種狀態的表）。
///
/// 失敗只印一行而不是 throw：面板沒有呼叫端可以處理錯誤，而使用者要的是一句話
/// 說明為什麼那一格沒出現。回舊的那一份 zones——謊稱寫成功會讓牆上多一格，
/// 而檔案裡沒有。
@MainActor
private func writeZones(_ change: (HotkeyDocument) -> HotkeyDocument) -> [GridZone] {
    let paths = TatamiPaths()
    let files = FileManagerStore()
    guard let fresh = HotkeyFile.readable(from: paths.hotkeys, files: files) else {
        FileHandle.standardError.write(Data("! hotkeys.json 看不懂，這一次不寫\n".utf8))
        return []
    }
    let next = change(fresh)
    do {
        try HotkeyFile.save(next, to: paths.hotkeys, files: files)
        return next.zones
    } catch {
        FileHandle.standardError.write(Data("! 寫不進 hotkeys.json：\(error)\n".utf8))
        return fresh.zones
    }
}

/// 設一次 frame，並把「被夾過」說出來。
///
/// **會 throw 而不是自己決定怎麼收場**：兩條路對失敗的處置不同——拖曳那條打完就
/// 結束，所以它走 `emitError`（帶 exit code、`--json` 有錯誤封套）；縮圖牆那條要
/// 留著，只印一行。共用這一支是為了讓「成功時說什麼」只有一份。
@MainActor
private func placeGrid(engine: WindowServerClient, window: String,
                       rect: Rect, json: Bool) throws
{
    // `setFrame` 回的是重讀的 bounds——macOS 會夾（實測一個高 1409 的視窗被夾成
    // 1374），而那個差就是使用者看到「沒有完全貼齊」的原因，要說出來。
    let actual = try engine.setFrame(window: window, rect)
    if json {
        // 縮圖牆連點好幾次就會印好幾個封套。那是誠實的（每一次都是一次真的套用），
        // 而 `--json` 本來就是給拖曳那條一次性的路用的。
        print((try? JSONEnvelope.success(command: "grid", data: [
            "window": window, "wanted": fields(rect), "actual": fields(actual),
        ])) ?? "")
    } else if !actual.isClose(to: rect, within: 1) {
        FileHandle.standardError.write(Data(
            "  ! 「\(window)」沒有接受指定的位置：要 \(fields(rect))、實際 \(fields(actual))\n".utf8
        ))
    }
}

/// 拖曳模式放開滑鼠之後。套一次就結束——那是這條路的既有行為。
@MainActor
private func applyGrid(engine: WindowServerClient, window: String,
                       rect: Rect, json: Bool) -> Never
{
    do {
        try placeGrid(engine: engine, window: window, rect: rect, json: json)
        exit(0)
    } catch {
        emitError(command: "grid", json: json, kind: "rejected", message: "\(error)")
    }
}

/// 要排哪個視窗、排進哪一塊畫布。
///
/// 三段查詢：焦點視窗 → 它在哪台螢幕 → 那台螢幕的 frame。中間那一段不能省——
/// 焦點視窗不一定在主螢幕上，而拿錯螢幕的後果是把視窗丟到另一台去。
private struct GridTarget {
    let window: String
    let display: String
    let app: String
    /// 那台螢幕的 uuid，空字串＝查不到。`LayoutCanvas` 與格線設定都用它，而
    /// **只查一次**：`grids` 那張表的鍵是 uuid，各查一份就是各自會漂的兩份。
    let uuid: String
    let canvas: Rect

    init(engine: WindowServerClient) throws {
        window = try engine.focusedWindow()
        guard case let .object(fields) = try engine.query(.window(window)),
              let index = fields.first(where: { $0.key == "display" })?.value
        else { throw WindowServerFailure.noFocusedWindow }
        display = rawText(index)
        // 同一份 deep 資料撿出來，不多問一次 query——這條路要在按下快捷鍵的那一刻
        // 回答，而 `.window(id)` 對不可見 space 上的視窗實測要 15–220ms。
        // 查不到就是空字串，`GridHeadline` 會說「焦點視窗」。
        app = fields.first(where: { $0.key == "app" }).map { rawText($0.value) } ?? ""
        let displays = try engine.query(.displays)
        guard let frame = Displays.frame(ofIndexText: display, in: displays) else {
            throw WindowServerFailure.noFocusedWindow
        }
        // 與 `--space` **共用** `LayoutCanvas.of`，不是「同一個算法」——抄一份就會漂。
        // uuid 走 `Displays.list`：沒有 index → uuid 的直接查法，而多一支只給這裡用的
        // 函式不如在這裡挑一次（`list` 本來就是「這份 JSON 裡有哪幾台」的入口）。
        let wanted = display
        uuid = Displays.list(in: displays)
            .first { String($0.index) == wanted }?.uuid ?? ""
        let state = (try? FileManagerStore().read(atPath: TatamiPaths().state)) ?? ""
        canvas = LayoutCanvas.of(frame: frame, display: uuid, state: state).frame
    }
}

/// CG 的矩形換成 NS 的。
///
/// 兩套座標系只差一件事：CG 原點在**主螢幕左上**且 y 往下，NS 原點在**主螢幕左下**
/// 且 y 往上。所以橋是主螢幕的高度，而「主螢幕」的判準是它的 NS frame 原點是 `(0,0)`
/// ——不是 `NSScreen.screens.first`（順序沒有保證）也不是 `NSScreen.main`
/// （那是「有焦點的那一台」，會隨滑鼠跑）。
///
/// 負的 y 是常態（本機 BenQ 的 CG y 是 -996），這個式子對它照樣成立。
/// 不是 private：`SnapOverlay.swift` 也要把畫布從 CG 換到 NS，而 Swift 的
/// private 是**檔案**範圍。這個換算全 repo 只該有一份——抄第二份的症狀是
/// 「蓋在別的螢幕上」或「上下顛倒」（見 CLAUDE.md 的格線那一節）。
func nsRect(fromCG rect: Rect) -> NSRect {
    let primaryHeight = NSScreen.screens
        .first { $0.frame.origin == .zero }?.frame.height ?? 0
    return NSRect(x: rect.originX,
                  y: primaryHeight - rect.originY - rect.height,
                  width: rect.width, height: rect.height)
}

/// 與 `__smoke snap` 印同一個格式（`x,y wxh`）。
///
/// 不用 `fields(_:)`：那一支回的是 `[String: Any]`，插值出來是一個**鍵序不定**的
/// 字典字面值——同一份輸入兩次跑印出來的字不一樣，拿它做 cmp 或貼進回報都不成立。
private func rectText(_ rect: Rect) -> String {
    "\(Int(rect.originX)),\(Int(rect.originY)) \(Int(rect.width))x\(Int(rect.height))"
}

/// 沒掛快捷鍵是**常態**（那一格只在面板裡按得到），所以那一欄留空而不是印「（無）」
/// ——一句「無」會讓人以為那是設錯了。
private func shortcut(_ zone: GridZone) -> String {
    zone.hotkey.map { "\t\($0.description)" } ?? ""
}

/// `tatami __smoke zones`：位置庫的探針。
///
/// 加它的理由與 `__smoke snap`／`__smoke save-all` 逐字相同——**「zone 套錯位置」
/// 與「zone 根本沒被讀到」在畫面上分不出來**（兩者都是「按了沒反應」或「排到奇怪的
/// 地方」）。這一支把「Domain 算得出來」與「上層有沒有讀到它」分成兩段輸出。
///
/// **住在這個檔而不是 `WsCommand.swift`**：它要用 `GridTarget`，而那個型別是
/// `private`（Swift 的 private 是**檔案**範圍）。放寬它的可見性只為了把探針擺到別的
/// 檔，等於替一個「只查一次」的型別多開一個消費端——它自己的 doc 就在警告那件事。
///
/// 螢幕 uuid 走 `target.uuid` 而不是自己再 `Displays.list` 查一次：`grid` 那條路
/// 用的就是那一個，各查一份就是各自會漂的兩份，而探針漂掉等於探針在說謊。
func runZonesSmoke() -> Never {
    let document = HotkeyFile.load(from: TatamiPaths().hotkeys, files: FileManagerStore(),
                                   reporter: makeReporter(json: false))
    print("zones：\(document.zones.count) 個")

    /// 算不出矩形時仍然印得出「檔案裡有什麼」——那一半不需要畫布，而它正是
    /// 「沒被讀到」與「讀到了但算錯」的分界。少了它，失敗那條路只剩一句話。
    func listWithoutRects() -> Never {
        for zone in document.zones {
            print("  \(zone.name)\t\(zone.gridText)\(shortcut(zone))")
        }
        exit(1)
    }
    guard let engine = try? WindowServerClient() else {
        print("FAIL 建不起引擎（沒有輔助使用權限？），只能印清單")
        listWithoutRects()
    }
    guard let target = try? GridTarget(engine: engine) else {
        print("FAIL 沒有焦點視窗，只能印清單")
        listWithoutRects()
    }
    let config = GridConfig.forDisplay(target.uuid, in: document.grids)
    print("焦點視窗 \(target.window)（\(target.app)）display \(target.display)")
    print("那台螢幕：\(config.columns)×\(config.rows) 間距 \(Int(config.gap))"
        + (document.grids[target.uuid] == nil ? "（沒設過，用預設）" : ""))
    print("畫布：\(rectText(target.canvas))")
    // 與放開滑鼠那一刻走同一支 `GapInset.cell`（`runGrid` 的 `place` 閉包）——
    // 抄一份算式的症狀是「探針說對、實際排到隔壁」，而兩邊都看起來正常。
    for zone in document.zones {
        let rect = GapInset.cell(config, spec: zone.spec, canvas: target.canvas)
        print("  \(zone.name)\t\(zone.gridText)\t→ \(rectText(rect))\(shortcut(zone))")
    }
    exit(0)
}
