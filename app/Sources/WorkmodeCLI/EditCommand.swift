import AppKit
import SwiftUI
import WorkmodeAdapters
import WorkmodeCore
import WorkmodeDomain
import WorkmodeEditorControl
import WorkmodeEditorModel
import WorkmodeEditorUI
import WorkmodeWire

/// 組出帶著真 adapters 的 controller。
///
/// **獨立一支而不是寫在 `runEditor()` 裡**：那支已經在 `function_body_length` 的邊上，
/// 而這兩件事本來就不同——這裡是接線，那裡是開視窗。
///
/// **`try?` 不是 `try`。** 這個執行檔的其他子命令找不到 yabai 就該停下（它們每一句都要
/// 問它），但編輯器主要的工作是編一個 JSON 檔，那件事不需要 yabai。拿不到就兩個閉包
/// 都是 nil，⌘R 回 `.notWired` 並照那個理由報——讓編輯器整個開不起來換不到任何安全性。
@MainActor
private func makeController(paths: TatamiPaths) -> EditorController {
    let yabai = try? WindowServerClient()
    // ⌘R 走的是 `--space`，而那條路 2026-09-03 起不叫 yabai。與 `yabai` 分成兩個
    // Optional：拿不到「輔助使用」權限時只該讓 ⌘R 變 `.notWired`，螢幕清單那半
    // （還在問 yabai）不必跟著消失。
    let engine = try? WindowServerClient()
    return EditorController(
        files: FileManagerStore(),
        layoutPath: paths.layout,
        // 組裝照抄 `SpaceCommand.swift` 的 `runSpaceLayout`：同樣的 6 個協定、同樣的
        // 兩個路徑、同樣的 `parse:`／`renderRaw:`。唯一的差別是 reporter——那邊寫進
        // stdout，這邊收進陣列交回 UI 顯示（`CallbackSink`）。
        //
        // **2026-08-30 之前這裡組的是 `ApplyLayout`。** 編輯器現在編的是 `spaceTrees`，
        // 而 `ApplyLayout` 走 `trees`——按 ⌘R 會套一棵使用者沒在編的樹。
        runLayout: engine.map { client in
            { (want: String) -> ApplyRun in
                var lines: [String] = []
                let reporter = TextReporter(
                    renderer: HumanEventRenderer(),
                    sink: CallbackSink { lines.append($0) }
                )
                let outcome = SpaceLayout(
                    // 同一個物件同時是 YabaiClient（查詢形狀）與 WindowServer（setFrame），
                    // 與 `SpaceCommand.swift` 的 `runSpaceLayout` 逐字相同。
                    yabai: client,
                    server: client,
                    safari: SafariOsascriptClient(),
                    clock: SystemClock(),
                    files: FileManagerStore(),
                    layoutPath: paths.layout,
                    statePath: paths.state,
                    parse: JSONParser.parse,
                    renderRaw: rawText,
                    reporter: reporter,
                    // ⌘R 不開 app：`--launch` 是一個要明確打出來的旗標，而這裡
                    // 沒有地方打它。多一個開關只為了讓一顆按鈕能開 app，卻讓
                    // 「只有明確帶旗標才開」這條規則多一個例外。
                    presence: nil
                ).run(want: want, mode: .apply, scope: .visible)
                return ApplyRun(outcome: outcome, lines: lines)
            }
        },
        displays: yabai.map { client in
            {
                let listed = (try? client.query(.displays)).map(Displays.list(in:)) ?? []
                // **以 yabai 那份為準，名稱只是補上去的**：能被 `layout.json` 引用的
                // 是 yabai 列出來的那些，macOS 認得而 yabai 沒列的不該出現在挑選器上。
                //
                // `ScreenCatalog.byUUID()` 是 `@MainActor`（`NSScreen` 是），而這個閉包
                // 存進 `EditorController` 之後沒有任何隔離。唯二的呼叫點是 SwiftUI 的
                // `.task`／`.onAppear`（`LocationView.swift:158`、`AddLocationForm.swift:57`），
                // 兩個都在 main actor 上——所以這裡用斷言而不是 `await`：猜錯會當場
                // crash，而把 `connectedDisplays()` 改成 async 要動到零測試的 UI 那層。
                let names = MainActor.assumeIsolated { ScreenCatalog.byUUID() }
                return DisplayChoice.merge(listed, names: names.mapValues {
                    (name: $0.name, size: "\($0.width)×\($0.height)")
                })
            }
        },
        spaces: yabai.map { client in { liveSpaces(client) } },
        windows: yabai.map { client in { liveWindows(client) } }
    )
}

/// 組出「格線」那一頁的編輯器。
///
/// `try?` 與 `makeController` 同一個理由：拿不到引擎就只是螢幕清單空的，
/// 格數與間距照樣編得動、存得掉——它們寫的是一個 JSON 檔。
@MainActor
private func makeGridSettingsEditor(paths: TatamiPaths,
                                    engine: WindowServerClient?) -> GridSettingsEditor
{
    let files = FileManagerStore()
    return GridSettingsEditor(
        load: { HotkeyFile.readable(from: paths.hotkeys, files: files) },
        store: { try HotkeyFile.save($0, to: paths.hotkeys, files: files) },
        connected: {
            // `ScreenCatalog.byUUID()` 是 `@MainActor`（`NSScreen` 是），而這個閉包
            // 存進 editor 之後沒有任何隔離。唯一的呼叫點是 SwiftUI 的 `.onAppear`，
            // 本來就在 main actor 上——與 `makeController` 的 `displays:` 逐字同一條。
            let names = MainActor.assumeIsolated { ScreenCatalog.byUUID() }
            // **以 yabai 那份為準，名稱只是補上去的**，與 `displays:` 同一條。
            // 查不到名字就退回 uuid：濾掉的話那台螢幕就設不了格數，而畫面上
            // 看不出少了什麼。
            let listed = (try? engine?.query(.displays)).map(Displays.list(in:)) ?? []
            return listed.map { (uuid: $0.uuid, name: names[$0.uuid]?.name ?? $0.uuid) }
        }
    )
}

/// `tatami edit`：組真的 adapter、建 controller、開視窗。這裡不放任何判斷。
///
/// 自己建 NSApplication 而不是用 `@main struct App: App`：這個執行檔是 CLI，
/// 其他子命令不能因為多了一個編輯器就變成 GUI 程式。`.regular` 讓視窗拿得到焦點
/// （`.accessory` 開出來會在背景，使用者以為沒反應）。
///
/// `@MainActor` 不是裝飾：AppKit 與 SwiftUI 的這些型別全都是 main-actor 隔離的，
/// 少了它 Swift 6 會對這裡的每一行發一句 actor-isolation 警告（實測 12 句）。
/// 呼叫端是 `main.swift` 的 top-level code，它本來就跑在 main actor 上。
@MainActor
func runEditor() -> Never {
    let paths = TatamiPaths()
    let controller = makeController(paths: paths)
    do {
        try controller.load()
    } catch {
        fail("! 讀不到或解析不了 \(paths.layout)：\(error)", code: 1)
    }

    let application = NSApplication.shared
    application.setActivationPolicy(.regular)

    let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
        styleMask: [.titled, .closable, .miniaturizable, .resizable],
        backing: .buffered, defer: false
    )
    window.title = "tatami edit"
    // `hotkeys.json` 的編輯器。解析與輸出用注入的閉包，理由與 `SpaceLayout`
    // 的 `parse:`／`renderRaw:` 逐字相同：`WorkmodeEditorControl` 不許 import Wire。
    let hotkeys = HotkeyEditor(files: FileManagerStore(), path: paths.hotkeys,
                               parse: JSONParser.parse, format: JSONWriter.format)
    // 格線那一頁。自己一個 client 而不是共用 `makeController` 那個：那支的兩個
    // Optional 是它自己的區域變數，而這裡拿不到引擎的後果只是螢幕清單空的。
    let gridSettings = makeGridSettingsEditor(paths: paths, engine: try? WindowServerClient())
    let root = EditorWindow(controller: controller, hotkeys: hotkeys,
                            gridSettings: gridSettings)
    window.contentView = NSHostingView(rootView: root)
    window.center()
    window.makeKeyAndOrderFront(nil)

    // 關掉視窗就結束，與其他子命令「跑完就退」的形狀一致；有沒存的東西先問一聲。
    quitOnClose.controller = controller
    quitOnClose.hotkeys = hotkeys
    quitOnClose.gridSettings = gridSettings
    window.delegate = quitOnClose
    application.activate(ignoringOtherApps: true)
    application.run()
    exit(0)
}

/// `NSWindow.delegate` 是 **weak**，而這個物件沒有別的持有者，所以它不能是區域變數：
/// ARC 可以在最後一次使用（指派那一行）之後就釋放它。debug build 通常會把生命週期延到
/// 作用域結束，所以那樣寫看起來沒事——但那是 `-Onone` 的行為不是語言保證，
/// `withExtendedLifetime` 存在就是因為沒有那個保證。
///
/// 症狀會是「關掉視窗但程式不結束」，而它**只在 release build 出現**，本機的
/// `mise run install` 裝的是 debug，所以人工驗收也照不出來。放檔案層級是最便宜的做法。
/// `@MainActor`：Swift 6 對非 Sendable 型別的全域要求隔離，而唯一的使用者已經是 main actor。
@MainActor private let quitOnClose = QuitOnClose()

@MainActor
private final class QuitOnClose: NSObject, NSWindowDelegate {
    /// 由 `runEditor()` 指派。**用可設定的屬性而不是 init 參數**，是為了讓上面那個
    /// 檔案層級的 `let` 留在原地：要帶 controller 就改回區域變數的話，delegate 是 weak
    /// 這件事會立刻把 phase 1 那個 bug 帶回來。
    var controller: EditorController?
    /// 同一個理由：快捷鍵那半也會 dirty，而它沒有 undo。
    var hotkeys: HotkeyEditor?
    /// 同上。格線那一頁與 `hotkeys` 寫同一個檔但是兩個 dirty，所以要**分開問**
    /// ——少問一份的症狀是那一頁未存的編輯關窗直接丟掉、零確認，而同一個視窗的
    /// 其他頁有對話框。
    var gridSettings: GridSettingsEditor?

    /// **`windowShouldClose` 不是 `windowWillClose`。** 後者發出來的時候視窗已經在關，
    /// 攔不住；前者回 false 就留在原地。沒有這一步的話「有未儲存的變更」只會在
    /// 按鈕上寫著，而關窗把它連同整個 session 一起丟掉，零確認。
    ///
    /// **每一份檔案都要問。** 只查 `controller` 的話，側欄那幾頁未存的編輯關窗就
    /// 直接不見，而 layout.json 那半有對話框——同一個視窗兩種待遇。
    func windowShouldClose(_: NSWindow) -> Bool {
        let unsaved = [controller?.isDirty == true ? "版面設定" : nil,
                       hotkeys?.isDirty == true ? "快捷鍵" : nil,
                       gridSettings?.isDirty == true ? "格線" : nil].compactMap(\.self)
        guard !unsaved.isEmpty else { return true }
        let alert = NSAlert()
        alert.messageText = "\(unsaved.joined(separator: "與"))有未儲存的變更"
        alert.informativeText = "關掉就沒了，undo 也救不回來。"
        // 第一顆是 Enter 的預設鍵，所以**破壞性的那顆不能排在前面**。這個對話框
        // 存在的唯一理由是攔下反射性的關窗，而反射性關窗之後最可能的下一個動作
        // 就是反射性按 Enter——把「捨棄」放預設，等於這道閘門對它最該防的情境
        // 完全無效。代價是想丟掉時要多移動一次滑鼠，那個不對稱是刻意的。
        alert.addButton(withTitle: "取消")
        alert.addButton(withTitle: "捨棄並關閉")
        return alert.runModal() == .alertSecondButtonReturn
    }

    func windowWillClose(_: Notification) {
        NSApplication.shared.terminate(nil)
    }
}

/// 現場的 space 清單。抽成獨立函式是 swiftlint 的 `function_body_length` 要的
/// （50 行），而 `makeController` 本來就只是一長串接線。
private func liveSpaces(_ client: any YabaiClient) -> [LiveSpace] {
    // 這裡不用 `Displays.list`：那支解的是螢幕。四個欄位直接從 `JSONValue` 挖成
    // `LiveSpace`——挖不出來的那一筆整筆略過，因為 uuid 是身分，
    // 沒有 uuid 的 space 挑了也寫不進設定。
    guard case let .array(items)? = try? client.query(.spaces) else { return [] }
    return items.compactMap { item in
        guard case let .string(uuid)? = item["uuid"],
              let index = Int(JQPrint.interpolate(item["index"] ?? .null)),
              let display = Int(JQPrint.interpolate(item["display"] ?? .null))
        else { return nil }
        return LiveSpace(uuid: uuid, index: index, display: display,
                         visible: item["is-visible"] == .bool(true))
    }
}

/// 現在開著的視窗，加上 Safari 說的當前分頁。
///
/// **Safari 那半失敗就當作沒有分頁**（`try?` → 空字串）：拿不到 dump 的時候
/// 清單仍然該列出所有視窗，只是每個都只能用 `app` 條件。整支回空陣列的話
/// 使用者連 `app` 都選不到，而那是四種裡唯一不需要 Safari 的。
///
/// id 走 `JQPrint.interpolate` 而不是 `Int`：`WindowChoice.merge` 自己會正規化，
/// 而這裡照 `liveSpaces` 的做法把 JSON 值印成字串。
private func liveWindows(_ client: any YabaiClient) -> [WindowChoice] {
    guard case let .array(items)? = try? client.query(.windows) else { return [] }
    let live: [LiveWindow] = items.compactMap { item in
        guard case let .string(app)? = item["app"] else { return nil }
        let id = JQPrint.interpolate(item["id"] ?? .null)
        guard !id.isEmpty else { return nil }
        let title: String = if case let .string(text)? = item["title"] {
            text
        } else {
            ""
        }
        return LiveWindow(id: id, app: app, title: title)
    }
    let dump = (try? SafariOsascriptClient().tabDump()) ?? ""
    return WindowChoice.merge(live, dump: dump)
}
