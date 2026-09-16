import Foundation
import WorkmodeCore
import WorkmodeDomain

/// 假的焦點與視窗控制。
final class FakeWindowControl: WindowControl {
    var focused: String?
    private(set) var focusCalls: [String] = []
    private(set) var closeCalls: [String] = []

    init(focused: String? = "1") {
        self.focused = focused
    }

    func focusedWindow() throws -> String {
        guard let focused else { throw FakeError.unstubbed(argv: ["focusedWindow"]) }
        return focused
    }

    func focus(window: String) throws {
        focusCalls.append(window)
    }

    func close(window: String) throws {
        closeCalls.append(window)
    }
}

final class FakeShell: ShellRunner {
    private(set) var commands: [String] = []
    var failWith: Int32?

    func run(_ command: String) throws {
        commands.append(command)
        if let failWith {
            throw ShellRunnerError.commandFailed(command: command, status: failWith)
        }
    }
}

// MARK: - 畫面的 fixture

/// yabai 形狀的 `{x,y,w,h}`。四位小數是照抄 `WindowServerShape` 印的樣子——
/// 少一個欄位或改成整數字面值，`WindowScene.rect` 就解不出來，而那正是它在守的。
func frameJSON(_ originX: Double, _ originY: Double,
               _ width: Double, _ height: Double) -> JSONValue
{
    .object([JSONMember(key: "x", value: .number(String(format: "%.4f", originX))),
             JSONMember(key: "y", value: .number(String(format: "%.4f", originY))),
             JSONMember(key: "w", value: .number(String(format: "%.4f", width))),
             JSONMember(key: "h", value: .number(String(format: "%.4f", height)))])
}

func windowJSON(_ id: String, space: String, display: String, frame: JSONValue) -> JSONValue {
    .object([JSONMember(key: "id", value: .number(id)),
             JSONMember(key: "app", value: .string("App\(id)")),
             JSONMember(key: "frame", value: frame),
             JSONMember(key: "space", value: .number(space)),
             JSONMember(key: "display", value: .number(display))])
}

func displayJSON(_ index: String, uuid: String, frame: JSONValue) -> JSONValue {
    .object([JSONMember(key: "uuid", value: .string(uuid)),
             JSONMember(key: "index", value: .number(index)),
             JSONMember(key: "frame", value: frame)])
}

func spaceJSON(_ index: String, display: String, visible: Bool) -> JSONValue {
    .object([JSONMember(key: "index", value: .number(index)),
             JSONMember(key: "uuid", value: .string("uuid-\(index)")),
             JSONMember(key: "display", value: .number(display)),
             JSONMember(key: "is-visible", value: .bool(visible))])
}

/// 一組跑得動的 `WindowActions` 與它的五個 fake。
struct HotkeyRig {
    let yabai = FakeYabai()
    let server = FakeWindowServer()
    let control = FakeWindowControl()
    let shell = FakeShell()
    let files: FakeFileStore
    let reporter = FakeReporter()
    let statePath = "/tmp/tatami-test-state"
    /// balance／rotate／gaps 跳過的 app。預設空——大多數測試不關心它。
    var floatApps: [String] = []
    /// 每台螢幕的格線設定。預設空＝`stubOneDisplay` 那台 `D1` 吃 `GridConfig.defaults`，
    /// 也就是間距 8。
    var grids: [String: GridConfig] = [:]

    init(state: String = "") {
        files = FakeFileStore(files: ["/tmp/tatami-test-state": state])
    }

    var actions: WindowActions {
        WindowActions(yabai: yabai, server: server, control: control, shell: shell,
                      files: files, statePath: statePath, reporter: reporter,
                      floatApps: floatApps, grids: grids)
    }

    /// 一台 3000×1600 的螢幕、一個 space、指定的那些視窗。
    func stubOneDisplay(_ windows: [JSONValue]) {
        yabai.stubFixed(.windows, .array(windows))
        yabai.stubFixed(.displays,
                        .array([displayJSON("1", uuid: "D1",
                                            frame: frameJSON(0, 0, 3000, 1600))]))
        yabai.stubFixed(.spaces, .array([spaceJSON("1", display: "1", visible: true)]))
    }
}
