/// Core 是 use case 層：apply / probe / save / switch 的編排。
/// 它定義 port（protocol），不認識任何實作——實作在 Adapters。
public enum WorkmodeCore {
    public static let layerName = "Core"
}
