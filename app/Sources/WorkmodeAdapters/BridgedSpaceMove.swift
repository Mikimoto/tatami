import AppKit
import Foundation
import MachO

/// 把視窗搬到別的 space。**這是整個引擎唯一需要「非匯出符號」的地方。**
///
/// 2026-09-04 之前這裡走 `CGSMoveWindowsToManagedSpace`，而它在 macOS 27 **靜默無效**
/// ——呼叫成功、回傳正常、視窗一動也不動，等 10 秒也不動（兩種 CFArray 元素型別都試過）。
/// 同期排除的還有：
///
///   * `SLSSpaceSetCompatID` ＋ `SLSSetWindowListWorkspace`（yabai 舊 macOS 的後備路徑）
///     ——後者回 **1006 `kCGErrorNotImplemented`**；
///   * `SLSSpaceSetFrontPSN` ——回 0 但視窗不動；
///   * `-[SLSBridgedMoveWindowsToManagedSpaceOperation performWithWMBridgeDelegate]` 與
///     `-[SLSWindowManagementFallbackBridge performAsynchronousBridgedWindowManagementOperation:]`
///     ——兩個都 respond、都不動（它們要一個我們沒有的 WM bridge delegate）。
///
/// 真正在做事的是 SkyLight 的 `SLSPerformAsynchronousBridgedWindowManagementOperation`，
/// 用 lldb 掛上 yabai 實測：搬一次視窗，那一輪**只有它命中**，上面那些一個都沒有。
///
/// **它是 internal linkage**（mangled 名以 `_ZL` 開頭），所以 `dlsym` 拿不到——裸名、
/// `_ZL…`、`__ZL…`、`RTLD_DEFAULT` 四種都實測回 NULL。拿得到它的方法是自己走那個
/// 已載入映像的 Mach-O `LC_SYMTAB`：那張表含 local symbol，而 `dlsym` 只看匯出表。
/// 實測本機 SkyLight 有 33017 筆符號，走一趟找得到 `0x198bb49c0`，同一支 `dlsym` 是 NULL。
/// （這是 yabai 的做法，`src/misc/macho_dlsym.h` 的 `macho_find_symbol`。）
///
/// **不是位址算術。** 用名字在執行時解析，macOS 換版之後符號還在就照常運作、不在就
/// 回 nil 讓呼叫端降級——把位址寫死才會在更新後靜默指到別的東西。
enum BridgedSpaceMove {
    /// SkyLight 裡那支 internal 函式的 mangled 名。symtab 裡的字串帶一個 C 慣例的
    /// 前導底線，所以是兩個底線開頭。
    private static let symbol = """
    __ZL54SLSPerformAsynchronousBridgedWindowManagementOperation\
    P47SLSAsynchronousBridgedWindowManagementOperation
    """

    fileprivate typealias Perform = @convention(c) (AnyObject) -> Int64
    fileprivate typealias MsgSendInit = @convention(c) (AnyObject, Selector, CFArray, UInt64)
        -> Unmanaged<AnyObject>?

    /// 找得到那支函式與那個 ObjC 類別就回一個可用的實例，否則 nil（呼叫端降級）。
    static func make() -> BridgedSpaceMove.Mover? {
        guard let address = localSymbol(inImageSuffix: "SkyLight", named: symbol),
              let cls = NSClassFromString("SLSBridgedMoveWindowsToManagedSpaceOperation"),
              let msgSend = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "objc_msgSend")
        else { return nil }
        return Mover(perform: unsafeBitCast(address, to: Perform.self),
                     operationClass: cls,
                     msgSendInit: unsafeBitCast(msgSend, to: MsgSendInit.self))
    }

    struct Mover {
        fileprivate let perform: Perform
        fileprivate let operationClass: AnyClass
        fileprivate let msgSendInit: MsgSendInit

        /// 送出搬移。**這是非同步操作**：它只把工作排進去，呼叫端必須讓 run loop 跑一次
        /// 才會生效——實測不跑 run loop（只 `usleep`）等 3.6 秒都不動，跑了之後 20ms 內就到。
        /// 回 false ＝ 連 operation 物件都建不出來，那是這條路整個不可用。
        func send(window id: CGWindowID, toSpace space: UInt64) -> Bool {
            // 元素型別要 `kCFNumberSInt32Type`：那是 yabai 用的形狀，而這個 operation
            // 的 `windows` getter 讀回來也是這個型別。
            var raw = Int32(bitPattern: id)
            guard let number = CFNumberCreate(nil, .sInt32Type, &raw) else { return false }
            let list = [number] as CFArray
            guard let allocated = (operationClass as AnyObject)
                .perform(NSSelectorFromString("alloc"))?.takeUnretainedValue(),
                let operation = msgSendInit(allocated,
                                            NSSelectorFromString("initWithWindows:spaceID:"),
                                            list, space)?.takeUnretainedValue()
            else { return false }
            _ = perform(operation as AnyObject)
            return true
        }
    }

    /// 走已載入映像的 `LC_SYMTAB` 找符號。
    ///
    /// 與 `dlsym` 的差別只有一個但很關鍵：這張表含 **internal linkage** 的 local symbol，
    /// `dlsym` 只看得到匯出表。其餘（slide、名字比對）與 `dlsym` 同義。
    ///
    /// `__LINKEDIT` 那一段的 `vmaddr - fileoff` 是把 symtab 的**檔案位移**換算成記憶體
    /// 位址的基準；漏掉它會讀到隨機記憶體而不是符號表。
    private static func localSymbol(inImageSuffix suffix: String,
                                    named name: String) -> UnsafeMutableRawPointer?
    {
        for index in 0 ..< _dyld_image_count() {
            guard let rawPath = _dyld_get_image_name(index),
                  String(cString: rawPath).hasSuffix(suffix),
                  let header = _dyld_get_image_header(index)
            else { continue }
            let slide = _dyld_get_image_vmaddr_slide(index)
            guard let table = symbolTable(of: header, slide: slide) else { continue }
            for offset in 0 ..< table.count {
                let entry = table.symbols[offset]
                // `n_value == 0` 是未定義符號（它們也在這張表裡），跳過。
                guard entry.n_un.n_strx != 0, entry.n_value != 0 else { continue }
                guard String(cString: table.strings.advanced(by: Int(entry.n_un.n_strx))) == name
                else { continue }
                return UnsafeMutableRawPointer(bitPattern: UInt(entry.n_value) + UInt(slide))
            }
        }
        return nil
    }

    /// 一個映像的符號表位置。用具名型別而不是三元組：swiftlint 的 `large_tuple`
    /// 上限是 2，而這三個值本來就是一組東西。
    private struct SymbolTable {
        let symbols: UnsafePointer<nlist_64>
        let strings: UnsafePointer<CChar>
        let count: Int
    }

    private static func symbolTable(of header: UnsafePointer<mach_header>,
                                    slide: Int) -> SymbolTable?
    {
        var cursor = UnsafeRawPointer(header).advanced(by: MemoryLayout<mach_header_64>.size)
        var linkeditBase = 0
        var table: symtab_command?
        for _ in 0 ..< Int(header.pointee.ncmds) {
            let command = cursor.assumingMemoryBound(to: load_command.self).pointee
            if command.cmd == UInt32(LC_SEGMENT_64) {
                let segment = cursor.assumingMemoryBound(to: segment_command_64.self).pointee
                let name = withUnsafeBytes(of: segment.segname) { bytes in
                    String(cString: bytes.baseAddress!.assumingMemoryBound(to: CChar.self))
                }
                if name == SEG_LINKEDIT {
                    linkeditBase = Int(segment.vmaddr) - Int(segment.fileoff) + slide
                }
            } else if command.cmd == UInt32(LC_SYMTAB) {
                table = cursor.assumingMemoryBound(to: symtab_command.self).pointee
            }
            cursor = cursor.advanced(by: Int(command.cmdsize))
        }
        guard let table, linkeditBase != 0,
              let symbols = UnsafeRawPointer(bitPattern: linkeditBase + Int(table.symoff)),
              let strings = UnsafeRawPointer(bitPattern: linkeditBase + Int(table.stroff))
        else { return nil }
        return SymbolTable(symbols: symbols.assumingMemoryBound(to: nlist_64.self),
                           strings: strings.assumingMemoryBound(to: CChar.self),
                           count: Int(table.nsyms))
    }
}
