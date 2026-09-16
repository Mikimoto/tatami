import SwiftUI
import WorkmodeEditorControl
import WorkmodeEditorModel

/// **label 不能當 id。** `LayoutValidator` 明文檢查「windows 的 label 重複」，
/// 代表重複是會發生的；而畸形的 entry 更是整批共用同一個投影值（缺 label 的都印
/// `null`）。三層一起列之後重複更容易發生——同一個 label 在共用層與地點層各寫一次
/// 是合法的。SwiftUI 對重複的 id 不會出聲，只會少畫或畫錯——而那幾列正是使用者
/// 開編輯器要修的。用來源順序的索引：天生唯一，而且順序本身有意義（前面的規則
/// 先認領視窗）。
///
/// 也不要寫 `extension ScopedRule: Identifiable`：那是對別的 module 的型別追加別的
/// module 的協定，Swift 6 會警告，而且那邊本來就沒有唯一的 id 可給。
/// `sheet(item:)` 要的身分。`RuleScope` 只有 `Equatable`，而 `ruleLayers` 的順序
/// 天生唯一（共用、每個地點、地點底下每個 profile），所以用它的索引當 id——
/// 與 `footer` 的 `ForEach` 用 `\.offset` 是同一個理由。
private struct WindowRuleTarget: Identifiable {
    let id: Int
    let scope: RuleScope
}

private struct IndexedRule: Identifiable {
    let id: Int
    let rule: ScopedRule
}

/// 一格可編輯的文字。**本地緩衝 ＋ `onSubmit`／失焦才提交**：直接繫結到
/// `controller.edit` 的話，每敲一個字就是一步 undo，50 步歷史打三個字就滿。
/// 代價是**沒有按 Enter 也沒有離開那一格時，改的字不會進 undo 也不會標 dirty**
/// ——Task 7 的人工驗收有一項在測這個。
///
/// 提交前比對 `initial`，只在真的改了才呼叫：光用 Tab 掃過一列四格不該是四次提交。
///
/// **提交被拒絕就把緩衝退回 `initial`。** `commit` 回 false ＝ 那次編輯沒有生效
/// （`EditorController.edit`，路徑走不通時 `RuleEdit` 回原文件不變），而這一格的
/// `initial` 於是也沒變、`onChange(of: initial)` 不會觸發——不自己退的話畫面上留著
/// 使用者打的字，檔案裡卻什麼都沒有，而且他要到存檔（或下次開啟）才會發現。
///
/// 退回緩衝**只負責「畫面不說謊」這一半**；為什麼不生效由
/// `EditorController.lastRejection` 講（`EditorWindow` 接到 alert）。這一格不自己
/// 湊那句話：措辭與「該不該出聲」都是判斷，而這一層零測試。
private struct EditableCell: View {
    let initial: String
    /// 回 false ＝ 這次編輯沒生效，緩衝要退回去。
    let commit: (String) -> Bool

    @State private var text: String = ""
    @FocusState private var focused: Bool

    var body: some View {
        TextField("", text: $text)
            .textFieldStyle(.plain)
            .focused($focused)
            .onAppear { text = initial }
            // 外面改了（undo、別格的編輯讓整份文件重畫）就跟上，但**正在編的那一格
            // 不跟**：跟了會把使用者打到一半的字換掉。
            .onChange(of: initial) { _, new in
                if !focused {
                    text = new
                }
            }
            .onSubmit { submit() }
            .onChange(of: focused) { _, isFocused in
                if !isFocused {
                    submit()
                }
            }
    }

    private func submit() {
        guard text != initial else { return }
        if !commit(text) {
            text = initial
        }
    }
}

/// 檔案裡的全部視窗規則，可以編。
///
/// 這一層**沒有任何測試驗得到**（`DependencyRuleTests` 的三條禁令就是為了讓判斷
/// 寫不進來），所以每個「能不能按」的條件都取自 Model 的投影，不在這裡自己算：
/// 新增看 `LayoutDocument.canInsertRule`、往下搬看 `ruleLayers` 的 `ruleCount`。
struct RuleTableView: View {
    let controller: EditorController
    let document: LayoutDocument

    /// 表格自己的選取，只管那一列反白。與側欄的選取無關——側欄選中「視窗規則」時
    /// 它不指向任何一層。**新增不看它**：加到哪一層由選單明講（見 `footer`）。
    @State private var selected: Int?

    /// 「從視窗建立」要開在哪一層。**一個 Optional 而不是 `Bool` 加一個 scope**：
    /// 兩個 `@State` 分開設的話，SwiftUI 在「開起來」的那一幀未必已經看到第二個，
    /// 內容就會是空的。
    @State private var fromWindow: WindowRuleTarget?

    private var indexed: [IndexedRule] {
        document.allRules.enumerated().map { IndexedRule(id: $0.offset, rule: $0.element) }
    }

    /// 拒絕新增的理由，依 scope 分歧——**三句現在都到得了**。選單列的是
    /// `document.ruleLayers`（每一層各一項，包含一列都沒有的層），所以任何一層的
    /// `windows` 不是陣列時，那一項就是灰的、拿這句話當提示。
    ///
    /// profile 那句是**最常見**的：使用者那份設定三個 profile 全都沒有 `windows`，
    /// 選單一打開就有三個灰項目。
    ///
    /// 三句的差別是實測來的：profile 層有 `windows` 會**取代**共用層與地點層，
    /// 地點層是**疊加**（`LayoutQuery.swift:114-122`），所以只有 profile 那句能講失效。
    private static func refusal(for scope: RuleScope) -> String {
        switch scope {
        case .shared:
            "最外層的 windows 不是陣列（缺這個鍵，或它是別的型別）。這裡不替它決定要"
                + "變成什麼，先把 layout.json 改成陣列，新增才有地方接。"
        case .location:
            "這個地點沒有 windows 陣列，編輯器不替它建一個。"
        case .profile:
            "這個 profile 沒有 windows 陣列。替它建一個會讓共用層與地點層的規則"
                + "在這個 profile 底下整組失效，所以這裡不做。"
        }
    }

    /// scope 變成文字只在這一層做：Model 一個字都不格式化（與 `WorkmodeCore` 同一條）。
    private static func source(of scope: RuleScope) -> String {
        switch scope {
        case .shared: "共用"
        case let .location(location): location
        case let .profile(location, profile): "\(location) ▸ \(profile)"
        }
    }

    /// 這一層最後一列的索引。`movingRule` 的 `to` 是**移除之後**的目標索引，越界時
    /// `JSONPath.move` 丟出來、`RuleEdit` 吞掉回原文件——按鈕可按卻沒反應，正是這一層
    /// 零測試最怕的那種。清點走 `ruleLayers`（每層各一列）而不是數 `allRules`：
    /// 後者裡沒有列的層根本不存在，而那正好是 `ruleCount == 0` 要講的事。
    private func lastIndex(in scope: RuleScope) -> Int {
        (document.ruleLayers.first { $0.scope == scope }?.ruleCount ?? 0) - 1
    }

    var body: some View {
        VStack(spacing: 0) {
            table
            Divider()
            footer
        }
    }

    private var table: some View {
        Table(indexed, selection: $selected) {
            TableColumn("來源") { Text(Self.source(of: $0.rule.scope)) }
                .width(min: 90, ideal: 110)
            TableColumn("label") { cell($0, .label, $0.rule.row.label) }
            TableColumn("類型") { cell($0, .matchKind, $0.rule.row.matchKind) }
            TableColumn("值") { cell($0, .matchValue, $0.rule.row.matchValue) }
            TableColumn("fallback") { fallbackCell($0) }
                .width(min: 180, ideal: 220)
            // **一個空的輸入框就夠，不像 fallback 需要「新增」按鈕。** fallback 是
            // 一個兩元素陣列，兩格都 nil 時給空框會讓人以為那條規則已經有 fallback；
            // `launch` 只有一個值，而空框就是「沒設」的正確樣子。清掉它的方法是打成
            // 空的——那一步在 `settingRuleField` 裡是**刪掉整個鍵**。
            TableColumn("launch") { cell($0, .launch, $0.rule.row.launch ?? "") }
                .width(min: 90, ideal: 120)
            TableColumn("") { actions($0) }
                .width(96)
        }
    }

    /// **這是唯一走 `edit` 的站點**，因為只有它有本地緩衝要對帳；六個按鈕走 `apply`
    /// （沒有東西要退，拒絕的說明統一由 `lastRejection` 出聲）。
    private func cell(_ item: IndexedRule, _ field: RuleField, _ value: String) -> some View {
        EditableCell(initial: value) { text in
            controller.edit {
                $0.settingRuleField(item.rule.scope, index: item.rule.index,
                                    field: field, to: text)
            }
        }
    }

    /// **兩格都是 nil 時給一個按鈕，不是兩個空輸入框。** `nil` 與空字串在檔案裡是
    /// 兩件事（`nil` ＝ 沒有這個鍵，`RuleRow` 看的就是鍵在不在），空框會讓使用者
    /// 以為那條規則已經有 fallback 了。
    ///
    /// 反向的「✕」也在這裡：`addingFallback` 有入口而 `removingFallback` 沒有的話，
    /// 那個按鈕是一扇單向門——把兩格清空並不會把鍵拿掉，使用者退不回去。
    @ViewBuilder private func fallbackCell(_ item: IndexedRule) -> some View {
        if let kind = item.rule.row.fallbackKind, let value = item.rule.row.fallbackValue {
            HStack(spacing: 4) {
                cell(item, .fallbackKind, kind)
                cell(item, .fallbackValue, value)
                Button {
                    controller.apply {
                        $0.removingFallback(item.rule.scope, index: item.rule.index)
                    }
                } label: {
                    Image(systemName: "xmark.circle")
                }
                .buttonStyle(.borderless)
                .help("拿掉 fallback：整個鍵刪掉，不是設成空字串")
            }
        } else {
            Button("＋ fallback") {
                controller.apply { $0.addingFallback(item.rule.scope, index: item.rule.index) }
            }
            .buttonStyle(.borderless)
        }
    }

    private func actions(_ item: IndexedRule) -> some View {
        let index = item.rule.index
        return HStack(spacing: 2) {
            Button {
                controller.apply {
                    $0.movingRule(item.rule.scope, from: index, to: index - 1)
                }
            } label: {
                Image(systemName: "arrow.up")
            }
            .disabled(index <= 0)
            Button {
                controller.apply {
                    $0.movingRule(item.rule.scope, from: index, to: index + 1)
                }
            } label: {
                Image(systemName: "arrow.down")
            }
            .disabled(index >= lastIndex(in: item.rule.scope))
            Button {
                // 走 controller 而不是 `apply { $0.deletingRule(...) }`：
                // 這個動作要在連帶拿掉窗格時出聲，而那個判斷不能寫在零測試的這一層。
                controller.deleteRule(item.rule.scope, index: index)
            } label: {
                Image(systemName: "minus")
            }
        }
        .buttonStyle(.borderless)
    }

    /// 新增那一列。**加到哪一層是選的，不是猜的**：原本用表格的選取推測（選到哪一列
    /// 就加到那一層，沒選就共用層），於是沒有列的層永遠選不到——`canInsertRule` 的
    /// false 分支到不了，`refusal(for:)` 三句只有一句會出現。選單列 `ruleLayers`，
    /// 那支連一列都沒有的層也列，所以每一層都到得了。
    ///
    /// 用 `enumerated()` 當 id 而不是 `\.scope`：`RuleScope` 只有 `Equatable`，而
    /// `ruleLayers` 的順序天生唯一（共用、每個地點、地點底下每個 profile）。
    private var footer: some View {
        let layers = Array(document.ruleLayers.enumerated())
        return HStack(spacing: 8) {
            Menu("＋ 新增規則") {
                ForEach(layers, id: \.offset) { _, layer in
                    insertItem(layer)
                }
            }
            .fixedSize()
            Menu("＋ 從視窗建立…") {
                ForEach(layers, id: \.offset) { index, layer in
                    fromWindowItem(index, layer)
                }
            }
            .fixedSize()
            Text(verbatim: "選一層加進去。灰掉的那層沒有 windows 陣列，理由在它的提示裡。")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            removeButton
        }
        .padding(8)
        // **sheet 而不是 popover。** 掛在 footer 上的 popover 由 `Menu` 的項目觸發時
        // **完全不會出現**（2026-08-29 人工實測）：`Menu` 自己也是一層 overlay，
        // 它關閉的時候把剛要開的那個 popover 一起收掉了。sheet 是獨立的 modal，
        // 不受那個時機影響，而這個表單的內容（清單加條件）本來也比 popover 適合。
        .sheet(item: $fromWindow) { target in
            AddRuleFromWindowForm(
                controller: controller, scope: target.scope,
                isPresented: Binding(get: { fromWindow != nil },
                                     set: {
                                         if !$0 {
                                             fromWindow = nil
                                         }
                                     })
            )
        }
    }

    /// 選到的那一列。**越界要擋**：`selected` 是 `allRules` 的扁平索引而它是
    /// view 的狀態，刪掉一列之後那個索引指向的已經是別人——不擋的話下一次
    /// Backspace 刪的是使用者沒有選的規則，而畫面上零訊號。
    private var selectedRule: ScopedRule? {
        guard let selected, document.allRules.indices.contains(selected) else {
            return nil
        }
        return document.allRules[selected]
    }

    /// 刪掉選到的規則。
    ///
    /// **走按鈕的 `keyboardShortcut` 而不是 `.onKeyPress`**（與畫布那顆同一條）：
    /// 後者要那個 view 拿到 SwiftUI 的鍵盤焦點，而 `.focusable()` ＋ `@FocusState`
    /// 在這個環境拿不到 first responder（2026-08-28 人工實測兩輪都是按了沒反應）。
    ///
    /// **裸的 Backspace 在表格裡打字時不會誤刪**：AppKit 的 key equivalent 先給
    /// first responder，`EditableCell` 的 `TextField` 吃掉那個鍵就不再往下傳
    /// （畫布那顆在 2026-08-28 實測過同一件事）。**改動這一行要重驗**——它的失敗
    /// 樣子是「刪掉一個字元的同時那一列也不見了」，而使用者不會把兩件事連起來。
    ///
    /// 走 `controller.deleteRule` 而不是 `apply { $0.deletingRule(...) }`：
    /// 這個動作要在連帶拿掉窗格時出聲，而那個判斷不能寫在零測試的這一層。
    private var removeButton: some View {
        Button("移除規則") {
            if let rule = selectedRule {
                controller.deleteRule(rule.scope, index: rule.index)
                // 索引失效了，留著下一次會刪到別人。
                selected = nil
            }
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .keyboardShortcut(.delete, modifiers: [])
        .disabled(selectedRule == nil)
        .help(selectedRule == nil
            ? "先點一列，再按這裡或 Backspace"
            : "移除選到的規則（Backspace）")
    }

    /// 「從視窗建立」的一層。守衛與 `insertItem` 共用 `canInsertRule`——
    /// 兩個入口對同一層給不同答案的話，使用者會以為其中一個壞了。
    private func fromWindowItem(_ index: Int, _ layer: RuleLayer) -> some View {
        let allowed = document.canInsertRule(layer.scope)
        return Button {
            fromWindow = WindowRuleTarget(id: index, scope: layer.scope)
        } label: {
            Text(verbatim: "\(Self.source(of: layer.scope))（\(layer.ruleCount)）")
        }
        .disabled(!allowed)
        .help(allowed ? "挑一個現在開著的視窗，條件自動填好。"
            : Self.refusal(for: layer.scope))
    }

    /// 選單裡的一層：層名加上它現在有幾列。**拒絕的時候要講出理由**——一個沒有反應
    /// 也沒有說明的灰項目，與「壞掉了」在畫面上分不出來。
    private func insertItem(_ layer: RuleLayer) -> some View {
        let allowed = document.canInsertRule(layer.scope)
        return Button {
            controller.apply { $0.insertingRule(layer.scope) }
        } label: {
            // 組出來的 `String` 明寫 `verbatim:`，與 `EditorWindow` 同一條：
            // 不寫它照樣編得過，只是走 `LocalizedStringKey` 那條 init。
            Text(verbatim: "\(Self.source(of: layer.scope))（\(layer.ruleCount)）")
        }
        .disabled(!allowed)
        .help(allowed ? "在這一層的最後面加一條新規則。" : Self.refusal(for: layer.scope))
    }
}
