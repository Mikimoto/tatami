import Foundation
import WorkmodeCore
import WorkmodeDomain
import WorkmodeWire

// `__diff` 的螢幕與 space。一個子命令一支函式，由 DiffCommand.swift 的表分派。

func diffDisplayIndexForUuid(_ args: [String]) {
    guard args.count == 4 else { fail("display_index_for_uuid 需要 2 個參數", code: 2) }
    // 解析失敗回 5 而不是 1：bash 版的這支函式最後一個命令是 jq，函式的
    // 回傳值就是 jq 的 exit code，而 jq 的 runtime error 是 5（實測
    // `{"uuid":"AAA"}` 與 `not json at all` 兩種輸入 bash 都回 5）。
    // __diff 存在的唯一目的是鏡射 bash，所以連 exit code 一起鏡射；
    // 使用者面向的 displays 命令則用自己的慣例（失敗回 1）。
    //
    // 兩個真實呼叫點（workmode.sh:1125、:1331）都只看輸出字串、不看 rc，
    // 所以這個差異不影響行為——但差分 harness 比 exit code，而那個比對
    // 對別的函式是有意義的（例如 id_for_label 找不到要回 1、
    // resolve_profile 參數打錯要回 2），不該為了這裡放寬它。
    guard let displays = try? DisplaysDecoder.decode(args[3]) else { exit(5) }
    for index in Displays.indices(forUUID: args[2], in: displays) {
        print(index)
    }

    //   space_rects **永遠 rc=0**：函式的最後一個命令是第二個 jq，第一個炸掉之後它讀
    //   到空輸入，於是零次過濾、exit 0、零位元組（實測壞 JSON／根不是陣列／frame 是
    //   字串／idmap 是陣列，四種 rc 全部是 0）。
}

///   space_rects **永遠 rc=0**：函式的最後一個命令是第二個 jq，第一個炸掉之後它讀
///   到空輸入，於是零次過濾、exit 0、零位元組（實測壞 JSON／根不是陣列／frame 是
///   字串／idmap 是陣列，四種 rc 全部是 0）。
func diffVisibleSpaceOn(_ args: [String]) {
    guard args.count == 4 else { fail("visible_space_on 需要 2 個參數", code: 2) }
    guard let display = try? JSONParser.parse(args[2]) else { exit(2) }
    guard let spaces = try? JSONParser.parse(args[3]) else { exit(5) }
    do {
        if let index = try Displays.visibleSpace(on: display, in: spaces) {
            print(rawText(index))
        }
    } catch { exit(5) }
}

func diffOtherSpaceOn(_ args: [String]) {
    guard args.count == 5 else { fail("other_space_on 需要 3 個參數", code: 2) }
    guard let display = try? JSONParser.parse(args[2]) else { exit(2) }
    guard let skip = try? JSONParser.parse(args[4]) else { exit(2) }
    guard let spaces = try? JSONParser.parse(args[3]) else { exit(5) }
    do {
        if let index = try Displays.otherSpace(on: display, in: spaces, skipping: skip) {
            print(rawText(index))
        }
    } catch { exit(5) }
}

func diffMatchLocation(_ args: [String]) {
    guard args.count == 4 else { fail("match_location 需要 2 個參數", code: 2) }
    // 設定壞掉不另外分流：bash 那側 jq 吐 parse error 到 stderr、迴圈一圈都沒跑，
    // 收斂成「沒命中」rc=1，與這裡的 exit(1) 同一個觀測結果。
    guard let config = try? JSONParser.parse(args[3]),
          let name = Displays.matchLocation(connected: args[2], in: config) else { exit(1) }
    FileHandle.standardOutput.write(Data(name.utf8))
}

func diffSpaceRects(_ args: [String]) {
    guard args.count == 4 else { fail("space_rects 需要 2 個參數", code: 2) }
    guard let wins = try? JSONParser.parse(args[2]),
          let idmap = try? JSONParser.parse(args[3]),
          // `tostring` 由這一層供給：容器的 compact 形式要靠 Wire 的 writer，
          // 而 Domain 不能依賴它。
          let result = try? SpaceRects.compute(windows: wins, idmap: idmap,
                                               idText: toStringText)
    else { exit(0) }
    for window in result.dropped {
        let app = toStringText(window["app"] ?? .null)
        FileHandle.standardError.write(Data(
            "  ! 「\(app)」的視窗與另一個完全重疊（yabai stack），只存最上面那個\n".utf8
        ))
    }
    print(compactText(result.rects))

    // 視窗比對三支。收場又是三種，與上面每一組都不同：
//

    //   find_windows  未知類型與壞掉的 pattern **都是 rc=2**——前者是 bash 自己
//                 `return 2`，後者是 awk exit 2 再由 `set -o pipefail` 透出來
//                 （實測 `find_windows title-regex '(' …` 回 2）。差別只在
//                 stderr 印的是誰的訊息，而 awk 那句複製不了，所以只有未知
//                 類型那條進 stderr 的差分。
    //   current_tab_url 永遠 rc=0，沒命中就零位元組。
    //   id_for_label  命中 rc=0 但用 `printf '%s'`——**沒有結尾換行**；沒命中 rc=1。
}
