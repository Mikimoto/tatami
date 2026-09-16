import WorkmodeDomain

// 三個測試檔各自有一份 leaf：TreeLayoutTests 那份多一個 ratio 參數，另外兩份是它
// ratio 為 nil 的特例（輸出逐字相同）。留超集這一份就夠。
//
// 這個 target 裡其他的同名 fixture（config、oneDisplay、layoutPath…）**不是**
// 同一份東西，值各不相同，所以沒有一起收進來——它們留在各自的檔案裡。

func leaf(_ label: String, ratio: String? = nil) -> JSONValue {
    var members = [JSONMember(key: "window", value: .string(label))]
    if let ratio {
        members.append(JSONMember(key: "ratio", value: .number(ratio)))
    }
    return .object(members)
}
