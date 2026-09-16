import Foundation
import WorkmodeAdapters
import WorkmodeCore
import WorkmodeWire

// `workmode --save` 的 CLI 那一層。從 `main.swift` 整段搬出來（行為零變更）：
// 那個檔在 phase 3a 之後剛好 400 行，也就是 swiftlint `file_length` 的門檻，
// 而 `.swiftlint.yml` 的檔頭明文禁止調參數。`EditCommand.swift` 是同一個先例。

/// `--save` 的五種結局各自的封套。抽出來是為了讓 runSaveLayout 回到複雜度門檻內。
func printSaveEnvelope(_ outcome: SaveLayout.Outcome) {
    switch outcome {
    case let .written(path):
        print((try? JSONEnvelope.success(command: "save", data: ["layout": path])) ?? "")
    case .cancelled:
        print((try? JSONEnvelope.success(command: "save",
                                         data: ["cancelled": true])) ?? "")
    case .needsTerminal:
        print((try? JSONEnvelope.failure(command: "save", kind: "needs_terminal",
                                         message: "--save 要從終端機跑")) ?? "")
    case .rejected:
        print((try? JSONEnvelope.failure(command: "save", kind: "rejected",
                                         message: "沒有寫入 layout.json")) ?? "")
    case let .layoutUnavailable(failure):
        print((try? JSONEnvelope.failure(command: "save", kind: "layout_unavailable",
                                         message: "\(failure)")) ?? "")
    }
}

func runSaveLayout(want: String, json: Bool, scope: SaveLayout.Scope) -> Never {
    let yabai: WindowServerClient
    do {
        yabai = try WindowServerClient()
    } catch {
        if json {
            print((try? JSONEnvelope.failure(command: "save", kind: "yabai_not_found",
                                             message: "\(error)")) ?? "")
            exit(1)
        }
        fail("! \(error)", code: 1)
    }

    let paths = TatamiPaths()
    let reporter = makeReporter(json: json)
    let outcome = SaveLayout(
        yabai: yabai,
        safari: SafariOsascriptClient(),
        terminal: DevTTYTerminal(),
        files: FileManagerStore(),
        layoutPath: paths.layout,
        statePath: paths.state,
        parse: JSONParser.parse,
        renderRaw: rawText,
        // 寫回去的格式必須與 `jq .` 相同——JSONWriter 對它差分驗過，而結尾那個
        // 換行由 FileStore 補（`printf '%s\n' … | jq .` 的檔尾換行來自 jq）。
        format: JSONWriter.format,
        reporter: reporter
    ).run(want: want, scope: scope, interaction: .terminal)

    if json {
        printSaveEnvelope(outcome)
    } else if case let .layoutUnavailable(failure) = outcome {
        reportLoadFailure(failure)
    }
    // 取消是 rc=0（bash 的 `return 0`），其餘不成功一律 1。
    switch outcome {
    case .written, .cancelled: exit(0)
    default: exit(1)
    }
}
