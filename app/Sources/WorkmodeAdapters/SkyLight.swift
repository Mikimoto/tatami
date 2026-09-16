// `CGDisplayCreateUUIDFromDisplayID` 住在 ColorSync 不是 CoreGraphics
// （`ScreenCatalog.swift` 是靠 AppKit 間接帶進來的，這裡直接指名）。
import ColorSync
import CoreGraphics
import Foundation

/// 窮舉這個 client 會失敗的方式。Core 不處理它們，唯一該做的事是印給人看。
public enum WindowServerFailure: Error, Equatable, Sendable, CustomStringConvertible {
    /// 沒有「輔助使用」權限。
    case notTrusted
    /// SkyLight 或 HIServices 缺這個符號——macOS 大版本升級時唯一會斷的地方。
    case symbolMissing(String)
    /// 找不到這個 window id（關掉了，或它的 app 不回應 AX）。
    case windowNotFound(String)
    /// AX 在 1 秒內沒有回應。
    case unresponsive(String)
    /// 沒有任何視窗有焦點（桌面被點到、或最前面那個 app 一個視窗都沒開）。
    case noFocusedWindow

    public var description: String {
        switch self {
        case .notTrusted:
            "沒有「輔助使用」權限。到 系統設定 → 隱私權與安全性 → 輔助使用 把 tatami（或終端機）打開。"
        case let .symbolMissing(name):
            "這個 macOS 沒有私有符號 \(name)，tatami 的視窗引擎接不上。"
        case let .windowNotFound(id):
            "找不到視窗 \(id)。"
        case let .unresponsive(id):
            "視窗 \(id) 的 app 一秒內沒有回應。"
        case .noFocusedWindow:
            "現在沒有視窗有焦點。先點一下要排的那個視窗。"
        }
    }
}

/// 私有 SkyLight 的四個符號，`dlsym` 進來。
///
/// 全部私有、全部 yabai 與 Hammerspoon `hs.spaces` 在用，多年沒斷。任一缺就建構失敗
/// 並說出名字：這是升級 macOS 之後第一個要看的地方。
struct SkyLight {
    private typealias MainConnectionID = @convention(c) () -> Int32
    private typealias CopyManagedDisplaySpaces = @convention(c) (Int32) -> CFArray?
    private typealias CopySpacesForWindows = @convention(c) (Int32, Int32, CFArray) -> CFArray?
    private typealias MoveWindowsToManagedSpace = @convention(c) (Int32, CFArray, UInt64) -> Void

    struct ManagedDisplay {
        let uuid: String
        let currentSpace: UInt64
        /// 依 mission control 順序。
        let spaces: [(id: UInt64, uuid: String)]
    }

    let connection: Int32
    private let copyManagedDisplaySpaces: CopyManagedDisplaySpaces
    private let copySpacesForWindows: CopySpacesForWindows
    private let moveWindowsToManagedSpace: MoveWindowsToManagedSpace
    /// nil ＝ 這個 macOS 沒有那支 internal 函式（或那個 ObjC 類別），`move` 降級。
    /// **不 throw**：它不在時引擎的其餘部分照常可用，只有搬 space 這一件事會失效，
    /// 而那比整支起不來好。
    private let bridged: BridgedSpaceMove.Mover?

    init() throws {
        guard let handle = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_NOW)
        else { throw WindowServerFailure.symbolMissing("SkyLight.framework") }
        func load<T>(_ name: String, as _: T.Type) throws -> T {
            guard let symbol = dlsym(handle, name) else { throw WindowServerFailure.symbolMissing(name) }
            return unsafeBitCast(symbol, to: T.self)
        }
        let mainConnection = try load("CGSMainConnectionID", as: MainConnectionID.self)
        connection = mainConnection()
        copyManagedDisplaySpaces = try load("CGSCopyManagedDisplaySpaces", as: CopyManagedDisplaySpaces.self)
        copySpacesForWindows = try load("CGSCopySpacesForWindows", as: CopySpacesForWindows.self)
        moveWindowsToManagedSpace = try load("CGSMoveWindowsToManagedSpace", as: MoveWindowsToManagedSpace.self)
        bridged = BridgedSpaceMove.make()
    }

    /// 每台螢幕與它的 space，順序就是 mission control 的順序（yabai 的 index 也這樣算）。
    ///
    /// 主螢幕的 `Display Identifier` 在某些版本是字面的 `"Main"`（yabai 有同一段特判），
    /// 換成 `CGMainDisplayID()` 的 UUID，否則與 `--displays` 的 uuid 對不起來。
    func managedDisplays() -> [ManagedDisplay] {
        guard let raw = copyManagedDisplaySpaces(connection) as? [[String: Any]] else { return [] }
        return raw.compactMap { entry in
            guard var uuid = entry["Display Identifier"] as? String,
                  let current = entry["Current Space"] as? [String: Any],
                  let currentID = (current["ManagedSpaceID"] as? NSNumber)?.uint64Value,
                  let spaces = entry["Spaces"] as? [[String: Any]]
            else { return nil }
            if uuid == "Main", let main = CGDisplayCreateUUIDFromDisplayID(CGMainDisplayID()) {
                uuid = CFUUIDCreateString(nil, main.takeRetainedValue()) as String
            }
            let list = spaces.compactMap { space -> (id: UInt64, uuid: String)? in
                guard let id = (space["ManagedSpaceID"] as? NSNumber)?.uint64Value,
                      let spaceUUID = space["uuid"] as? String else { return nil }
                return (id, spaceUUID)
            }
            return ManagedDisplay(uuid: uuid, currentSpace: currentID, spaces: list)
        }
    }

    /// 這個視窗在哪些 space（通常一個；最小化的可能是零個）。0x7 ＝ 全部種類。
    func spaces(ofWindow id: CGWindowID) -> [UInt64] {
        guard let raw = copySpacesForWindows(connection, 0x7, [NSNumber(value: id)] as CFArray) as? [NSNumber]
        else { return [] }
        return raw.map(\.uint64Value)
    }

    /// bridged 那條路可不可用。`__smoke ws` 問它——那支符號消失的症狀是「切 space
    /// 之後視窗沒跟過去」，沒有任何錯誤訊息，所以要有一個地方能主動問。
    var canMoveAcrossSpaces: Bool {
        bridged != nil
    }

    /// 搬到別的 space。**先走 bridged operation，那支才是 macOS 27 真正在動的東西**
    /// ——`CGSMoveWindowsToManagedSpace` 在這個版本呼叫成功而視窗不動（實測，見
    /// `BridgedSpaceMove` 的說明）。留著它當後備是照 yabai 的結構：舊 macOS 上
    /// bridged 那支不存在，而那時這一支是有效的。
    ///
    /// 回 false ＝ 兩條路都沒送出去。送出去**不代表搬完**：bridged 是非同步的，
    /// 呼叫端要讓 run loop 跑一次再量。
    func move(window id: CGWindowID, toSpace space: UInt64) -> Bool {
        if let bridged, bridged.send(window: id, toSpace: space) {
            return true
        }
        moveWindowsToManagedSpace(connection, [NSNumber(value: id)] as CFArray, space)
        return true
    }
}
