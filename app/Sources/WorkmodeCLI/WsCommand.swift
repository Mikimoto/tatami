import Foundation
import WorkmodeAdapters
import WorkmodeCore
import WorkmodeDomain
import WorkmodeWire

/// `ws` 與 `__smoke ws` 自己的錯誤。
///
/// 不重用 `WindowServerFailure.windowNotFound`：那個型別講的是「window server 找不到
/// 這個視窗」，拿它承載「回來的 JSON 形狀不對」會讓訊息說謊，而這兩支的唯一產出就是
/// 訊息本身。
enum WsFailure: Error, CustomStringConvertible {
    case shape(String)

    var description: String {
        switch self {
        case let .shape(text): text
        }
    }
}

/// `JSONValue` 沒有 subscript（它是保序的 `[JSONMember]`），而 `ws` 這一層要從
/// yabai 形狀的回覆裡挑欄位。挑一個不存在的鍵回 nil，由呼叫端決定那是不是錯。
private func member(_ value: JSONValue?, _ key: String) -> JSONValue? {
    guard case let .object(members)? = value else { return nil }
    return members.first { $0.key == key }?.value
}

/// `tatami ws <spaces|windows|frame|move>`：視窗引擎的查詢與動作，給人、給 AI、給驗證。
///
/// 查詢印的就是 client 回的 yabai 形狀 JSON（`JSONWriter.format`），所以
/// `tatami ws spaces | jq '.[].uuid'` 與 `yabai -m query --spaces | jq '.[].uuid'` 可以直接 diff。
/// 動作**預設 dry-run**，加 `--apply` 才動；印一行 `JSONEnvelope`。
/// 不進用法字串（`--space`／`edit` 的既有慣例）。
func runWindowServer(_ parts: [String], json: Bool) -> Never {
    let client: WindowServerClient
    do {
        client = try WindowServerClient()
    } catch {
        emitError(command: "ws", json: json, kind: "engine_unavailable", message: "\(error)")
    }
    let apply = parts.contains("--apply")
    let words = parts.filter { $0 != "--apply" }

    func show(_ query: YabaiQuery) -> Never {
        do {
            try print(JSONWriter.format(client.query(query)))
            exit(0)
        } catch {
            emitError(command: "ws", json: json, kind: "query_failed", message: "\(error)")
        }
    }

    /// uuid → mission control 編號。用 uuid 不用編號：編號會隨插拔螢幕跳
    /// （CLAUDE.md），uuid 才是身分。
    func spaceIndex(forUUID uuid: String, command: String) -> String {
        guard case let .array(spaces)? = try? client.query(.spaces),
              let match = spaces.first(where: { member($0, "uuid") == .string(uuid) }),
              case let .number(index)? = member(match, "index")
        else {
            emitError(command: command, json: json, kind: "space_not_found",
                      message: "沒有 uuid 是 \(uuid) 的 space")
        }
        return index
    }

    // Swift 的 switch 不能在陣列 pattern 裡綁變數（`case ["frame", let id, …]` 編不過），
    // 所以用 count 與索引，與 `main.swift` 的 `app-running` 那列同一個寫法。
    switch words.first {
    // 螢幕清單。加它的理由是 ⌥ 拖曳的吸附區靠 `frame` 判斷「游標在哪一台上」，
    // 而那個 frame 是**可視區**（扣掉選單列與 Dock），與 `yabai -m query --displays`
    // 印的整片螢幕不同——查不出來的話那個判斷只能用猜的。
    case "displays" where words.count == 1:
        show(.displays)
    case "spaces" where words.count == 1:
        show(.spaces)
    case "windows" where words.count == 1:
        show(.windows)
    case "windows" where words.count == 3 && words[1] == "--space":
        show(.windowsOnSpace(spaceIndex(forUUID: words[2], command: "ws windows")))
    case "frame" where words.count == 6:
        runFrame(client, words: words, apply: apply, json: json)
    case "move" where words.count == 4 && words[2] == "--to":
        runMove(client, words: words, index: spaceIndex(forUUID: words[3], command: "ws move"),
                apply: apply, json: json)
    default:
        fail("用法：tatami ws spaces | windows [--space <uuid>]"
            + " | frame <id> <x> <y> <w> <h> [--apply]"
            + " | move <id> --to <uuid> [--apply]", code: 2)
    }
}

/// `ws frame <id> <x> <y> <w> <h> [--apply]`。
///
/// 拆成獨立一支是 `function_body_length`：`runWindowServer` 那個 switch 已經滿了。
private func runFrame(_ client: WindowServerClient, words: [String],
                      apply: Bool, json: Bool) -> Never
{
    let id = words[1]
    guard let xValue = Double(words[2]), let yValue = Double(words[3]),
          let wValue = Double(words[4]), let hValue = Double(words[5])
    else { emitError(command: "ws frame", json: json, kind: "usage", message: "四個數字：x y w h") }
    let wanted = Rect(originX: xValue, originY: yValue, width: wValue, height: hValue)
    guard apply else {
        print(envelope(command: "ws frame",
                       data: ["dryRun": true, "window": id, "wanted": fields(wanted)]))
        exit(0)
    }
    do {
        // 回的是 window server 重讀的 bounds，不是我們送出去的值——macOS 會夾（實測
        // 一個高 1409 的視窗被夾成 1374），而那個差就是 `frameRejected` 要說的事。
        let actual = try client.setFrame(window: id, wanted)
        print(envelope(command: "ws frame",
                       data: ["window": id, "wanted": fields(wanted), "actual": fields(actual)]))
        exit(0)
    } catch {
        emitError(command: "ws frame", json: json, kind: "rejected", message: "\(error)")
    }
}

/// `ws move <id> --to <uuid> [--apply]`。
///
/// 收整個 `words` 而不是拆成 window／uuid 兩個參數：swiftlint 的
/// `function_parameter_count` 上限是 5，而那條規則不准調。
private func runMove(_ client: WindowServerClient, words: [String],
                     index: String, apply: Bool, json: Bool) -> Never
{
    let window = words[1], uuid = words[3]
    guard apply else {
        print(envelope(command: "ws move", data: ["dryRun": true, "window": window, "to": uuid]))
        exit(0)
    }
    do {
        try client.run(.moveToSpace(window: window, space: index))
        // 搬完重問一次：`move` 對 SkyLight 是 fire-and-forget，沒有回傳可以看。
        let after = member(try? client.query(.window(window)), "space").map(rawText) ?? "?"
        print(envelope(command: "ws move",
                       data: ["window": window, "to": uuid, "nowOnSpaceIndex": after]))
        exit(0)
    } catch {
        emitError(command: "ws move", json: json, kind: "move_failed", message: "\(error)")
    }
}

/// 封套組不出來時印空字串（與其他子命令的 `(try? …) ?? ""` 同一個處置）。
private func envelope(command: String, data: [String: Any]) -> String {
    (try? JSONEnvelope.success(command: command, data: data)) ?? ""
}

/// internal 而不是 private：`GridCommand.swift` 印同一組欄位（同一個封套形狀）。
func fields(_ rect: Rect) -> [String: Any] {
    ["x": rect.originX, "y": rect.originY, "w": rect.width, "h": rect.height]
}

/// `tatami __smoke ws`：對真的系統把四件事跑一遍，唯讀。
///
/// 與 `__smoke yabai` 同一個定位：fake 測得到編排，測不到私有符號真的接上了。
/// 比對對象是 yabai 自己的 query——兩邊的 uuid 集合必須相同，這是「我們的 SkyLight
/// 讀法對不對」唯一的外部基準。yabai 不在時只印我們這邊的數字。
///
/// **螢幕鎖住時第 3、4 項必然失敗**：`AXIsProcessTrusted()` 照樣是 true，
/// `kAXWindowsAttribute` 照樣回元素，但那些元素拿不到 window id（`-25201`），
/// 所以 AX 那半整個是空的。CG 那半（1、2 項）不受影響。判別法：
/// `ioreg -n Root -d1 -k IOConsoleUsers | grep CGSSessionScreenIsLocked`。
/// `__smoke snap <x> <y>`：問 `SnapSource` 那一點的畫布與吸附區。
///
/// ⌥ 拖曳的吸附區是「拖了才知道」的東西，而它安靜失敗的樣子（沒有吸附區＝
/// 照自由位置放）與「這個功能沒開」完全相同。這支讓那件事查得出來。
func runSnapSmoke(_ posX: String, _ posY: String) -> Never {
    guard let pointX = Double(posX), let pointY = Double(posY) else {
        print("用法：tatami __smoke snap <x> <y>（CG 座標）")
        exit(2)
    }
    guard let engine = try? WindowServerClient() else {
        print("FAIL 建不起引擎（沒有輔助使用權限？）")
        exit(1)
    }
    let paths = TatamiPaths()
    let source = SnapSource(yabai: engine, files: FileManagerStore(),
                            layoutPath: paths.layout, statePath: paths.state,
                            parse: JSONParser.parse, renderRaw: rawText)
    guard let found = source.zones(at: MouseDrag.Point(posX: pointX, posY: pointY)) else {
        print("FAIL 那一點不在任何一台螢幕上")
        exit(1)
    }
    let canvas = found.canvas
    print("畫布：\(canvas.originX),\(canvas.originY) \(canvas.width)x\(canvas.height)")
    print("吸附區：\(found.zones.count) 個" + (found.zones.count == 9 ? "（九宮格）" : "（樹的葉）"))
    for zone in found.zones {
        let target = zone.target
        print("  \(zone.name)\t→ \(Int(target.originX)),\(Int(target.originY)) "
            + "\(Int(target.width))x\(Int(target.height))")
    }
    let hit = SnapZones.zone(at: MouseDrag.Point(posX: pointX, posY: pointY),
                             in: found.zones)
    print("游標落在：\(hit?.name ?? "（都不在）")")
    exit(0)
}

func runWindowServerSmoke() -> Never {
    var failures = 0
    func check(_ name: String, _ body: () throws -> String) {
        do { try print("ok   \(name)：\(body())") } catch { failures += 1; print("FAIL \(name)：\(error)") }
    }
    let client: WindowServerClient
    do { client = try WindowServerClient() } catch { print("FAIL 建 client：\(error)"); exit(1) }

    check("spaces") { try smokeSpaces(client) }
    check("windows") { try smokeWindows(client) }
    check("視窗形狀過得了 ManagedWindow") { try smokeManagedShape(client) }
    check("AX 找得到不可見 space 上的視窗") { try smokeHiddenWindow(client) }
    check("Safari 的 AXDocument") { try smokeSafariDocument(client) }
    // 唯讀：只問那支非匯出符號找不找得到，不搬任何視窗。它是 macOS 升級時最可能
    // 消失的東西，而消失的症狀是「切 space 之後視窗沒跟過去」——沒有錯誤訊息。
    check("跨 space 搬移的符號") {
        guard client.canMoveAcrossSpaces else {
            throw WsFailure.shape("找不到 SLSPerformAsynchronousBridgedWindowManagementOperation"
                + "（或那個 ObjC 類別）；搬 space 會降級成無效的舊呼叫")
        }
        return "找得到，bridged 那條路可用"
    }

    // 唯讀。`grid` 要排的就是這個視窗，而「排錯視窗」與「沒反應」在畫面上分得出來
    // 但都很惱人，所以要有一個地方能先問「你現在認為焦點在哪」。
    check("焦點視窗") {
        let id = try client.focusedWindow()
        guard case let .object(fields) = try client.query(.window(id)),
              let app = fields.first(where: { $0.key == "app" })?.value
        else { return "id \(id)（問不到它的 app）" }
        return "id \(id)（\(rawText(app))）"
    }

    print(failures == 0 ? "--- smoke passed ---" : "--- \(failures) 項失敗 ---")
    exit(failures == 0 ? 0 : 1)
}

private func smokeSpaces(_ client: WindowServerClient) throws -> String {
    guard case let .array(ours) = try client.query(.spaces) else {
        throw WsFailure.shape("query(.spaces) 不是陣列")
    }
    let ourUUIDs = Set(ours.compactMap { member($0, "uuid") }.map(rawText))
    // `try?` 而不是 `try`：yabai 答不出來與 yabai 不在是同一件事——都沒有基準可比，
    // 不是我們這半壞了。實測（2026-09-03，螢幕鎖住）`yabai -m query --spaces` 會回
    // 一個位元組 `[` 而 rc=0，用 `try` 的話那個 malformedOutput 會被記成我們失敗。
    if let yabai = try? YabaiProcessClient(),
       case let .array(theirs)? = try? yabai.query(.spaces)
    {
        let theirUUIDs = Set(theirs.compactMap { member($0, "uuid") }.map(rawText))
        guard ourUUIDs == theirUUIDs else {
            throw WsFailure.shape("uuid 集合與 yabai 不同：只有我們有 "
                + "\(ourUUIDs.subtracting(theirUUIDs))、只有 yabai 有 \(theirUUIDs.subtracting(ourUUIDs))")
        }
        return "\(ours.count) 個 space，uuid 與 yabai 全同"
    }
    return "\(ours.count) 個 space（yabai 不在或答不出 spaces，沒得比）"
}

private func smokeWindows(_ client: WindowServerClient) throws -> String {
    guard case let .array(windows) = try client.query(.windows) else {
        throw WsFailure.shape("query(.windows) 不是陣列")
    }
    // `space` 為 0 代表那個視窗的 space id 不在我們列出的清單裡（理論上不該發生，
    // 發生就是 SkyLight 那半漏了什麼），所以要數出來而不是靜靜吞掉。
    let placed = windows.filter { member($0, "space").map(rawText) != "0" }.count
    return "\(windows.count) 個視窗（含不可見 space 上的）"
        + (placed == windows.count ? "" : "，\(windows.count - placed) 個查不到 space")
}

/// `ManagedWindow.matches` 對這條路吐出來的每一列都要是 **true**。
///
/// 這一項是 2026-09-08 的迴歸換來的：`windowJSON` 沒有印
/// `is-floating`／`is-visible`／`is-minimized`，而那個 select 要求三個**恰好**相等
/// ——缺欄位是 null，`null == false` 為 false，所以「每一個視窗都不受管理」。
/// 後果是 `--save` 印「這些螢幕上沒有任何可以存的視窗」然後一個字都不寫。
/// 它沒有單元測試的家（Adapters 這層要碰真系統），所以釘在這裡。
private func smokeManagedShape(_ client: WindowServerClient) throws -> String {
    guard case let .array(windows) = try client.query(.windows) else {
        throw WsFailure.shape("query(.windows) 不是陣列")
    }
    // 空清單不算通過：那與「三個欄位都漏了」的外觀相同（兩者都是零個 managed）。
    guard let first = windows.first else {
        throw WsFailure.shape("一個視窗都沒有，這一項證明不了任何事")
    }
    let unmanaged = windows.filter { ManagedWindow.matches($0) != true }
    guard unmanaged.isEmpty else {
        let names = unmanaged.prefix(3).map { member($0, "app").map(rawText) ?? "?" }
        throw WsFailure.shape("\(unmanaged.count)/\(windows.count) 列過不了"
            + " ManagedWindow（\(names.joined(separator: "、"))）")
    }
    return "\(windows.count) 列全過（例：\(member(first, "app").map(rawText) ?? "?")）"
}

private func smokeHiddenWindow(_ client: WindowServerClient) throws -> String {
    guard case let .array(spaces) = try client.query(.spaces),
          let hidden = spaces.first(where: { member($0, "is-visible") == .bool(false) }),
          case let .number(index)? = member(hidden, "index"),
          case let .array(windows) = try client.query(.windowsOnSpace(index)),
          let first = windows.first, let id = member(first, "id").map(rawText)
    else { return "沒有不可見 space 上的視窗可以測" }
    // 判準是 **`title`** 而不是 `is-minimized`：後者 2026-09-08 起連淺的那半也一定
    // 有（見 `windowJSON` 的 doc），所以拿它當「AX 元素找得到」的證據會恆真。
    // `title` 只在 `AXWindow.find` 成功時才被 append。
    guard case let .object(deep) = try client.query(.window(id)),
          deep.contains(where: { $0.key == "title" })
    else { throw WsFailure.shape("視窗 \(id) 問不到 AX 元素（螢幕鎖住時必然如此）") }
    return "視窗 \(id)（space \(index)）的 AX 元素找得到"
}

private func smokeSafariDocument(_ client: WindowServerClient) throws -> String {
    // 兩種結果分開講。原本一句「沒有 Safari 視窗，或它沒給 AXDocument」把它們併在
    // 一起，於是 Safari 明明在清單裡（`ws windows` 印得出來）而這一行說「沒有」，
    // 讀的人會去追一個不存在的漏斗 bug——2026-09-07 我自己追了一次。
    guard case let .array(windows) = try client.query(.windows),
          let safari = windows.first(where: { member($0, "app") == .string("Safari") }),
          let id = member(safari, "id").map(rawText)
    else { return "沒有 Safari 視窗可以測" }
    guard case let .object(deep) = try client.query(.window(id)),
          let document = deep.first(where: { $0.key == "document" })?.value
    else { return "視窗 \(id) 是 Safari 但沒給 AXDocument（沒開分頁時是這樣）" }
    return rawText(document)
}
