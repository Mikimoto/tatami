import WorkmodeDomain

/// 每台螢幕頂端被 macOS 夾掉的那幾點（選單列），逐螢幕記在狀態檔裡。
///
/// **為什麼要記而不是問系統**：macOS 不讓任何視窗的 y 小於「螢幕 frame 頂端 ＋ 選單列
/// 高」，而那個高度**沒有任何 API 吐得出來**。實測 2026-09-03：display 2（BenQ）的
/// frame 是 `(1728, -1026, 3008, 1692)`（與 `yabai -m query --displays` 逐字相同），
/// 對它上面的視窗設 y = -1026，AX 讀回來是 **-996**——差 30pt。而
/// `NSScreen.visibleFrame`／`safeAreaInsets`／`auxiliaryTopLeftArea` 對兩台外接螢幕
/// **全是 0**（只有內建螢幕報 33），`NSStatusBar.system.thickness` 是 22 不是 30，
/// `defaults read com.apple.spaces spans-displays` 是 0（每台螢幕都有選單列）。
/// 所以唯一的來源是「設一次、量回來」——也就是自動校準。
///
/// 沒學到之前那一列的視窗會被誤報成 `frameRejected`，而且要等滿 `setFrame` 的輪詢
/// 預算才放棄；學到之後它精確命中、立刻返回。
enum TopInset {
    /// 狀態檔的 key：`topinset.<display uuid>`。
    static func key(display: String) -> String {
        "topinset." + display
    }

    /// 這台螢幕已經學到的 inset。沒學過、或值不是正整數，都是 0。
    ///
    /// 負值一律當成沒學過：它會把畫布往**上**推出螢幕，而那件事沒有任何訊號。
    static func learned(display: String, in state: String) -> Double {
        guard let value = Int(StateFile.value(forKey: key(display: display), in: state)),
              value > 0 else { return 0 }
        return Double(value)
    }

    /// 把這一輪量到的 inset 折進狀態檔。**每個值都與現況比對，一個都沒變就回 nil**
    /// ——回 nil 的呼叫端不寫檔，否則每跑一次 `--space` 都會動一次狀態檔的 mtime。
    ///
    /// 走 `StateFile.set`（整份重建）而不是自己接字串：追加會讓同一個 key 累積多筆，
    /// 而讀的時候只拿得到其中一筆。`CommandSubstitution.capture` 剝掉結尾換行的理由
    /// 與 `SwitchSetting.capture` 逐字相同（adapter 寫檔時會自己補一個）。
    static func writing(_ observed: [String: Double], into state: String) -> String? {
        var next = state
        var changed = false
        for display in observed.keys.sorted() {
            guard let value = observed[display] else { continue }
            let rounded = Int(value.rounded())
            guard rounded > 0, Double(rounded) != learned(display: display, in: state) else {
                continue
            }
            next = CommandSubstitution.capture(
                StateFile.set(next, key: key(display: display), value: String(rounded))
            )
            changed = true
        }
        return changed ? next : nil
    }
}
