import WorkmodeDomain

/// ⌥ 拖曳時，游標所在那台螢幕的畫布與吸附區。
///
/// **樹優先**（使用者的裁決）：那個 space 在 `spaceTrees` 裡有樹就用樹的葉當吸附區，
/// 沒有就退回九宮格（`SnapZones.grid`）。理由是那個版面是他自己畫的，吸附到
/// 「畫布上本來就有的那幾格」比吸附到一組通用的半邊更接近意圖。
///
/// **用的是設定裡的樹，不是畫面上現在的矩形。** 兩者多數時候一樣（`--space` 剛套過），
/// 但 space 只開了一半的視窗時差很多：現在的矩形只切得出開著的那幾格，而樹知道
/// 那個 space 本來有幾格。拖一個視窗進去，想要的是後者。
///
/// **每次拖曳開始問一次，不是每個移動事件問一次**：這支會讀並解析 `layout.json`。
public struct SnapSource {
    private let yabai: any YabaiClient
    private let files: any FileStore
    private let layoutPath: String
    private let statePath: String
    private let parse: (String) throws -> JSONValue
    private let renderRaw: (JSONValue) -> String

    public init(yabai: any YabaiClient, files: any FileStore, layoutPath: String,
                statePath: String, parse: @escaping (String) throws -> JSONValue,
                renderRaw: @escaping (JSONValue) -> String)
    {
        self.yabai = yabai
        self.files = files
        self.layoutPath = layoutPath
        self.statePath = statePath
        self.parse = parse
        self.renderRaw = renderRaw
    }

    /// 游標在這一點時的吸附區。
    ///
    /// 回 nil ＝那一點不在任何一台螢幕上（拖到螢幕之間的縫）。**設定讀不到不算失敗**
    /// ——那時退回九宮格，因為「沒有樹」與「沒有設定檔」對這個功能是同一件事。
    public func zones(at point: MouseDrag.Point) -> (canvas: Rect, zones: [SnapZone])? {
        let displays = (try? yabai.query(.displays)) ?? .null
        guard let display = display(containing: point, in: displays) else { return nil }
        let state = CommandSubstitution.capture(
            ((try? files.read(atPath: statePath)) ?? nil) ?? ""
        )
        let canvas = LayoutCanvas.of(frame: display.frame, display: display.uuid,
                                     state: state).frame
        return (canvas, SnapZones.of(canvas: canvas,
                                     leaves: leaves(on: display, canvas: canvas,
                                                    state: state)))
    }

    private struct Screen {
        let uuid: String
        let indexText: String
        let frame: Rect
    }

    private func display(containing point: MouseDrag.Point,
                         in displays: JSONValue) -> Screen?
    {
        guard case let .array(rows) = displays else { return nil }
        for row in rows {
            guard case let .string(uuid)? = row["uuid"],
                  let frame = rect(row["frame"]),
                  point.posX >= frame.originX, point.posX < frame.originX + frame.width,
                  point.posY >= frame.originY, point.posY < frame.originY + frame.height
            else { continue }
            return Screen(uuid: uuid, indexText: renderRaw(row["index"] ?? .null),
                          frame: frame)
        }
        return nil
    }

    /// 那台螢幕目前可見的 space 在設定裡的樹，排進畫布之後的葉矩形。
    /// 任何一步查不到就回空陣列——呼叫端把空的當成「用九宮格」。
    private func leaves(on display: Screen, canvas: Rect, state _: String) -> [Rect] {
        let reading = LayoutReading(renderRaw: renderRaw)
        let silent = SilentReporter()
        let preamble = LayoutPreamble(
            yabai: yabai, reporter: silent, reading: reading, renderRaw: renderRaw,
            loader: LayoutLoader(files: files, path: layoutPath, parse: parse,
                                 reporter: silent),
            stateReader: StateReader(files: files, path: statePath),
            activeLocation: ActiveLocation(yabai: yabai, reporter: silent)
        )
        guard case let .ready(decided) = preamble.decide(want: "") else { return [] }
        let spaceTrees = (try? reading.member(decided.config, decided.location, "profiles",
                                              decided.choice.name, "spaceTrees")) ?? .null
        let spaces = (try? yabai.query(.spaces)) ?? .null
        guard let index = try? parse(display.indexText),
              let visible = (try? Displays.visibleSpaceObject(on: index, in: spaces)) ?? nil,
              case let .string(spaceUUID)? = visible["uuid"],
              let role = role(forDisplay: display.uuid, location: decided.location,
                              config: decided.config, spaceTrees: spaceTrees,
                              reading: reading),
              let tree = SpaceNames.tree(role: role, uuid: spaceUUID, in: spaceTrees),
              let found = try? TreeRects.leaves(of: tree, in: canvas)
        else { return [] }
        return found.map(\.rect)
    }

    /// 這台螢幕在這個 profile 裡是哪個角色。`spaceTrees` 的角色才算——
    /// 只在 `displays` 出現而沒有任何樹的角色，查了也沒有樹。
    private func role(forDisplay uuid: String, location: String, config: JSONValue,
                      spaceTrees: JSONValue, reading: LayoutReading) -> String?
    {
        reading.roles(of: spaceTrees).first {
            reading.displayUUID(of: $0, location: location, in: config) == uuid
        }
    }

    private func rect(_ value: JSONValue?) -> Rect? {
        guard let value,
              case let .number(originX)? = value["x"], case let .number(originY)? = value["y"],
              case let .number(width)? = value["w"], case let .number(height)? = value["h"],
              let posX = Double(originX), let posY = Double(originY),
              let sizeW = Double(width), let sizeH = Double(height)
        else { return nil }
        return Rect(originX: posX, originY: posY, width: sizeW, height: sizeH)
    }
}

/// 這條路上沒有人要看事件：吸附區算不出來就是退回九宮格，而那不是錯誤。
private struct SilentReporter: Reporter {
    func report(_: WorkmodeEvent) {}
}
