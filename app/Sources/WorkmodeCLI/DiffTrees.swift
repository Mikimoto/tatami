import Foundation
import WorkmodeCore
import WorkmodeDomain
import WorkmodeWire

// `__diff` 的樹：反推、剪枝、走訪、比例。一個子命令一支函式，由 DiffCommand.swift 的表分派。

func diffMarker(_: [String]) {
    print(WorkmodeDomain.layerName)

    // 樹走訪五支。解析失敗一律 5：bash 那側每支的最後一個命令都是 jq，函式的回傳值
    // 就是 jq 的 exit code，而 jq 的 parse error 與 runtime error 都是 5（實測）。
}

/// 樹走訪五支。解析失敗一律 5：bash 那側每支的最後一個命令都是 jq，函式的回傳值
/// 就是 jq 的 exit code，而 jq 的 parse error 與 runtime error 都是 5（實測）。
func diffTreeRoot(_ args: [String]) {
    guard args.count == 3 else { fail("tree_root 需要 1 個參數", code: 2) }
    guard let node = try? JSONParser.parse(args[2]) else { exit(5) }
    do { try print(rawText(LayoutTree.representative(node))) } catch { exitLikeJQ(error) }
}

func diffTreeSeq(_ args: [String]) {
    guard args.count == 3 else { fail("tree_seq 需要 1 個參數", code: 2) }
    guard let node = try? JSONParser.parse(args[2]) else { exit(5) }
    do {
        // 邊算邊印，不是算完一份再印：jq 在 runtime error 前印出去的行留在
        // stdout 上（實測），收成陣列會讓失敗時的輸出從一行變成零行。
        try LayoutTree.splits(node) { split in
            let fields = try [split.target, split.axis, split.place].map(tsvField)
            print(fields.joined(separator: "\t"))
        }
    } catch { exitLikeJQ(error) }
}

func diffTreeRatios(_ args: [String]) {
    guard args.count == 3 else { fail("tree_ratios 需要 1 個參數", code: 2) }
    guard let node = try? JSONParser.parse(args[2]) else { exit(5) }
    do {
        // bash 是 `[.window, (.ratio | tostring)] | @tsv`——label 直接進 @tsv，
        // ratio 先 tostring 變成字串再進。兩條路徑對容器的下場相反：
        // label 是容器就報錯，ratio 是容器則印出它的 compact 形式。
        try LayoutTree.ratios(node) { leaf in
            let label = try tsvField(leaf.label)
            print(label + "\t" + JQPrint.tsvEscape(toStringText(leaf.ratio)))
        }
    } catch { exitLikeJQ(error) }
}

func diffPruneTree(_ args: [String]) {
    guard args.count == 4 else { fail("prune_tree 需要 2 個參數", code: 2) }
    // live 清單壞掉回 2 而不是 5：jq 在讀 stdin 之前就先解析 --argjson，
    // 失敗的是命令列本身（`jq: invalid JSON text passed to --argjson`）。
    // 實測「兩個參數都壞」也是 2，所以這道檢查要排在樹的解析之前。
    guard let live = try? JSONParser.parse(args[3]) else { exit(2) }
    guard let node = try? JSONParser.parse(args[2]) else { exit(5) }
    do {
        // 全剪光時 bash 印的是字面的 null，不是空輸出。
        try print(JSONWriter.format(LayoutTree.prune(node, live: live) ?? .null))
    } catch { exitLikeJQ(error) }
}

func diffReferencedLabels(_ args: [String]) {
    guard args.count == 3 else { fail("referenced_labels 需要 1 個參數", code: 2) }
    guard let trees = try? JSONParser.parse(args[2]) else { exit(5) }
    do {
        for label in try LayoutTree.referencedLabels(trees) {
            print(rawText(label))
        }
    } catch { exitLikeJQ(error) }

    // 反推與剪比例兩支。收場與樹走訪那五支相同（最後一個命令是 jq，所以解析錯誤
    // 與 runtime error 都是 5），差別只在它們印的是**一整個 JSON 值**：`jq -c`，
    // 所以要 compact 加一個換行，而切不開時印的是字面的 null 不是零位元組。

    // 反推與剪比例兩支。收場與樹走訪那五支相同（最後一個命令是 jq，所以解析錯誤
    // 與 runtime error 都是 5），差別只在它們印的是**一整個 JSON 值**：`jq -c`，
    // 所以要 compact 加一個換行，而切不開時印的是字面的 null 不是零位元組。
}

/// 反推與剪比例兩支。收場與樹走訪那五支相同（最後一個命令是 jq，所以解析錯誤
/// 與 runtime error 都是 5），差別只在它們印的是**一整個 JSON 值**：`jq -c`，
/// 所以要 compact 加一個換行，而切不開時印的是字面的 null 不是零位元組。
func diffRectsToTree(_ args: [String]) {
    guard args.count == 3 else { fail("rects_to_tree 需要 1 個參數", code: 2) }
    guard let rects = try? JSONParser.parse(args[2]) else { exit(5) }
    do { try print(compactText(RectTree.fromRects(rects))) } catch { exitLikeJQ(error) }
}

func diffTrimRatios(_ args: [String]) {
    guard args.count == 3 else { fail("trim_ratios 需要 1 個參數", code: 2) }
    guard let node = try? JSONParser.parse(args[2]) else { exit(5) }
    do { try print(compactText(RectTree.trim(node))) } catch { exitLikeJQ(error) }

    // 設定查詢六支。解析失敗一律 5，理由與樹走訪那五支相同（最後一個命令是 jq）。
//

    // 三種收場對應 bash 的三種 jq 尾巴，不要合併：
    //   `// empty` 的兩支 → nil 就**什麼都不印**（零位元組），不是印空行
    //   `join(" ")` 的三支 → 一定印一行，空清單就是一個空行
    //   `@tsv` 的那支    → 一行一條規則，邊算邊印
}
