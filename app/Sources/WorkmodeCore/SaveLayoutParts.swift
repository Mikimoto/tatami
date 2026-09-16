import WorkmodeDomain

// `save_layout` 自己的零件。與主檔分開只是型別長度——每一支的唯一呼叫端都在
// SaveLayout 的三個階段（盤點、問名字、組樹）裡。
//
// 這一組多數要讀 SaveLayout 的相依物（reading、renderRaw、rules），所以連同那三個
// 欄位一起從 private 放寬成 internal。Swift 的 private 是**檔案**範圍，跨檔的
// extension 看不到——這與 Domain 那幾次拆檔是同一個代價，只是這次落在儲存屬性上。
// 它們都是 let，而且 WorkmodeCore 之外仍然看不到。

// MARK: - 這一支自己的零件

extension SaveLayout {
    /// `printf '%s' "$catalog" | cut -f1`：整份總表的 label，一行一個。
    /// `save_layout` 的 keep 是**整份**而不是這次樹引用到的那些（workmode.sh:1101）。
    func labels(of catalog: String) -> String {
        catalog.split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.split(separator: "\t", maxSplits: 1,
                            omittingEmptySubsequences: false).first.map(String.init) ?? "" }
            .joined(separator: "\n")
    }

    /// `rules` 的 `<label>\t<id>` 反轉成 `{"<id>": "<label>"}`（workmode.sh:1107-1109）。
    /// awk 的 `NF == 2` 濾掉欄數不是 2 的行——空行因此不會變成一個空 key。
    func idmapObject(from rules: String) -> JSONValue {
        var members: [JSONMember] = []
        for line in rules.split(separator: "\n", omittingEmptySubsequences: false) {
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard fields.count == 2 else { continue }
            members.append(JSONMember(key: String(fields[1]), value: .string(String(fields[0]))))
        }
        // `add // {}`：後面的鍵蓋掉前面同名的，與 jq 的物件合併同向。
        var seen: [String: Int] = [:]
        var merged: [JSONMember] = []
        for member in members {
            if let existing = seen[member.key] {
                merged[existing] = member
            } else {
                seen[member.key] = merged.count
                merged.append(member)
            }
        }
        return .object(merged)
    }

    /// `.[$l].displays[]`：這個地點宣告的螢幕 uuid。
    func knownUUIDs(location: String, in config: JSONValue) -> Set<String> {
        guard case let .object(members)? = try? reading.member(config, location, "displays")
        else { return [] }
        return Set(members.map { renderRaw($0.value) })
    }

    /// `.[].uuid`：當下接上的。
    func connectedUUIDs(in displays: JSONValue) -> [String] {
        guard case let .array(items) = displays else { return [] }
        return items.compactMap { item in
            guard case let .string(text)? = item["uuid"] else { return nil }
            return text
        }
    }

    /// `.[$l].displays | keys_unsorted[]`。與 `roles(of:)` 不同的是它讀的是 displays
    /// 而不是 trees——存版面時是「這個地點有哪些螢幕」，不是「上次存了哪些樹」。
    func displayRoles(location: String, in config: JSONValue) -> [String] {
        guard case let .object(members)? = try? reading.member(config, location, "displays")
        else { return [] }
        return members.map(\.key)
    }

    func displayUUID(role: String, location: String, in config: JSONValue) -> String? {
        reading.displayUUID(of: role, location: location, in: config)
    }

    func displayIndexText(forUUID uuid: String, in displays: JSONValue) -> String {
        reading.displayIndexText(forUUID: uuid, in: displays)
    }

    /// `--argjson d "$idx"`：那段文字要能解析回一個 JSON 值。多筆命中時它是兩行，
    /// 於是解析失敗——那條路徑在 bash 是 `visible_space_on` 印不出東西。
    func parseIndex(_ text: String) throws -> JSONValue {
        guard let number = Int(text) else { throw LayoutQueryError.runtime }
        return .number(String(number))
    }

    /// `map(.role = $r)`（workmode.sh:1138）。
    func stamp(_ rects: JSONValue, role: String) -> JSONValue {
        guard case let .array(items) = rects else { return rects }
        return .array(items.map { item in
            guard case var .object(members) = item else { return item }
            members.removeAll { $0.key == "role" }
            members.append(JSONMember(key: "role", value: .string(role)))
            return .object(members)
        })
    }

    func rectArray(_ value: JSONValue) -> [JSONValue] {
        guard case let .array(items) = value else { return [] }
        return items
    }

    /// 問名字時印的那段位置：`\(.w)x\(.h) @\(.x),\(.y)`（workmode.sh:1185）。
    func position(of rect: JSONValue) -> String {
        let field = { (key: String) in self.renderRaw(rect[key] ?? .null) }
        return "\(field("w"))x\(field("h")) @\(field("x")),\(field("y"))"
    }

    /// 沒有名字的矩形在**切樹之前**就丟掉（2026-09-08 改，使用者裁決）。
    ///
    /// 原本是 bash 的順序：`fromRects` 拿**全部**矩形切出一棵樹，再用
    /// `LayoutTree.prune` 把沒有名字的葉剪掉。那個順序在 yabai 的 bsp 底下是對的
    /// ——畫面必定是一個可以遞迴對切的分割，而未命名的視窗佔的格子是真的存在。
    /// bsp 退役之後什麼都不管，**一個隨手擺的 Finder 視窗就讓那個 space 存不下來**：
    /// 它擋得住 `fromRects`，卻反正會被 `prune` 剪掉——參與幾何只有害處。
    ///
    /// 代價（明講）：存下來的比例與畫面有落差。那些視窗佔的空間被剩下的葉均分掉，
    /// 而不是照它們原本的分割線。`prune` 之後的 `trim` 本來也會丟掉那段比例，
    /// 所以差別只在「剩下的葉怎麼分那塊空出來的地方」。
    ///
    /// 連帶：`LayoutTree.prune` 與那份 `live` 清單在這條路上不再需要
    /// （每一片葉都有名字，剪不掉任何東西）。
    func onlyNamed(_ rects: JSONValue) -> JSONValue {
        guard case let .array(items) = rects else { return rects }
        return .array(items.filter { !renderRaw($0["label"] ?? .null).isEmpty })
    }

    /// `map(if .label == "" then .label = ($m[.id | tostring] // "") else . end)`。
    func fill(_ rects: JSONValue, with labels: [String: String]) -> JSONValue {
        guard case let .array(items) = rects else { return rects }
        return .array(items.map { item in
            guard case var .object(members) = item,
                  renderRaw(item["label"] ?? .null).isEmpty else { return item }
            let id = renderRaw(item["id"] ?? .null)
            let label = labels[id] ?? ""
            if let existing = members.firstIndex(where: { $0.key == "label" }) {
                members[existing] = JSONMember(key: "label", value: .string(label))
            } else {
                members.append(JSONMember(key: "label", value: .string(label)))
            }
            return .object(members)
        })
    }

    /// workmode.sh:1212-1215 那個遞迴的 jq：葉子印 `window`（有 ratio 就加一個空白
    /// 與它），節點印 `(左 <軸的第一個字> 右)`。
    func shape(of node: JSONValue) -> String {
        if let window = node["window"] {
            let ratio = node["ratio"].map { " " + renderRaw($0) } ?? ""
            return renderRaw(window) + ratio
        }
        guard case let .array(children)? = node["children"], children.count == 2 else {
            return ""
        }
        let axis = renderRaw(node["axis"] ?? .null)
        return "(" + shape(of: children[0]) + " " + String(axis.prefix(1)) + " "
            + shape(of: children[1]) + ")"
    }

    /// `.[$l].profiles | has($p)`。
    func profileExists(_ profile: String, location: String,
                       in config: JSONValue) -> Bool
    {
        guard case let .object(members)? = try? reading.member(config, location, "profiles")
        else { return false }
        return members.contains { $0.key == profile }
    }

    /// 每個角色的矩形反推成一棵樹。
    ///
    /// 回 nil 是「某個角色的矩形排不成樹」——那是 `return .rejected`，整支放棄。
    /// 回空陣列是「每個角色都被跳過」，呼叫端另有一句話要報，所以兩者不能合併。
    /// 回的是 `{角色: {space uuid: 樹}}` 的角色那一層。
    ///
    /// **一個角色可以有多個 uuid**（`--save --all`），所以這裡要**依角色分組**再吐
    /// 一個成員。每個 `RoleRects` 各吐一個同名成員的話，`spaceTrees` 會出現重複的
    /// 角色鍵，而 `ProfileMerge.mergeSpaceTrees` 只會留下其中一個——症狀是
    /// 「存了五個 space，只有最後一個進得去」，而存檔本身完全成功。
    func buildTrees(roleRects: [RoleRects],
                    named: Named) -> [JSONMember]?
    {
        // 角色維持首次出現的順序，uuid 維持量到的順序：`JSONWriter` 照鍵序輸出，
        // 而順序漂掉會讓一次沒有實質變更的存檔產生整段 diff。
        var order: [String] = []
        var byRole: [String: [JSONMember]] = [:]
        for entry in roleRects {
            let filled = onlyNamed(fill(entry.rects, with: named.labels))
            // 一個名字都沒有就沒有東西可存，而 `fromRects` 對空陣列的回答與
            // 「切不開」相同（都是 null）——要在那之前分出來，不然訊息會叫使用者
            // 去整理一個其實沒問題的畫面。
            if rectArray(filled).isEmpty {
                reporter.report(.saveRoleHasNoNamedWindow(role: entry.role))
                continue
            }
            // **一個角色（或一個 space）切不開不擋其他的**，與 `SpaceLayout` 那六條
            // `…DoesNotStopTheOnesAfterIt` 同一條規則。`return nil` 會讓整趟
            // `--save --all` 因為某一個螢幕上有兩個沒在樹裡的 Finder 視窗而一個字
            // 都不寫，而那個訊息指的是使用者當下沒在看的那台螢幕。
            //
            // 切不開時先讓 `splittable` 把這一輪自己命名的那些拿掉再試一次
            // （`SaveAutoNames.swift`，那支的 doc 寫著為什麼只丟得動那些）。
            guard let tree = splittable(filled, named: named, role: entry.role) else {
                reporter.report(.saveRoleNotSplittable(role: entry.role))
                continue
            }
            reportSmallRatios(in: tree)
            guard let trimmed = try? RectTree.trim(tree) else { continue }
            reporter.report(.saveRoleShape(role: entry.role, shape: shape(of: trimmed)))
            if byRole[entry.role] == nil {
                order.append(entry.role)
            }
            byRole[entry.role, default: []]
                .append(JSONMember(key: entry.uuid, value: trimmed))
        }
        return order.map { JSONMember(key: $0, value: .object(byRole[$0] ?? [])) }
    }

    /// 存不下來的比例要講出來，不能靜默丟掉——但門檻是 0.47 而不是 trim 的 0.53。
    /// 兩者之間那一段是均分，trim 一樣會丟掉它，可是均分本來就沒有東西可存，
    /// 報「存不下來」是假的。
    func reportSmallRatios(in tree: JSONValue) {
        try? LayoutTree.ratios(tree) { ratio in
            if let value = Double(renderRaw(ratio.ratio)), value < 0.47 {
                reporter.report(.saveRatioTooSmall(label: renderRaw(ratio.label),
                                                   ratio: renderRaw(ratio.ratio)))
            }
        }
    }

    /// 這個 profile 的 `spaceTrees` 裡，**這一輪沒有寫到**的 space 有幾個。
    ///
    /// `--save` 只量得準目前可見的那幾個 space：不可見的 space 上，yabai 更新樹但不套
    /// frame（實測 2026-08-30：對不可見的 space 下 swap，`split-child` 對調而 `frame`
    /// 一動也不動），而這支是量 frame 再反推成樹。所以要說出來——不說的話使用者會
    /// 以為整個 profile 都存了。
    ///
    /// 數的是**舊設定**裡的 uuid：`written` 是這一輪要寫的那幾個，兩者相減就是沒動的。
    /// 角色也算進去——同一個角色底下別的 space 與別的角色，對使用者是同一件事
    /// （「我沒看到的那些版面沒有被重新量過」）。
    func untouchedSpaceCount(config: JSONValue, location: String, profile: String,
                             written: [JSONMember]) -> Int
    {
        guard case let .object(roles)? = try? reading.member(config, location, "profiles",
                                                             profile, "spaceTrees")
        else { return 0 }
        var writtenPairs: Set<String> = []
        for role in written {
            guard case let .object(spaces) = role.value else { continue }
            for space in spaces {
                writtenPairs.insert("\(role.key)\u{0}\(space.key)")
            }
        }
        var count = 0
        for role in roles {
            guard case let .object(spaces) = role.value else { continue }
            for space in spaces where !writtenPairs.contains("\(role.key)\u{0}\(space.key)") {
                count += 1
            }
        }
        return count
    }
}

// MARK: - 逐角色量測（`--save` 的盤點那一半）

extension SaveLayout {
    /// 每個角色要存的那幾個 space 的矩形。
    ///
    /// 搬出主檔的理由是 `type_body_length` 與 `cyclomatic_complexity`
    /// （上限 250／10，`.swiftlint.yml` 的檔頭明文禁止調參數）。
    /// `displays`／`spaces`／`idmap` 包成一包：這支原本就有六個參數，而 swiftlint 的
    /// `function_parameter_count` 上限是 5（不准調參數）。三者都是「這一輪從
    /// yabai 問到的畫面」，本來就是一組。
    struct Snapshot {
        let displays: JSONValue
        let spaces: JSONValue
        let idmap: JSONValue
    }

    func collectRects(config: JSONValue, location: String, scope: Scope,
                      snapshot: Snapshot) -> [RoleRects]
    {
        let displays = snapshot.displays, spaces = snapshot.spaces
        let idmap = snapshot.idmap
        var out: [RoleRects] = []
        for role in displayRoles(location: location, in: config) {
            guard let uuid = displayUUID(role: role, location: location, in: config) else {
                continue
            }
            let indexText = displayIndexText(forUUID: uuid, in: displays)
            if indexText.isEmpty {
                reporter.report(.saveRoleDisplayNotConnected(role: role))
                continue
            }
            guard let index = try? parseIndex(indexText) else {
                reporter.report(.saveRoleHasNoVisibleSpace(role: role))
                continue
            }
            let targets = spacesToSave(on: index, scope: scope, spaces: spaces)
            if targets.isEmpty {
                reporter.report(.saveRoleHasNoVisibleSpace(role: role))
                continue
            }
            out.append(contentsOf: rects(role: role, targets: targets, idmap: idmap))
        }
        return out
    }

    private func rects(role: String, targets: [JSONValue],
                       idmap: JSONValue) -> [RoleRects]
    {
        var out: [RoleRects] = []
        for space in targets {
            guard case let .string(spaceUUID)? = space["uuid"] else { continue }
            let spaceText = renderRaw(space["index"] ?? .null)
            let windows = (try? yabai.query(.windowsOnSpace(spaceText))) ?? .null
            guard let computed = try? SpaceRects.compute(windows: windows, idmap: idmap,
                                                         idText: renderRaw)
            else { continue }
            // 空的 space 直接跳過，不報錯——`--all` 底下那是常態。
            if rectArray(computed.rects).isEmpty {
                continue
            }
            // 把角色蓋到每個矩形上：待會問名字時要講「這是哪個螢幕上的哪一塊」，
            // 而攤平成一份之後就分不出來了。
            out.append(RoleRects(role: role, uuid: spaceUUID,
                                 rects: stamp(computed.rects, role: role)))
        }
        return out
    }

    /// 這一輪要存哪幾個 space。
    ///
    /// `.visible` 走 `Displays.visibleSpaceObject`——與 `SpaceLayout.resolveTargets`
    /// 同一支，兩邊挑到不同的 space 的話症狀是「存進 A、套的是 B」，
    /// 而畫面上完全看不出來。
    private func spacesToSave(on index: JSONValue, scope: Scope,
                              spaces: JSONValue) -> [JSONValue]
    {
        switch scope {
        case .visible:
            guard let visible = (try? Displays.visibleSpaceObject(on: index,
                                                                  in: spaces)) ?? nil
            else { return [] }
            return [visible]
        case .all:
            guard case let .array(rows) = spaces else { return [] }
            return rows.filter { $0["display"] == index }
        }
    }

    /// 覆寫的許可。抽成一支是為了讓 `build` 過 swiftlint 的
    /// `cyclomatic_complexity`（上限 10，不准調參數）。
    func granted(_ interaction: Interaction) -> Bool {
        switch interaction {
        case .terminal:
            let answer = terminal.readLine() ?? ""
            return answer == "y" || answer == "Y"
        // 選單列那條已經在畫面上問過了，這裡不再問一次。
        case let .automatic(overwrite):
            return overwrite
        }
    }
}
