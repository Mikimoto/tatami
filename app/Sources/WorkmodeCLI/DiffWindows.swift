import Foundation
import WorkmodeCore
import WorkmodeDomain
import WorkmodeWire

// `__diff` 的視窗比對、規則與狀態檔。一個子命令一支函式，由 DiffCommand.swift 的表分派。

///   find_windows  未知類型與壞掉的 pattern **都是 rc=2**——前者是 bash 自己
///                 `return 2`，後者是 awk exit 2 再由 `set -o pipefail` 透出來
///                 （實測 `find_windows title-regex '(' …` 回 2）。差別只在
///                 stderr 印的是誰的訊息，而 awk 那句複製不了，所以只有未知
///                 類型那條進 stderr 的差分。
///   current_tab_url 永遠 rc=0，沒命中就零位元組。
///   id_for_label  命中 rc=0 但用 `printf '%s'`——**沒有結尾換行**；沒命中 rc=1。
func diffFindWindows(_ args: [String]) {
    guard args.count == 5 else { fail("find_windows 需要 3 個參數", code: 2) }
    do {
        guard let ids = try WindowMatching.findWindows(kind: args[2], value: args[3],
                                                       dump: args[4]) else { exit(0) }
        for id in ids {
            print(id)
        }
    } catch let WindowMatchError.unknownKind(kind) {
        fail("! 未知的 match 類型：\(kind)", code: 2)
    } catch {
        // awk 印的是它自己的 `illegal primary in regular expression …`，
        // 逐位元組複製不了，所以這行刻意用自己的描述並且不進 stderr 的差分。
        fail("! title-regex 的 pattern 編不起來", code: 2)
    }
}

func diffCurrentTabUrl(_ args: [String]) {
    guard args.count == 4 else { fail("current_tab_url 需要 2 個參數", code: 2) }
    if let url = WindowMatching.currentTabURL(window: args[2], dump: args[3]) {
        print(url)
    }
}

func diffIdForLabel(_ args: [String]) {
    guard args.count == 4 else { fail("id_for_label 需要 2 個參數", code: 2) }
    guard let value = WindowMatching.idForLabel(args[2], in: args[3]) else { exit(1) }
    FileHandle.standardOutput.write(Data(value.utf8))
}

func diffEscapeEre(_ args: [String]) {
    guard args.count == 3 else { fail("escape_ere 需要 1 個參數", code: 2) }
    // 不用 print：bash 那側是 `printf '%s' | sed`，輸入沒有尾端換行時
    // BSD sed 也不補一個，所以這裡補了就會差一個位元組。
    FileHandle.standardOutput.write(Data(WindowRules.escapeERE(args[2]).utf8))
}

func diffRuleForWindow(_ args: [String]) {
    guard args.count == 7 else { fail("rule_for_window 需要 5 個參數", code: 2) }
    // `jq -nc` 印 compact 再加一個換行，所以這裡用 print。
    print(compactText(WindowRules.rule(label: args[2], app: args[3], title: args[4],
                                       url: args[5], many: args[6])))
}

func diffStateGet(_ args: [String]) {
    guard args.count == 4 else { fail("state_get 需要 2 個參數", code: 2) }
    // awk 的 `END { if (v != "") print v }`：空值時**整行都不印**，不是印一個
    // 空行。所以這裡不能無條件 print("")。
    let value = StateFile.value(forKey: args[3], in: args[2])
    if !value.isEmpty {
        print(value)
    }
}

func diffStateSet(_ args: [String]) {
    guard args.count == 5 else { fail("state_set 需要 3 個參數", code: 2) }
    // 回傳值自己帶結尾換行（sort 的每一行都是換行結尾），print 會多一個。
    FileHandle.standardOutput.write(
        Data(StateFile.set(args[2], key: args[3], value: args[4]).utf8)
    )
    // 刪除（value 為空）時 bash 回 1 而不是 0：`workmode.sh:4` 開了 pipefail，
    // 而區塊最後一個命令是 `[ -n "$value" ] && printf …`，值為空時那個 AND
    // 串列回 1。內容是對的，rc 只是短路的副作用——但 __diff 要鏡射它，否則
    // 差分得替這支開一張例外清單。判斷是「空字串」而不是「假值」：實測
    // `' '` 與 `'0'` 都回 0。
    if args[4].isEmpty {
        exit(1)
    }
}
