/// Domain 是最內層：實體與純規則。
///
/// 它不知道 JSON、不知道 yabai、不知道檔案系統。這不是風格偏好——
/// 後續會有一個測試掃這個目錄，出現 Process / FileManager /
/// JSONSerialization / FileHandle 就讓測試紅。
public enum WorkmodeDomain {
    public static let layerName = "Domain"
}
