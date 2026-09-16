/// 對一份 `JSONValue` 做**定點**修改：只碰路徑指到的那一個位置，其餘位元組原樣帶過。
///
/// 為什麼路徑是 `[Step]` 而不是 `[String]`：編輯器要改的是 `windows` 陣列裡的第 N 條
/// 規則，所以鍵與索引得混著走。`ProfileMerge`（`ProfileResolution.swift`）原本自己帶了
/// 一份只走物件的複製品，2026-08-19 併進來了——留兩份走訪的話，改了一邊另一邊不會出聲。
/// 差分語料（`merge_profile`／`resolve_profile`）是那次併入的護欄。
///
/// 寫入有**兩個**公開入口，差別只在路徑上遇到 `null` 中繼節點時的態度：`set` throw，
/// `setCreatingMissingObjects` 照 jq `setpath` 建成物件。兩個名字而不是一個布林旗標，
/// 是因為各自的合約不同，讓呼叫端猜旗標等於把合約藏起來。
///
/// 除了那條，語意上與 jq `setpath` 還有一個**刻意**差異，兩個入口都適用：陣列索引越界
/// 就 throw，不像 jq 會補 null 撐長。編輯器的路徑來自它自己剛投影出來的結構，走不通
/// 代表投影與文件不同步，那是 bug 不是要補的洞。
public enum JSONPath {
    public enum Step: Equatable, Sendable {
        case key(String)
        case index(Int)
    }

    public enum Failure: Error, Equatable, Sendable {
        /// 路徑要求走進物件的鍵，但那裡不是物件（或走陣列而那裡不是陣列）。
        /// `step` 是出事的那一段在 `path` 裡的索引。標籤不叫 `at` 是因為 swiftlint
        /// 的 `identifier_name` 對 associated value 的標籤也要求 ≥3 個字元。
        case shapeMismatch(step: Int)
        case indexOutOfRange(step: Int)
    }

    public static func get(_ root: JSONValue, _ path: [Step]) -> JSONValue? {
        var cursor = root
        for step in path {
            switch (step, cursor) {
            case let (.key(name), .object(members)):
                guard let hit = members.first(where: { $0.key == name }) else { return nil }
                cursor = hit.value
            case let (.index(slot), .array(items)):
                guard items.indices.contains(slot) else { return nil }
                cursor = items[slot]
            default:
                return nil
            }
        }
        return cursor
    }

    /// 既有的鍵**原地**更新、新的鍵接在尾端；陣列元素只換值，長度不變。
    /// 路徑走進 `null` 中繼節點就 throw——編輯器的路徑來自自己剛投影出來的結構。
    public static func set(_ root: JSONValue, _ path: [Step],
                           to newValue: JSONValue) throws -> JSONValue
    {
        try edit(root, path, depth: 0, nulls: .reject) { _ in newValue }
    }

    /// jq `setpath` 的語意：路徑上遇到 `null` 就建成物件。**只給 `ProfileMerge` 用**
    /// ——`workmode --save` 可以指定一個還不存在的 profile，那時 `profiles` 這個鍵
    /// 整個不在，得一路建下去（實測：把這條改成 throw，`__diff merge_profile` 從
    /// rc=0 變 rc=5，而差分語料報有差異）。
    ///
    /// 編輯器不用這支而用 `set`：它的路徑來自自己剛投影出來的結構，走不通代表投影
    /// 與文件不同步，那是 bug 不是要補的洞。
    public static func setCreatingMissingObjects(_ root: JSONValue, _ path: [Step],
                                                 to newValue: JSONValue) throws -> JSONValue
    {
        try edit(root, path, depth: 0, nulls: .buildObject) { _ in newValue }
    }

    public static func delete(_ root: JSONValue, _ path: [Step]) throws -> JSONValue {
        guard let last = path.last else { return .null }
        return try container(root, Array(path.dropLast()), depth: 0) { parent in
            switch (last, parent) {
            case let (.key(name), .object(members)):
                return .object(members.filter { $0.key != name })
            case let (.index(slot), .array(items)):
                guard items.indices.contains(slot) else {
                    throw Failure.indexOutOfRange(step: path.count - 1)
                }
                var out = items
                out.remove(at: slot)
                return .array(out)
            default:
                throw Failure.shapeMismatch(step: path.count - 1)
            }
        }
    }

    public static func insert(_ root: JSONValue, _ path: [Step],
                              at index: Int, _ newValue: JSONValue) throws -> JSONValue
    {
        try container(root, path, depth: 0) { parent in
            guard case let .array(items) = parent else {
                throw Failure.shapeMismatch(step: path.count)
            }
            guard index >= 0, index <= items.count else {
                throw Failure.indexOutOfRange(step: path.count)
            }
            var out = items
            out.insert(newValue, at: index)
            return .array(out)
        }
    }

    /// 拿掉再插入。`to` 是**移除之後**的目標索引。
    public static func move(_ root: JSONValue, _ path: [Step],
                            from: Int, to target: Int) throws -> JSONValue
    {
        try container(root, path, depth: 0) { parent in
            guard case let .array(items) = parent else {
                throw Failure.shapeMismatch(step: path.count)
            }
            guard items.indices.contains(from) else {
                throw Failure.indexOutOfRange(step: path.count)
            }
            var out = items
            let moved = out.remove(at: from)
            guard target >= 0, target <= out.count else {
                throw Failure.indexOutOfRange(step: path.count)
            }
            out.insert(moved, at: target)
            return .array(out)
        }
    }

    /// 原地改名一個鍵：值不動、**位置不動**。
    ///
    /// **不能用「`delete` 舊的 ＋ `set` 新的」代替**——`set` 對新鍵是「接在尾端」
    /// （見上面那句註解），於是改一個 profile 的名字會把它整個搬到 `profiles` 的
    /// 最後，而 `JSONWriter` 照來源鍵序輸出：一個改名變成一個全檔 diff。
    ///
    /// 三種情況 throw：那個位置不是物件、`from` 不存在、`to` 已經被別的鍵占著。
    /// 三種共用 `shapeMismatch` 是刻意的——呼叫端（Model）會先各自擋掉並給出不同
    /// 的訊息，走到這裡代表投影與文件不同步，那是 bug 不是要分類的使用者錯誤。
    /// `from == to` 是 no-op 而不是「已存在」。
    public static func renameKey(_ root: JSONValue, _ path: [Step],
                                 from: String, to newName: String) throws -> JSONValue
    {
        try container(root, path, depth: 0) { parent in
            guard case let .object(members) = parent,
                  members.contains(where: { $0.key == from }),
                  from == newName || !members.contains(where: { $0.key == newName })
            else { throw Failure.shapeMismatch(step: path.count) }
            return .object(members.map {
                $0.key == from ? JSONMember(key: newName, value: $0.value) : $0
            })
        }
    }

    // MARK: - 走訪

    /// 路徑上遇到 `null` 中繼節點時怎麼辦。private：外面看到的是兩個具名入口。
    private enum NullPolicy {
        /// 編輯器：走不進去就是投影與文件不同步。
        case reject
        /// jq `setpath`：建成物件再走下去。
        case buildObject
    }

    /// 走到 `path` 指的那個**值**，用 `transform` 換掉它。
    private static func edit(_ node: JSONValue, _ path: [Step], depth: Int,
                             nulls: NullPolicy,
                             _ transform: (JSONValue) throws -> JSONValue) throws -> JSONValue
    {
        guard let step = path.first else { return try transform(node) }
        let rest = Array(path.dropFirst())
        switch (step, node) {
        case let (.key(name), .object(members)):
            var out = members
            if let slot = out.firstIndex(where: { $0.key == name }) {
                let child = try edit(out[slot].value, rest, depth: depth + 1,
                                     nulls: nulls, transform)
                out[slot] = JSONMember(key: name, value: child)
            } else {
                // 缺的鍵先當成 null 再往下走，於是「建不建」由 nulls 一處決定。
                let child = try edit(.null, rest, depth: depth + 1, nulls: nulls, transform)
                out.append(JSONMember(key: name, value: child))
            }
            return .object(out)
        case let (.index(slot), .array(items)):
            guard items.indices.contains(slot) else { throw Failure.indexOutOfRange(step: depth) }
            var out = items
            out[slot] = try edit(out[slot], rest, depth: depth + 1, nulls: nulls, transform)
            return .array(out)
        case let (.key(name), .null) where nulls == .buildObject:
            // 只有鍵這一步會建。jq 對 null 加索引是補一串 null 撐出陣列，而唯一的
            // 呼叫端（ProfileMerge）的路徑全是鍵，照抄那段等於寫一段沒人驗的程式碼。
            let child = try edit(.null, rest, depth: depth + 1, nulls: nulls, transform)
            return .object([JSONMember(key: name, value: child)])
        default:
            throw Failure.shapeMismatch(step: depth)
        }
    }

    /// 走到 `path` 指的那個**容器**，用 `transform` 換掉整個容器。
    /// 三個呼叫端（delete／insert／move）都只有編輯器在用，所以 null 一律 reject。
    private static func container(_ node: JSONValue, _ path: [Step], depth: Int,
                                  _ transform: (JSONValue) throws -> JSONValue) throws -> JSONValue
    {
        try edit(node, path, depth: depth, nulls: .reject, transform)
    }
}
