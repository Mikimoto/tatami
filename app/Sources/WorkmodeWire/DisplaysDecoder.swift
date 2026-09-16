import Foundation
import WorkmodeDomain

public enum WireError: Error {
    case notAnArray
}

public enum DisplaysDecoder {
    /// 對齊 jq 的行為：根不是陣列時失敗；元素缺 uuid 或 index 就跳過
    /// （jq 的 `.index // empty` 對缺欄位的物件不輸出）。
    public static func decode(_ json: String) throws -> [Display] {
        let root = try JSONSerialization.jsonObject(with: Data(json.utf8))
        guard let items = root as? [Any] else { throw WireError.notAnArray }
        return items.compactMap { item in
            guard let obj = item as? [String: Any],
                  let uuid = obj["uuid"] as? String,
                  let index = obj["index"] as? Int else { return nil }
            return Display(uuid: uuid, index: index)
        }
    }
}
