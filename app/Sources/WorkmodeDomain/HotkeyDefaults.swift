public extension HotkeyDocument {
    /// `hotkeys.json` 不存在時的整份預設：綁定抄自退役前的 `skhd/skhdrc`，
    /// float 清單是每台 Mac 都有的那一部分（凍結副本在
    /// `tests/default-float-apps.txt`，有測試逐字對帳）。
    static let defaults = HotkeyDocument(bindings: HotkeyBindings.defaults,
                                         floatApps: HotkeyBindings.defaultFloatApps)
}

public extension HotkeyBindings {
    /// balance／rotate／gaps 跳過的 app。
    ///
    /// **只放每台 Mac 都有的東西**：Apple 的系統工具（多半是面板與對話框，排進
    /// 版面沒有意義）加上 tatami 自己。
    ///
    /// 這份清單原本是退役前 `yabairc` 那 29 條 `manage=off` 的逐字副本，而那記的
    /// 是**一台特定機器裝了什麼**——大半是市售軟體。把它當成所有人的預設有兩個
    /// 問題：對沒裝的人是一份無效的清單，而對裝了的人我們等於替他做了一個他沒
    /// 表示過意見的決定。要 float 別的 app 就寫進自己的 `hotkeys.json`，
    /// 編輯器的「快捷鍵」那一頁在編它。
    ///
    /// `System Settings` 與 `系統設定` 都在——`app` 欄位給的是本地化名稱，
    /// 兩個都可能出現（CLAUDE.md 的「本地化的 app 名字」那一節）。
    static let defaultFloatApps: [String] = [
        "System Settings", "System Information", "Activity Monitor", "Calculator",
        "Disk Utility", "Archive Utility", "Installer", "Finder", "Feedback Assistant",
        "訊息", "密碼", "tatami", "系統設定",
    ]

    /// `hotkeys.json` 不存在時用的那一份，逐條抄自使用者退役前的 `skhd/skhdrc`。
    ///
    /// 抄的是**意圖**不是命令：yabai 的 bsp 動作在這條路上換成幾何近似
    /// （見 `HotkeyAction` 的 doc），而三條沒有近似物的（`toggle split`、
    /// `zoom-parent`、`toggle float` 的 float 那半）不在這裡——它們問的是
    /// 一棵我們沒有的樹。
    ///
    /// **resize 那四條刻意與 skhdrc 不同**。原本是
    /// `--resize left:-20:0 || --resize right:-20:0`（往左長，不行就往右縮），
    /// 那是 bsp 的分割線語意；`home` 與 `end` 在那個寫法下**都是變寬**。
    /// 這裡改成對稱的窄／寬／矮／高，因為沒有分割線可以推，而不對稱的版本
    /// 在幾何世界裡只是一個記不住的規則。
    static let defaults: [HotkeyBinding] = (layout + placement + movement + misc)
        .compactMap { key, action in
            guard let hotkey = Hotkey.parse(key), let action = HotkeyAction.parse(action)
            else { return nil }
            return HotkeyBinding(hotkey: hotkey, action: action)
        }

    /// 排版：套版面、格線、方向 focus 與 swap。
    private static var layout: [(String, String)] {
        [
            ("ctrl + alt + cmd - w", "apply:visible"),
            ("ctrl + alt + cmd - g", "grid-picker"),
            ("alt + cmd - left", "focus:west"),
            ("alt + cmd - right", "focus:east"),
            ("alt + cmd - up", "focus:north"),
            ("alt + cmd - down", "focus:south"),
            ("ctrl + alt + cmd - left", "swap:west"),
            ("ctrl + alt + cmd - right", "swap:east"),
            ("ctrl + alt + cmd - up", "swap:north"),
            ("ctrl + alt + cmd - down", "swap:south"),
            ("shift + alt + cmd - left", "stack:west"),
            ("shift + alt + cmd - right", "stack:east"),
            ("shift + alt + cmd - up", "stack-focus:prev"),
            ("shift + alt + cmd - down", "stack-focus:next"),
        ]
    }

    /// 位置與尺寸。
    private static var placement: [(String, String)] {
        [
            ("alt + cmd - home", "grid:2:2:0:0:1:1"),
            ("alt + cmd - end", "grid:2:2:1:1:1:1"),
            ("alt + cmd - pagedown", "grid:2:2:0:1:1:1"),
            ("alt + cmd - pageup", "grid:2:2:1:0:1:1"),
            ("ctrl + alt + cmd - space", "grid:12:12:1:1:9:9"),
            ("alt + cmd - space", "fullscreen"),
            ("ctrl + alt + cmd - home", "resize:-20:0"),
            ("ctrl + alt + cmd - end", "resize:20:0"),
            ("ctrl + alt + cmd - pageup", "resize:0:-20"),
            ("ctrl + alt + cmd - pagedown", "resize:0:20"),
        ]
    }

    /// 跨 space 與跨螢幕。
    private static var movement: [(String, String)] {
        var rows: [(String, String)] = [
            ("ctrl + cmd - left", "space:prev"),
            ("ctrl + cmd - right", "space:next"),
            ("ctrl + alt - left", "display:prev"),
            ("ctrl + alt - right", "display:next"),
        ]
        for index in 1 ... 9 {
            rows.append(("ctrl + cmd - \(index)", "space:\(index)"))
        }
        for index in 1 ... 3 {
            rows.append(("ctrl + alt - \(index)", "display:\(index)"))
        }
        return rows
    }

    /// 其餘。
    ///
    /// **內建預設裡沒有任何 `shell` 前綴的綁定**（2026-09-15 起）。那道逃生門
    /// 還在、使用者寫得出來，但預設值不能指向一個只有作者機器上才有的腳本——
    /// 全新安裝按下去是靜默失敗，而那與「這個功能壞了」分不出來。
    ///
    /// 這件事由「這個檔裡那個前綴加冒號的字面出現 0 次」守著，所以**整段刻意不寫出
    /// 那個字面**——寫了的話那個守衛從此恆為非 0，與「真的有一條」分不出來。
    ///
    /// 被拿掉的是 `cmd - f3`（跑 `~/.config/tatami/scripts/taggleShowHideDesktop.sh`
    /// 改 Finder 的 `CreateDesktop`）。它是退役的 47 條 skhdrc 綁定裡唯一搬過來
    /// 又被移除的那條，所以 `onlyTheServiceRestartAndTheAuthorsScriptHaveNoNewHome`
    /// 的清單有兩項而不是一項。已經把它落進自己 `hotkeys.json` 的人不受影響。
    private static var misc: [(String, String)] {
        [
            ("alt + cmd - backspace", "close"),
            ("alt + cmd - \\", "balance"),
            ("alt + cmd - g", "gaps"),
            ("alt + cmd - r", "rotate:ccw"),
            ("shift + alt + cmd - r", "rotate:cw"),
        ]
    }
}
