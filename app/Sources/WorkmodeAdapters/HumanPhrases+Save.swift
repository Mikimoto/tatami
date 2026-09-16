import Foundation
import WorkmodeCore
import WorkmodeDomain

// `--save` 的句子。26 個站點，是全部裡最大的一組，所以自己一個檔。

extension HumanEventRenderer {
    func render(saveRejection: SaveRejection) -> String {
        switch saveRejection {
        // MARK: save_layout

        //
        // 兩句**沒有結尾換行**（1160 的 label 提示與 1235 的覆寫確認）：它們是提示符，
        // 游標要停在同一行等使用者打字。1158 那句相反，格式字串**以 `\n` 開頭**。
        // workmode.sh:1071
        case .saveNeedsTerminal:
            "! --save 要從終端機跑（需要問視窗名稱與確認覆寫），不能從快捷鍵觸發。\n"
        // workmode.sh:1078
        case .saveLocationUnrecognized:
            "! 認不出這是哪個地點，不知道要存到哪裡。先用 --switch <地點> 指定。\n"
        // workmode.sh:1094
        case .saveProfileNameReserved:
            "! profile 不能叫 auto，那是 --switch 的保留字。\n"
        // workmode.sh:1095
        case let .saveProfileNameHasSpace(profile):
            "! profile 名稱不能含空白：\(profile)\n"
        }
    }

    func render(saveSurvey: SaveSurvey) -> String {
        switch saveSurvey {
        // workmode.sh:1098
        case let .saveBannerShown(location, desc, profile):
            "== 地點：\(location)（\(desc)）· 存成 profile：\(profile) ==\n"
        // workmode.sh:1118
        case let .saveDisplayNotInLayout(uuid):
            "  ! 螢幕 \(uuid) 不在 displays 裡，略過\n"
        // workmode.sh:1127
        case let .saveRoleDisplayNotConnected(role):
            "  \(role)：未接，沿用舊設定\n"
        // workmode.sh:1132
        case let .saveRoleHasNoVisibleSpace(role):
            "  ! \(role)：找不到可見的 space，沿用舊設定\n"
        // workmode.sh:1144
        case .saveNothingToStore:
            "! 這些螢幕上沒有任何可以存的視窗。\n"
        // workmode.sh:1158
        case let .saveWindowIntroduced(app, title):
            "\n  app=\(app)  標題=\(title)\n"
        // workmode.sh:1159
        case let .saveWindowPosition(role, position):
            "  \(role)  \(position)\n"
        }
    }

    func render(saveNaming: SaveNaming) -> String {
        switch saveNaming {
        // workmode.sh:1160
        case let .saveLabelPrompt(app):
            "  label（Enter=\(app)、- =不存這個視窗）> "
        // workmode.sh:1167
        case .saveLabelHasTab:
            "  ! label 不能含 tab（windows_for 用 TSV 輸出）\n"
        // workmode.sh:1171
        case let .saveLabelTaken(label):
            "  ! 「\(label)」這個名字已經有人用了，換一個\n"
        // workmode.sh:1182
        case let .saveTitleRuleIsExact(pattern):
            "  這條用標題逐字比對：^\(pattern)$ —— 標題一變就認不出來，"
                + "之後可以自己改寬鬆\n"
        }
    }

    func render(saveShaping: SaveShaping) -> String {
        switch saveShaping {
        // workmode.sh:1194
        case let .saveRoleNotSplittable(role):
            "! \(role)：這個畫面切不開成 bsp 樹（多半有視窗完全重疊或浮動視窗擋著），"
                + "不寫檔\n"
        // workmode.sh:1200
        case let .saveRoleHasNoNamedWindow(role):
            "  ! \(role)：沒有任何有名字的視窗，沿用舊設定\n"
        // workmode.sh:1209-1210（awk 印的）
        case let .saveRatioTooSmall(label, ratio):
            "  「\(label)」的比例 \(ratio) 存不下來"
                + "（設定只讓分割裡較大的那一側帶 ratio），已略過\n"
        // workmode.sh:1216
        case let .saveRoleShape(role, shape):
            "  \(role)：\(shape)\n"
        // workmode.sh:1221
        case .saveNoTreeStored:
            "! 沒有任何螢幕存得出樹，不寫檔。\n"
        // 沒有 bash 對應（2026-09-10）。其餘的存進去了，只有這一扇沒有。
        case let .saveWindowLostToOverlap(role, label):
            "  ! \(role)：「\(label)」沒能存進去（與別的視窗重疊）\n"
        }
    }

    func render(saveWriting: SaveWriting) -> String {
        switch saveWriting {
        // validate_layout 印的那整段，借 `renderProblems`——那是它唯一的家。
        case let .layoutValidationFailed(problems):
            problems.isEmpty ? "" : renderProblems(problems)
        // workmode.sh:1228
        case .saveMergedInvalid:
            "! 合併後的設定沒通過驗證（原因見上），不寫檔。\n"
        // workmode.sh:1235
        case let .saveOverwritePrompt(profile):
            "覆寫現有的「\(profile)」？[y/N] "
        // workmode.sh:1239
        case .saveCancelled:
            "取消，沒有動 layout.json。\n"
        // workmode.sh:1249
        case .saveWriteFailed:
            "! 產生新的 layout.json 失敗，原檔沒有動。\n"
        // workmode.sh:1253
        case let .saveWritten(path):
            "已寫入 \(path)。\n"
        // 沒有 bash 對應（2026-09-10）。**這句話不講位置**：它同一天稍晚就會變成
        // 假的——落點由 `RulePlacement` 決定（catch-all 前面或清單尾端），而這個
        // 事件在放位置**之前**就發出去了。位置本來也不是可行動的資訊，
        // 使用者要看的話 layout.json 上就有。
        case let .saveRuleInvented(label, match):
            "  ＋ 替「\(label)」加了規則 \(match)\n"
        case let .saveSkippedUnnamed(count):
            "  沒存：\(count) 個認不出名字的視窗（先在「視窗規則」裡替它們建規則）\n"
        // 沒有 bash 對應（2026-08-30）。量得準的只有目前可見的那幾個 space。
        case let .saveSkippedInvisibleSpaces(count):
            "沒動：這個 profile 底下另外 \(count) 個 space 的樹——切過去才量得準\n"
        }
    }
}
