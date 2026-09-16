/// Wire 是序列化層：layout.json 的保序讀寫、TSV 輸出、--json 的封套。
///
/// 這裡有兩個方向相反的序列化器，不要為了 DRY 合併：
///   · layout.json 的寫入器要「保留來源鍵序」（windows 的順序決定誰先認領視窗）
///   · --json 的封套要「鍵序穩定」（sortedKeys），才好做位元組斷言
public enum WorkmodeWire {
    public static let layerName = "Wire"
}
