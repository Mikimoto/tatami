/// 位置庫的一格：一個名字、一塊格線上的位置、以及選配的一組快捷鍵。
///
/// **形狀就是既有 `grid:` 動作的參數**（`rows:cols:x:y:w:h`，與 yabai 的
/// `--grid` 逐字相同的順序）。不發明比例格式，兩個理由：
///
///   * `grid:` **自帶格數**，所以某台螢幕改成 4×4 之後既有的 zone 不會壞
///     ——`2:2:0:0:1:1` 永遠是「左半」。
///   * 這個檔是人要讀也要改的（`HotkeyAction` 的檔頭就是這個理由選字串而不是
///     巢狀物件），而 `2:2:0:0:1:1` 讀得出來、`0.0:0.0:0.5:1.0` 讀不出來。
///
/// **不塞進 `bindings`**：`HotkeyBinding.hotkey` 是非 optional 的，而沒有掛
/// 快捷鍵的 zone 是常態（Lasso 的截圖裡就有沒有徽章的格）。
///
/// **`Equatable` 而不是 `Hashable`**：`WindowGeometry.GridSpec` 只 conform
/// `Equatable`，所以合成的 `Hashable` 編不過；而這裡沒有消費端需要雜湊
/// （`HotkeyDocument` 自己也只是 `Equatable`）。要 Hashable 的那天再一起加，
/// 現在加等於替一個沒有人問的問題選一個答案。
public struct GridZone: Equatable, Sendable {
    public let name: String
    public let spec: WindowGeometry.GridSpec
    /// nil ＝只在面板裡按得到。
    public let hotkey: Hotkey?

    public init(name: String, spec: WindowGeometry.GridSpec, hotkey: Hotkey? = nil) {
        self.name = name
        self.spec = spec
        self.hotkey = hotkey
    }

    /// 檔案裡那個 `grid` 欄位的文字。**沒有 `grid:` 前綴**——鍵名已經是 `grid`，
    /// 再寫一次是雜訊；解析時補回去就能整支重用 `HotkeyAction.parse`，
    /// 於是這裡零個新的 parser。
    ///
    /// 切在第一個 `:` 而不是 `replacingOccurrences(of:with:)`——後者是 Foundation，
    /// 而 Domain 零 import（`WorkmodeArchitectureTests` 在守）。從 `text` 切出來
    /// 而不是自己再拼一次那六個數字：拼第二份就等於宣稱兩邊永遠一起改。
    public var gridText: String {
        let text = action.text
        guard let colon = text.firstIndex(of: ":") else { return text }
        return String(text[text.index(after: colon)...])
    }

    /// 有快捷鍵就變成一條綁定，與既有 45 條走同一條註冊路徑。
    public var binding: HotkeyBinding? {
        guard let hotkey else { return nil }
        return HotkeyBinding(hotkey: hotkey, action: action)
    }

    private var action: HotkeyAction {
        .placeGrid(rows: spec.rows, columns: spec.columns,
                   originX: spec.originX, originY: spec.originY,
                   width: spec.width, height: spec.height)
    }
}

public extension HotkeyDocument {
    /// 要送去 `RegisterEventHotKey` 的全部：綁定 ＋ 有快捷鍵的 zone。
    ///
    /// 合成一份而不是讓註冊那側多收一個參數：`HotkeyBindings.conflicts` 吃的是
    /// `[HotkeyBinding]`，合起來之後「zone 的鍵與某條綁定撞了」自動被抓到——
    /// 分開的話那個撞鍵是靜默的（`RegisterEventHotKey` 對重複的組合回錯誤，
    /// 而後來那個就安靜地不生效）。
    /// 下一個自動名字：第一個**沒用過**的「區塊 N」，不是最大的加一。
    ///
    /// 固定或留空的話按第二次就撞名——與「新增規則」挑 `新規則 N` 同一條。
    /// 撞名不是無害的：`removingZone` 用名字比對，兩個同名會一次刪掉兩個。
    var nextZoneName: String {
        let taken = Set(zones.map(\.name))
        var number = 1
        while taken.contains("區塊 \(number)") {
            number += 1
        }
        return "區塊 \(number)"
    }

    /// 加一個 zone，**其餘一個欄位都不動**。
    ///
    /// 寫成 Domain 的純函式而不是在 CLI 那層改字典：面板與編輯器的「快捷鍵」頁
    /// 寫同一個檔，動到別的鍵就是互相蓋掉對方，而症狀是「我剛設的快捷鍵不見了」。
    /// 純函式讓那件事有測試守著（`addingAZoneLeavesEverythingElseAlone`），
    /// 而 CLI 那一層是零測試的。
    func addingZone(named name: String, spec: WindowGeometry.GridSpec) -> HotkeyDocument {
        var copy = self
        copy.zones.append(GridZone(name: name, spec: spec))
        return copy
    }

    /// 依名字刪。用名字而不是索引：面板寫檔前會**重讀**整份文件（別的 writer
    /// 可能已經動過），而重讀之後索引可能指到別人。
    func removingZone(named name: String) -> HotkeyDocument {
        var copy = self
        copy.zones.removeAll { $0.name == name }
        return copy
    }

    var registrableBindings: [HotkeyBinding] {
        bindings + zones.compactMap(\.binding)
    }
}
