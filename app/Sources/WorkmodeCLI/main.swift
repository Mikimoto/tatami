import Foundation
import WorkmodeAdapters
import WorkmodeCore
import WorkmodeDomain
import WorkmodeWire

/// 四種入口（外加下面那兩個真的會動視窗的）：
///   tatami __diff <函式> <參數...>   → 與 bash 逐位元組相同的原始輸出，給差分 harness
///   tatami displays --uuid X --json  → 使用者／AI 用的命令
///   tatami fmt [--json] < 檔案       → 保序重排 JSON，對照組是 `jq .`
///   tatami validate [--json] < 檔案  → 檢查設定結構，對照組是 bash 的 validate_layout
///   tatami [profile] [--json]        → 套用版面（**會搬動視窗**）
///   tatami --probe [profile] [--json]→ 只辨識，不動任何視窗
///
/// 最後兩個的第一個參數是使用者自訂的 profile 名稱，所以它與上面那些命令名共用一個
/// 位置：叫做 `displays`／`fmt`／`validate`／`__diff`／`__smoke` 的 profile 會被當成
/// 命令。bash 沒有這個問題（它的 dispatch 只認 `--*`），但那五個名字都不是中文、
/// 而 layout.json 的 profile 是「開發」「會議」這種，所以留著這個重疊比為它發明一個
/// `--profile` 旗標便宜。
///
/// 預設輸出是差分測試在守的東西，不可以為了好看而改；--json 是 bash 沒有的新表面，
/// 由 WorkmodeWireTests 的 schema 斷言守。
let args = Array(CommandLine.arguments.dropFirst())

func fail(_ message: String, code: Int32) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(code)
}

func emit(command: String, json: Bool, indices: [Int]) {
    if json {
        let line = (try? JSONEnvelope.success(command: command,
                                              data: ["indices": indices])) ?? ""
        print(line)
    } else {
        // 一行一個，與 jq -r 的串流輸出相同（含每行的結尾換行）。
        for index in indices {
            print(index)
        }
    }
}

/// `--flag <整數>`。找不到、不是整數、或後面沒有值都回 nil 讓呼叫端用預設。
///
/// 不報錯是刻意的：打錯格數的後果是「格子跟預期不一樣」，當場看得見也當場改得掉，
/// 而為它多一條錯誤路徑要多一個事件與兩個 renderer 分支。
func intFlag(_ name: String, in words: [String]) -> Int? {
    guard let position = words.firstIndex(of: name), position + 1 < words.count else {
        return nil
    }
    return Int(words[position + 1])
}

func emitError(command: String, json: Bool, kind: String, message: String) -> Never {
    if json {
        let line = (try? JSONEnvelope.failure(command: command, kind: kind,
                                              message: message)) ?? ""
        print(line)
        exit(1)
    }
    fail(message, code: 1)
}

// ---------- 套用版面與 probe ----------

/// 事件的落點。人看的與 `--json` 各一份 renderer，而「哪句話進哪個流」由事件自己決定。
///
/// 用函式而不是三元運算：`TextReporter` 是泛型的，兩個分支的具體型別不同。
func makeReporter(json: Bool) -> any Reporter {
    let sink = StandardStreams()
    if json {
        return TextReporter(renderer: JSONEventRenderer(), sink: sink)
    }
    return TextReporter(renderer: HumanEventRenderer(), sink: sink)
}

/// 早退時人看的那一句。
///
/// `.missing` 不在這裡：`LayoutLoader` 已經替它發過事件（那是 `load_layout` 自己的
/// printf）。另外三條在 bash 是 `validate_layout` 印的，所以借同一套 renderer——
/// 但 `.unparsable` 的理由文字複製不了（bash 印的是 jq 的內部錯誤訊息，而這裡的
/// parser 早在 `LayoutLoader` 裡就把錯誤吞掉了），所以那條只說「不是合法 JSON」，
/// 細節請跑 `tatami validate`。
func reportLoadFailure(_ failure: LayoutLoadFailure) {
    switch failure {
    case .missing:
        break
    case let .unreadable(path):
        FileHandle.standardError.write(Data("! 讀不到設定檔：\(path)\n".utf8))
    case .unparsable:
        FileHandle.standardError.write(
            Data("! layout.json 不是合法 JSON（用 tatami validate 看細節）\n".utf8)
        )
    case let .invalid(problems):
        FileHandle.standardError.write(Data(renderProblems(problems).utf8))
    }
}

func runSwitchSetting(argument: String, json: Bool) -> Never {
    let yabai: WindowServerClient
    do {
        yabai = try WindowServerClient()
    } catch {
        if json {
            print((try? JSONEnvelope.failure(command: "switch", kind: "yabai_not_found",
                                             message: "\(error)")) ?? "")
            exit(1)
        }
        fail("! \(error)", code: 1)
    }

    let paths = TatamiPaths()
    let reporter = makeReporter(json: json)
    let outcome = SwitchSetting(
        yabai: yabai,
        files: FileManagerStore(),
        picker: FzfPicker(),
        layoutPath: paths.layout,
        statePath: paths.state,
        parse: JSONParser.parse,
        renderRaw: rawText,
        reporter: reporter
    ).run(argument: argument)

    if json {
        switch outcome {
        case .updated:
            print((try? JSONEnvelope.success(command: "switch",
                                             data: ["state": paths.state])) ?? "")
        case .rejected:
            print((try? JSONEnvelope.failure(command: "switch", kind: "rejected",
                                             message: "沒有更新狀態檔")) ?? "")
        case let .layoutUnavailable(failure):
            print((try? JSONEnvelope.failure(command: "switch", kind: "layout_unavailable",
                                             message: "\(failure)")) ?? "")
        }
    } else if case let .layoutUnavailable(failure) = outcome {
        reportLoadFailure(failure)
    }
    guard case .updated = outcome else { exit(1) }
    exit(0)
}

switch args.first {
case "__diff":
    runDiff(args)

case "edit":
    runEditor()

case "displays":
    let json = args.contains("--json")
    guard let flagIndex = args.firstIndex(of: "--uuid"), args.count > flagIndex + 1 else {
        fail("用法：tatami displays --uuid <uuid> [--json]", code: 2)
    }
    let uuid = args[flagIndex + 1]
    let source = FileHandle.standardInput.readDataToEndOfFile()
    do {
        let displays = try DisplaysDecoder.decode(String(decoding: source, as: UTF8.self))
        emit(command: "displays", json: json,
             indices: Displays.indices(forUUID: uuid, in: displays))
    } catch {
        emitError(command: "displays", json: json,
                  kind: "not_an_array", message: "輸入不是螢幕陣列")
    }

// 兩種輸出模式並存的理由不同，不要把其中一種當成另一種的裝飾：
//
// 預設模式印的是**裸的文件**，因為它的對照組是 `jq .`——差分 harness 拿它跟
// jq 的輸出逐位元組比，多包一層封套就沒得比了。`print` 補的那個換行正好對上
// jq 的檔尾換行，所以 JSONWriter 不產生結尾換行是對的。
//

// --json 模式包封套，因為呼叫端是 AI 而不是 shell pipeline。裸模式要呼叫端
// 分辨「stdout 是文件」與「stderr 有錯、exit 非零」兩種形狀；封套讓它永遠
// parse 一行、看 ok 就好，錯誤與成功走同一條 stdout。
case "fmt":
    let json = args.contains("--json")
    // 不寫任何檔：layout.json 是使用者正在用的設定，格式化只印到 stdout。
    // 輸入從哪裡來見 `ConfigSource`——管線與重導照舊讀 stdin，tty 讀設定檔。
    guard let source = ConfigSource.read() else {
        emitError(command: "fmt", json: json, kind: "config_unreadable",
                  message: "讀不到設定檔：\(ConfigSource.configPath)")
    }
    do {
        let value = try JSONParser.parse(source)
        let formatted = JSONWriter.format(value)
        if json {
            let line = (try? JSONEnvelope.success(command: "fmt",
                                                  data: ["formatted": formatted])) ?? ""
            print(line)
        } else {
            print(formatted)
        }
    } catch {
        emitError(command: "fmt", json: json,
                  kind: "invalid_json", message: "輸入不是合法的 JSON")
    }

// 預設模式的三段輸出全在 stderr、rc=1，逐位元組對齊 bash——那是差分 harness 拿
// test_workmode.sh 的 fixture 在守的東西。--json 則把同一份問題清單放進封套，
// 讓呼叫端不必去 parse 那三種格式。
case "validate":
    // 不寫任何檔，理由與 fmt 相同：layout.json 是使用者正在用的設定。
    // 輸入從哪裡來見 `ConfigSource`。**那句「不是合法 JSON」的訊息不可以改**——
    // `tests/oracle/workmode-38.line` 凍著 bash 的 printf 原文，`swift_checks.sh:60`
    // 從那個檔挖前綴出來比對，動它兩處一起紅。這裡換的只有輸入來源。
    let json = args.contains("--json")
    guard let source = ConfigSource.read() else {
        emitError(command: "validate", json: json, kind: "config_unreadable",
                  message: "讀不到設定檔：\(ConfigSource.configPath)")
    }
    runValidate(text: source, json: json)

// 手動入口，不在任何自動化流程裡：Adapters 對真的 yabai 的唯讀 smoke。
// 見 YabaiSmoke.swift 的說明——它為什麼不能是一個單元測試。
case "__smoke":
    switch Array(args.dropFirst()) {
    case ["ports"]: runPortSmoke()
    // AX 加 SkyLight 那條路對真系統：唯讀。yabai 還在時它拿 query 當外部基準，
    // 不在就只印自己這邊的數字（2026-09-14 之後這台機器一律走後者）。
    case ["ws"]: runWindowServerSmoke()
    case let parts where parts.count == 3 && parts[0] == "snap":
        runSnapSmoke(parts[1], parts[2])
    case ["menu"]: runMenuSmoke()
    // 位置庫的探針，見 GridCommand.swift 的 doc。
    case ["zones"]: runZonesSmoke()
    // 選單列那條存檔路徑的唯一非人工入口，見 MenuActions.swift 的 doc。
    case let parts where parts.count == 2 && parts[0] == "save-all":
        runSaveAllSmoke(parts[1])
    // 螢幕名稱只有 macOS 知道（yabai 的 label 三台都是空的，2026-08-21 實測），
    // 所以它另有一支。
    case ["screens"]: runScreensSmoke()
    // 這兩支印的是**原始位元組**（沒有抬頭、沒有多餘的換行），因為它們的用途是
    // 與 bash 做 cmp；`ports` 那支印的是人讀的報告。混在一起會讓 cmp 沒得比。
    case ["safari-dump"]: runSafariDumpSmoke()
    case ["safari-script"]: runSafariScriptSmoke()
    case let parts where parts.count == 2 && parts[0] == "app-running":
        runAppRunningSmoke(app: parts[1])
    // **會真的開一個 app**（所以不在 `ports` 那一輪裡，要自己打）。它存在的理由是
    // `open -a` 失敗後那條 Spotlight 後備沒有別的地方走得到——`ports` 的 AppLauncher
    // 只測失敗路徑（成功會搶焦點），而後備的成功正是要驗的那一半。
    case let parts where parts.count == 2 && parts[0] == "app-open":
        runAppOpenSmoke(app: parts[1])
    default:
        // 這一句要與上面的 case 逐一對得上。`yabai` 與 `settings` 2026-09-14
        // 拆掉了（yabai 從這台機器移除，兩支永遠跑不起來）；`snap` 與 `save-all`
        // 本來就漏了，同日補上。
        fail("用法：tatami __smoke ports|ws|screens|safari-dump|safari-script"
            + "|menu|zones|snap <x> <y>|save-all <profile>"
            + "|app-running <名稱>|app-open <名稱>", code: 2)
    }

// bash 的 dispatch（workmode.sh:1258-1264）。`--json` 不是 bash 的旗標而是這一層的
// 新表面，所以先把它抽掉再看剩下的第一個參數——`--probe --json` 的 profile 才不會
// 變成 `--json`。
default:
    let json = args.contains("--json")
    let positional = args.filter { $0 != "--json" }
    switch positional.first {
    // **裸的 `tatami` 與 `tatami <profile>` 2026-09-07 退役。**
    //
    // 那條路徑走 `ApplyLayout`：把視窗聚集到可見的 space、把不在樹裡的視窗流放到
    // 別的 space、再用 yabai 的 bsp 命令排版。使用者的原始抱怨就是那個行為
    // （「只排得到目前的 space」「會把我沒管的視窗搬走」），而 `--space` 是相反的
    // 意圖：每個 space 各有版面、陌生視窗一概不碰。
    //
    // **刻意不做成 `--space` 的別名。** 同一個命令換一種行為，而使用者打它的時候
    // 期待的是舊的那個——那比明擺著的用法錯誤糟。
    case nil:
        // **`Tatami.app` 沒有參數就是選單列。** Finder 與 launchd 起一個 .app 時
        // 不會給任何參數，而這個執行檔同時是 CLI，所以要一個訊號分辨兩者——
        // 那個判斷在 `LaunchContext`（Core，四條測試），理由與實測寫在它的 doc 裡。
        //
        // 判的是 `args.isEmpty` 而不是 `positional.first == nil`：後者對
        // `tatami --json` 也成立，而那應該照樣落進下面的用法字串。
        let launch = LaunchContext.decide(
            bundleIdentifier: Bundle.main.bundleIdentifier,
            launchServicesIdentifier: ProcessInfo.processInfo.environment["__CFBundleIdentifier"]
        )
        if args.isEmpty, launch == .menuBarApp {
            runMenuBar()
        }
        makeReporter(json: json).report(.usageRejected)
        if json {
            print((try? JSONEnvelope.failure(command: "usage", kind: "retired_entry",
                                             message: "裸的 tatami 已退役，用 tatami --space")) ?? "")
        }
        exit(2)
    case "--probe":
        // `--probe` 後面沒有東西就是沒指定 profile。
        // **2026-09-07 起它走 `--space` 那條引擎**（`ApplyLayout` 已退役）：probe 的
        // 價值全在「它報的就是真的會用的那一份」。
        // `--probe --all` 也成立：probe 的價值是「它報的就是真的會用的那一份」，
        // 所以 `--all` 那一份也要有它自己的 probe。
        let probeRest = positional.dropFirst().filter { $0 != "--all" }
        runSpaceLayout(want: probeRest.first ?? "", json: json, launch: false, mode: .probe,
                       scope: positional.contains("--all") ? .all : .visible)
    case "--switch":
        // bash 是 `switch_setting "${2:-}"`：沒有第二個參數就是空字串＝走選單。
        runSwitchSetting(argument: positional.count > 1 ? positional[1] : "", json: json)
    case "--save":
        // bash 是 `save_layout "${2:-}"`。
        // `--all` 在這裡抽掉（與 `--space` 同一個寫法）：存**每一個有視窗的 space**，
        // 不只每個角色目前可見的那一個。
        let saveRest = positional.dropFirst().filter { $0 != "--all" }
        runSaveLayout(want: saveRest.first ?? "", json: json,
                      scope: positional.contains("--all") ? .all : .visible)
    // 視窗引擎的查詢與動作（隱藏子命令，不進 usage）。放在 `--space` 之前只是分組，
    // 它不以 `--` 開頭，所以與底下那條「不認得這個旗標」的規則無關。
    case "ws":
        runWindowServer(Array(positional.dropFirst()), json: json)
    // 排在 catch-all 之前：它以 `--` 開頭，排在後面會被吃成「不認得這個旗標」。
    case "--space":
        // `--launch` 只在這裡抽掉，不像 `--json` 那樣在最上面就從 `positional` 濾走：
        // 濾走的話 `tatami --launch`（沒有 `--space`）會變成裸的一次套用，而現在它
        // 落進底下那條「不認得這個旗標」。位置不限，`--space --launch 開發` 與
        // `--space 開發 --launch` 都吃得下。
        // `--all` 與 `--launch` 同一個處置：只在這個 case 裡抽掉。
        let rest = positional.dropFirst().filter { $0 != "--launch" && $0 != "--all" }
        runSpaceLayout(want: rest.first ?? "", json: json,
                       launch: positional.contains("--launch"), mode: .apply,
                       scope: positional.contains("--all") ? .all : .visible)
    // `menu` 進 usage。**它由 `Tatami.app` 起**（登入項，`SMAppService.mainApp`，
    // 見 `SpaceWatch.swift:88`）——AX 的授權掛在 responsible process 上，而那個身分
    // 由簽章決定；`~/.local/bin/tatami` 是指向 `.build/debug` 的 symlink、每次
    // `swift build` 都換 cdhash，所以裸執行檔留不住授權。
    //
    // 2026-09-08 之前是由 `yabai/yabairc` 檔尾那一段起的（那時 tatami 只有在 yabai
    // 起得來時才活得了）。Developer ID 簽章讓那個限制不在了，而 `yabairc` 現在
    // 一個 tatami 呼叫都沒有。
    case "menu":
        runMenuBar()
    // `grid` 進 usage（與 `--space`／`edit` 同級，它是使用者要打的東西）。
    // 格數的兩個旗標**在這裡抽掉**，與 `--launch` 同一個寫法：在最上面濾走的話
    // `tatami --columns 8` 會變成裸的一次套用而不是「不認得這個旗標」。
    case "grid":
        let rest = Array(positional.dropFirst())
        // 沒給就是 nil 而不是 6／4：那台螢幕的設定要贏過寫死的預設，而
        // `runGrid` 是唯一知道「這是哪台螢幕」的地方。
        runGrid(columns: intFlag("--columns", in: rest),
                rows: intFlag("--rows", in: rest),
                json: json)
    // 同樣是隱藏子命令：跑一個快捷鍵動作再結束。驗那 45 個動作、以及把 `skhdrc`
    // 一條一條搬過來的過渡期都要用它（見 `HotkeyCommand.swift`）。
    case "__hotkey":
        runHotkeyAction(positional.count > 1 ? positional[1] : "", json: json)
    case let first? where first.hasPrefix("--"):
        // 那句用法字串是一個事件（workmode.sh:1262 的 printf），所以走 renderer 而
        // 不是這裡的 `fail`——它是全部 60 多句話唯一的家。
        makeReporter(json: json).report(.usageRejected)
        if json {
            // 用法字串本身已經在事件流裡（`usageRejected`），封套只說結果。
            print((try? JSONEnvelope.failure(command: "usage", kind: "unknown_flag",
                                             message: "不認得這個旗標")) ?? "")
        }
        exit(1)
    // 任何其他第一個參數（含 profile 名）都落這裡。與 `case nil` 同一條理由。
    case let unknown?:
        makeReporter(json: json).report(.usageRejected)
        if json {
            print((try? JSONEnvelope.failure(command: "usage", kind: "retired_entry",
                                             message: "裸的 tatami <profile> 已退役，"
                                                 + "用 tatami --space \(unknown)")) ?? "")
        }
        exit(2)
    }
}
