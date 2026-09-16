/// Adapters 實作 Core 定義的 port：YabaiClient(Process)、FileStore、
/// SafariClient(osascript)、AppLauncher、Picker(fzf)、TTY。
///
/// 它存在的理由不是分層美學：bash 裡「會呼叫 yabai 的函式一律靠實機驗證」，
/// 因為沒有接縫。有了 port 之後，那 19 個函式的編排邏輯第一次可以用假的實作測。
public enum WorkmodeAdapters {
    public static let layerName = "Adapters"
}
