import WorkmodeDomain

// RectTreeTests 拆成兩個檔之後這兩支兩邊都要用，所以搬到這裡。
//
// `leaf` 與 LayoutTreeTests 那支同名但**不是**同一支：這裡的 window 收 JSONValue
// （邊界那組要餵 null 與數字），那裡收 String。兩者簽章不同、JSONValue 又沒有
// ExpressibleByStringLiteral，所以是明確的多載而不是撞名，`leaf("A")` 永遠挑得到
// LayoutTreeTests 自己那支。合成一支要把那邊 53 個 leaf("A") 全部改成
// leaf(.string("A"))，讀起來更差。

/// 一個矩形。label 給 nil 代表整個鍵不存在（未命名的視窗會變成 window: null）。
func rect(_ label: JSONValue?, _ originX: String, _ originY: String,
          _ width: String, _ height: String) -> JSONValue
{
    var pairs: [(String, JSONValue)] = []
    if let label {
        pairs.append(("label", label))
    }
    pairs += [("x", num(originX)), ("y", num(originY)), ("w", num(width)), ("h", num(height))]
    return obj(pairs)
}

func leaf(_ window: JSONValue, _ ratio: String? = nil) -> JSONValue {
    var pairs: [(String, JSONValue)] = [("window", window)]
    if let ratio {
        pairs.append(("ratio", num(ratio)))
    }
    return obj(pairs)
}
