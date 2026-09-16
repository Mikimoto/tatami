import WorkmodeDomain

// 從終端機跑時（`Interaction.terminal`）逐個問「這個視窗要叫什麼」。
// `save_layout` 的問名字迴圈（workmode.sh:1112-1180）。
//
// 自成一檔的理由是 `type_body_length`（上限 250 行，不含註解與空行；
// `.swiftlint.yml` 的檔頭明文禁止調參數）：`SaveLayout` 的 struct body 加上放位置
// 那幾行就滿了。留在原地的是「決定走哪條路」，兩種答名字的方式各自一個檔
// ——這一支的答案來自 tty，`SaveAutoNames.swift` 那一支來自推導，
// 而兩支吐同一個 `Named` 交給同一段組樹與寫檔。

extension SaveLayout {
    /// 回 nil ＝ 中途放棄（目前只有讀不到輸入那條，bash 會把 label 當成 `-`）。
    func askForNames(unnamed rects: [JSONValue], catalog: String,
                     dump: String) -> Named?
    {
        var newRules: [NewRule] = []
        var addMap: [String: String] = [:]
        let taken = Set(labels(of: catalog).split(separator: "\n").map(String.init))

        for rect in rects where renderRaw(rect["label"] ?? .null).isEmpty {
            let id = renderRaw(rect["id"] ?? .null)
            let app = renderRaw(rect["app"] ?? .null)
            let title = renderRaw(rect["title"] ?? .null)
            // 同一個 app 有沒有多個視窗，是對「這次要存的**全部**矩形」算的：
            // 規則要能在整份總表裡分辨得出來。
            let many = rects.filter { renderRaw($0["app"] ?? .null) == app }.count > 1
            let url = app == "Safari" ? (WindowMatching.currentTabURL(window: id,
                                                                      dump: dump) ?? "") : ""

            let label = ask(about: rect, app: app, title: title, taken: taken) { name in
                newRules.contains { renderRaw($0.rule["label"] ?? .null) == name }
            }
            if label == "-" {
                continue
            }

            newRules.append(NewRule(rule: WindowRules.rule(label: label, app: app,
                                                           title: title, url: url,
                                                           many: many ? "1" : "0"),
                                    app: app))
            addMap[id] = label
            if many, url.isEmpty {
                reporter.report(.saveTitleRuleIsExact(pattern: WindowRules.escapeERE(title)))
            }
        }
        // `invented` 是空的：使用者親手打的名字不該被幾何丟掉（`splittable` 的 doc）。
        return Named(rules: newRules, labels: addMap, invented: [])
    }

    /// 問到一個可用的名字為止。`-` ＝ 這個視窗不存。
    ///
    /// `alreadyUsed` 是閉包而不是一份清單：這一輪前面幾個視窗剛拿到的名字住在
    /// 呼叫端那個 `newRules` 裡，而它每一圈都在長。
    private func ask(about rect: JSONValue, app: String, title: String,
                     taken: Set<String>,
                     alreadyUsed: (String) -> Bool) -> String
    {
        let role = renderRaw(rect["role"] ?? .null)
        while true {
            reporter.report(.saveWindowIntroduced(app: app, title: title))
            reporter.report(.saveWindowPosition(role: role, position: position(of: rect)))
            reporter.report(.saveLabelPrompt(app: app))
            // 讀不到就是 `-`：bash 的 `IFS= read -r label < /dev/tty || label='-'`。
            let answer = terminal.readLine() ?? "-"
            let label = answer.isEmpty ? app : answer
            if label == "-" {
                return label
            }
            if label.contains("\t") {
                reporter.report(.saveLabelHasTab)
                continue
            }
            if taken.contains(label) || alreadyUsed(label) {
                reporter.report(.saveLabelTaken(label: label))
                continue
            }
            return label
        }
    }
}
