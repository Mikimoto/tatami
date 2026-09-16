// swift-tools-version: 6.0
import PackageDescription

// 相依方向：CLI → Adapters → Core → Domain，Wire → Domain。
// Domain 的 dependencies 是空的，那不是疏漏，是這個架構的核心約束。
let package = Package(
    name: "WorkmodePackage",
    platforms: [.macOS("14.0")],
    products: [
        .library(name: "WorkmodeDomain", targets: ["WorkmodeDomain"]),
        .library(name: "WorkmodeCore", targets: ["WorkmodeCore"]),
        .executable(name: "tatami", targets: ["WorkmodeCLI"]),
    ],
    targets: [
        .target(name: "WorkmodeDomain"),
        .target(name: "WorkmodeWire", dependencies: ["WorkmodeDomain"]),
        .target(name: "WorkmodeCore", dependencies: ["WorkmodeDomain"]),
        .target(name: "WorkmodeAdapters",
                dependencies: ["WorkmodeCore", "WorkmodeDomain", "WorkmodeWire"]),
        // 編輯器的三層，MVC 對應 clean architecture 的三圈（相依向內）。
        // 拆三個 target 而不是一個：分層是 WorkmodeArchitectureTests 掃原始碼在守的，
        // 同一個 target 裡 Model 與 View 的界線只剩檔名，而沒有測試跑得到 view 的
        // 程式碼（這裡沒有 UI test target，就像下面 CLI 的 switch 也沒人跑得到）。
        // 架構測試讀得到 view 的原始碼，那是掃字串，不是執行它。
        .target(name: "WorkmodeEditorModel", dependencies: ["WorkmodeDomain"]),
        .target(name: "WorkmodeEditorControl",
                dependencies: ["WorkmodeEditorModel", "WorkmodeDomain",
                               "WorkmodeWire", "WorkmodeCore"]),
        .target(name: "WorkmodeEditorUI",
                dependencies: ["WorkmodeEditorControl", "WorkmodeEditorModel",
                               "WorkmodeDomain"]),
        .executableTarget(name: "WorkmodeCLI",
                          dependencies: ["WorkmodeAdapters", "WorkmodeCore",
                                         "WorkmodeDomain", "WorkmodeWire",
                                         "WorkmodeEditorUI", "WorkmodeEditorControl",
                                         "WorkmodeEditorModel"]),
        .testTarget(name: "WorkmodeDomainTests", dependencies: ["WorkmodeDomain"]),
        // 沒有 dependencies：它掃的是原始碼檔案，不 import 任何層。
        .testTarget(name: "WorkmodeArchitectureTests"),
        // Core 的 port 沒有差分基準（bash 那側沒有接縫），驗收改成用 fake 測編排。
        .testTarget(name: "WorkmodeCoreTests",
                    dependencies: ["WorkmodeCore", "WorkmodeDomain"]),
        // renderer 住在 Adapters 而不是 CLI，就是為了讓這個 target 測得到它——
        // CLI 是 executable target，那裡的 switch 沒有測試進得去。
        .testTarget(name: "WorkmodeAdaptersTests",
                    dependencies: ["WorkmodeAdapters", "WorkmodeCore", "WorkmodeDomain"]),
        // 編輯器的兩個測試 target 隨它們的第一個測試檔一起加——
        // WorkmodeEditorModelTests 跟著 PaneNodeTests、
        // WorkmodeEditorControlTests 跟著 EditorControllerTests。
        // 先宣告是不行的：SwiftPM 對「Tests/<name>/ 不存在的 testTarget」是硬失敗
        // （`error: Source files for target … should be located under …`），
        // 不是當成空 target 略過。
        .testTarget(name: "WorkmodeEditorModelTests",
                    dependencies: ["WorkmodeEditorModel", "WorkmodeDomain", "WorkmodeWire"]),
        // `WorkmodeAdapters` 在這裡是為了 `HotkeyFile.readable`：那道「這份檔能不能
        // 拿來覆寫」的守衛只有一份實作，而 `GridSettingsEditor` 的 `canSave` 守的就是
        // 它——測試自己抄一份的話，產品那支壞掉時這裡照樣全綠（2026-09-09 實測過）。
        // 只有測試 target 這樣連，`Sources/WorkmodeEditorControl` 的相依沒有變
        // （`DependencyRuleTests` 掃的是 `Sources/`）。
        .testTarget(name: "WorkmodeEditorControlTests",
                    dependencies: ["WorkmodeEditorControl", "WorkmodeEditorModel",
                                   "WorkmodeDomain", "WorkmodeWire", "WorkmodeCore",
                                   "WorkmodeAdapters"]),
        .testTarget(name: "WorkmodeWireTests",
                    dependencies: ["WorkmodeWire", "WorkmodeDomain"]),
    ]
)
