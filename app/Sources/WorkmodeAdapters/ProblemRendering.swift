import WorkmodeDomain

// `validate_layout` 印的那段文字。住在 Adapters 而不是 CLI，因為 `save_layout`
// 也會印它（workmode.sh:1227 對合併後的設定再驗一次），而事件的 renderer 在這一層。
// 兩邊各抄一份的話，那段格式就有兩個家。

/// 一則問題的裸文字：不含 `! layout.json …` 抬頭，也不含縮排。
/// `--json` 的 `data.problems` 用的就是這個，所以呼叫端不必再剝格式。
///
/// 只是 `LayoutProblem.text` 的別名，留著是因為 `problems.map(payload)` 這個寫法
/// 有外部呼叫端（`WorkmodeCLI/main.swift:87`）。取值的那一份在 Domain——編輯器的
/// UI 也要它，而那一層不准 import 這個 module。
public func payload(_ problem: LayoutProblem) -> String {
    problem.text
}

/// 把問題清單排成 bash 的 stderr 輸出（workmode.sh:51-53 與 :96-98）。
///
/// 兩段互斥不是這裡決定的：bash 的 validate_layout 在缺欄位那段有輸出時直接
/// `return 1`，結構那段的 jq 根本不會執行。`LayoutValidator` 已經照這個語意分段
/// 回傳，所以看第一則屬於哪一類就能決定整段的格式。
public func renderProblems(_ problems: [LayoutProblem]) -> String {
    if case .missingField = problems[0] {
        // bash 是 `tr '\n' ' '`，各條用單一空白接成一行。它**沒有**結尾空白——
        // jq 的結尾換行早在 `missing=$(...)` 賦值時就被命令替換吃掉了，輪到 tr
        // 時已經沒有東西可以轉。實測 `{"home":{}}` 的輸出以 `home.windows\n` 結束。
        let joined = problems.map(payload).joined(separator: "\n")
            .replacingOccurrences(of: "\n", with: " ")
        return "! layout.json 缺欄位：\(joined)\n"
    }
    // 結構那段：抬頭一行，之後每行縮 4 格。bash 是 `sed 's/^/    /'`，縮的是**行**
    // 而不是條目，所以訊息自己含換行時每一行都會被縮——照著做，不要只縮第一行。
    var out = "! layout.json 有問題：\n"
    let body = problems.map(payload).joined(separator: "\n")
    for line in body.split(separator: "\n", omittingEmptySubsequences: false) {
        out += "    \(line)\n"
    }
    return out
}
