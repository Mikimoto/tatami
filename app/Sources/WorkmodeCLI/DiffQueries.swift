import Foundation
import WorkmodeCore
import WorkmodeDomain
import WorkmodeWire

// `__diff` 的設定查詢：驗證、地點、profile、放逐、視窗清單。一個子命令一支函式，由 DiffCommand.swift 的表分派。

func diffValidate(_ args: [String]) {
    // bash 的 validate_layout 吃的是參數而不是 stdin，差分 harness 的 run_pair
    // 也是傳參數的，所以這裡跟著吃參數；使用者面向的 validate 則讀 stdin。
    // bash 三條失敗路徑一律 return 1，成功 return 0，所以沒有 5 那種例外。
    guard args.count == 3 else { fail("validate 需要 1 個參數", code: 2) }
    runValidate(text: args[2], json: false)

    // 樹走訪五支。解析失敗一律 5：bash 那側每支的最後一個命令都是 jq，函式的回傳值
    // 就是 jq 的 exit code，而 jq 的 parse error 與 runtime error 都是 5（實測）。

    // 三種收場對應 bash 的三種 jq 尾巴，不要合併：
    //   `// empty` 的兩支 → nil 就**什麼都不印**（零位元組），不是印空行
    //   `join(" ")` 的三支 → 一定印一行，空清單就是一個空行
    //   `@tsv` 的那支    → 一行一條規則，邊算邊印
}

/// 三種收場對應 bash 的三種 jq 尾巴，不要合併：
///   `// empty` 的兩支 → nil 就**什麼都不印**（零位元組），不是印空行
///   `join(" ")` 的三支 → 一定印一行，空清單就是一個空行
///   `@tsv` 的那支    → 一行一條規則，邊算邊印
func diffLocationDesc(_ args: [String]) {
    guard args.count == 4 else { fail("location_desc 需要 2 個參數", code: 2) }
    guard let config = try? JSONParser.parse(args[3]) else { exit(5) }
    do {
        if let desc = try LayoutQuery.locationDescription(args[2], in: config) {
            print(rawText(desc))
        }
    } catch { exitLikeJQ(error) }
}

func diffLocationDisplay(_ args: [String]) {
    guard args.count == 5 else { fail("location_display 需要 3 個參數", code: 2) }
    guard let config = try? JSONParser.parse(args[4]) else { exit(5) }
    do {
        if let uuid = try LayoutQuery.locationDisplay(args[2], role: args[3], in: config) {
            print(rawText(uuid))
        }
    } catch { exitLikeJQ(error) }
}

func diffLocationNamesFrom(_ args: [String]) {
    guard args.count == 3 else { fail("location_names_from 需要 1 個參數", code: 2) }
    guard let config = try? JSONParser.parse(args[2]) else { exit(5) }
    do { try print(LayoutQuery.locationNames(in: config)) } catch { exitLikeJQ(error) }
}

func diffProfileNamesIn(_ args: [String]) {
    guard args.count == 4 else { fail("profile_names_in 需要 2 個參數", code: 2) }
    guard let config = try? JSONParser.parse(args[3]) else { exit(5) }
    do {
        try print(LayoutQuery.profileNames(inLocation: args[2], in: config))
    } catch { exitLikeJQ(error) }
}

func diffExileFor(_ args: [String]) {
    guard args.count == 5 else { fail("exile_for 需要 3 個參數", code: 2) }
    guard let config = try? JSONParser.parse(args[4]) else { exit(5) }
    do {
        try print(LayoutQuery.exile(location: args[2], profile: args[3], in: config))
    } catch { exitLikeJQ(error) }
}

func diffWindowsFor(_ args: [String]) {
    guard args.count == 5 else { fail("windows_for 需要 3 個參數", code: 2) }
    guard let config = try? JSONParser.parse(args[4]) else { exit(5) }
    do {
        // 邊算邊印，理由與 tree_seq 相同：jq 在 runtime error 前印出去的行留在
        // stdout 上（實測 label 是物件時第一行照樣印出來才 rc=5）。
        try LayoutQuery.windowRules(location: args[2], profile: args[3], in: config) { rule in
            let fields = try [rule.label, rule.matchKind, rule.matchValue,
                              rule.fallbackKind, rule.fallbackValue].map(tsvField)
            print(fields.joined(separator: "\t"))
        }
    } catch { exitLikeJQ(error) }

    // profile 的解析與合併兩支。這兩支的收場與上面全部不同，三個都要留意：
//

    //   resolve_profile 印的是 `printf '%s\t%s\t%s'`——**沒有結尾換行**，所以不能用
    //   print；它的失敗是 rc=2（命令列參數打錯字），而設定壞掉不算失敗。
    //   merge_profile 的 `--argjson` 壞掉是 rc=2、stdin 的 JSON 壞掉才是 rc=5。

    //   resolve_profile 印的是 `printf '%s\t%s\t%s'`——**沒有結尾換行**，所以不能用
    //   print；它的失敗是 rc=2（命令列參數打錯字），而設定壞掉不算失敗。
    //   merge_profile 的 `--argjson` 壞掉是 rc=2、stdin 的 JSON 壞掉才是 rc=5。
}

///   resolve_profile 印的是 `printf '%s\t%s\t%s'`——**沒有結尾換行**，所以不能用
///   print；它的失敗是 rc=2（命令列參數打錯字），而設定壞掉不算失敗。
///   merge_profile 的 `--argjson` 壞掉是 rc=2、stdin 的 JSON 壞掉才是 rc=5。
func diffResolveProfile(_ args: [String]) {
    guard args.count == 6 else { fail("resolve_profile 需要 4 個參數", code: 2) }
    // 解析失敗不回 5：bash 那側整份設定是餵給兩個 jq 呼叫的，解析失敗時兩者都
    // 吐零位元組而 rc 沒人檢查，於是收斂成 `\tfirst\t` rc=0——與「設定是 null」
    // 觀測上相同（實測 `nope` 與 `null` 兩種輸入 bash 都印 `\tfirst\t` rc=0，
    // 差分語料兩條都放了）。
    let profileConfig = (try? JSONParser.parse(args[5])) ?? JSONValue.null
    do {
        let choice = try ProfileResolution.resolve(
            location: args[2], want: args[3], state: args[4],
            in: profileConfig, renderRaw: rawText
        )
        let line = "\(choice.name)\t\(choice.source.rawValue)\t\(choice.ignoredMemory)"
        FileHandle.standardOutput.write(Data(line.utf8))
    } catch let error as ProfileResolutionError {
        guard case let .unknownProfile(want, location, available) = error else {
            fail("resolve_profile 失敗", code: 2)
        }
        fail("! 「\(want)」不是 \(location) 底下的 profile。可用的有：\(available)",
             code: 2)
    } catch {
        exitLikeJQ(error)
    }
}

func diffMergeProfile(_ args: [String]) {
    guard args.count == 7 else { fail("merge_profile 需要 5 個參數", code: 2) }
    // 兩個 --argjson 先驗，理由與 prune_tree 那條相同：jq 在讀 stdin 之前就先
    // 解析命令列，失敗的是命令列本身而不是過濾器（實測「argjson 與 stdin 都壞」
    // 也是 2）。所以這道檢查要排在設定的解析之前。
    guard let newTrees = try? JSONParser.parse(args[5]) else { exit(2) }
    guard let newRules = try? JSONParser.parse(args[6]) else { exit(2) }
    guard let base = try? JSONParser.parse(args[2]) else { exit(5) }
    do {
        try print(JSONWriter.format(ProfileMerge.merge(
            base, location: args[3], profile: args[4],
            trees: newTrees, rules: newRules
        )))
    } catch { exitLikeJQ(error) }

    // 螢幕與 space 四支。收場三種都不同，不要照著上面幾組的直覺套：
//
    //   visible_space_on／other_space_on 的 `--argjson` 壞掉是 rc=2、spaces 壞掉才是
    //   rc=5（實測「兩個都壞」也是 2，所以 argjson 要先驗）。
//
    //   match_location 只回 0 或 1：jq 的錯誤只印到 stderr，函式照樣把已收到的行跑完
    //   再 `return 1`。而且它印的是 `printf '%s'`——**沒有結尾換行**。
//

    //   space_rects **永遠 rc=0**：函式的最後一個命令是第二個 jq，第一個炸掉之後它讀
    //   到空輸入，於是零次過濾、exit 0、零位元組（實測壞 JSON／根不是陣列／frame 是
    //   字串／idmap 是陣列，四種 rc 全部是 0）。
}
