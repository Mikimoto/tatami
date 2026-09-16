import SwiftUI
import WorkmodeDomain
import WorkmodeEditorControl
import WorkmodeEditorModel

/// 一格帶本地緩衝的文字欄。與 `RuleTableView` 的 `EditableCell` 是同一個形狀，理由
/// 也同一條：直接繫結的話每敲一個字就是一步 undo，50 步歷史打三個字就滿；而提交被拒
/// （`commit` 回 false）要把緩衝退回 `initial`，否則畫面上留著使用者打的字而檔案裡
/// 什麼都沒有。
///
/// **這是第二份。** 那一個是 `RuleTableView.swift` 的 private 型別，而 Task 5 不准動
/// 那個檔；兩份要一起改。抽成共用型別是 Task 6 動那個檔時順手的事。
private struct BufferedField: View {
    let prompt: String
    let initial: String
    /// 回 false ＝ 這次編輯沒生效，緩衝要退回去。
    let commit: (String) -> Bool

    @State private var text: String = ""
    @FocusState private var focused: Bool

    var body: some View {
        TextField(prompt, text: $text)
            .focused($focused)
            .onAppear { text = initial }
            // 外面改了（undo、別處的編輯讓整份文件重畫）就跟上，但**正在編的那一格
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

/// 從現在接著的螢幕挑一個 UUID 填進去。
///
/// **旁邊那個文字欄不會因此消失。** 手打是這之前唯一的路，而清單空的時候（沒有
/// yabai，或真的一台都沒查到——`EditorController.connectedDisplays()` 兩種都回空陣列）
/// 它還是唯一的路，所以挑選器是多一條路不是取代。
///
/// 項目裡那個編號是 **yabai 的螢幕編號**，不是 `displays` 裡的角色名：角色名是使用者
/// 自己取的，`main` 不一定是 1 號。所以這支只回 UUID，角色名一個字都不碰。
///
/// **住在這個檔而不是自己一個檔**：`EditorWindow` 的新增地點表單也要用它，而同一個
/// module 內 internal 就跨得過去（`private` 不行——`ApplyButton.swift` 的檔頭記著那次
/// 實測）。`id` 用 `index` 而不是 `uuid`：yabai 的編號在一次查詢裡不重複，而兩台螢幕
/// 回同一個 UUID 時 `ForEach` 的 id 撞掉會讓其中一列畫不出來。
struct DisplayPickerMenu: View {
    let displays: [DisplayChoice]
    /// 收 UUID 的那一端。回 Void：這裡沒有「被拒絕」的概念，設 UUID 的動作
    /// （`settingDisplayUUID`）永遠會生效。
    let choose: (String) -> Void

    private var help: String {
        displays.isEmpty
            ? "查不到螢幕清單（yabai 沒接上）"
            : "從現在接著的螢幕挑一個，UUID 會填進左邊那一格。"
    }

    /// **名稱查不到就退回 UUID**，不是留一個只有編號的空殼：`DisplayChoice.merge`
    /// 刻意讓 macOS 認不得的螢幕留在清單上（濾掉的話使用者就選不到那台，而畫面上
    /// 看不出少了什麼），所以這條退路一定要有東西可以認。
    ///
    /// 這一支寫在 UI 是因為它只是把三個欄位拼成一句話——`DisplayChoice` 已經把
    /// 「查不查得到」表示成 `name` 的 Optional 了，這裡沒有第二個判斷。
    private func label(for display: DisplayChoice) -> String {
        guard let name = display.name else {
            return "顯示器 \(display.index) — \(display.uuid)"
        }
        guard let size = display.size else {
            return "顯示器 \(display.index) — \(name)"
        }
        return "顯示器 \(display.index) — \(name)（\(size)）"
    }

    var body: some View {
        Menu {
            ForEach(displays, id: \.index) { display in
                Button {
                    choose(display.uuid)
                } label: {
                    Text(verbatim: label(for: display))
                }
                // **UUID 不藏起來**：寫進 `layout.json` 的是它不是名字，使用者拿檔案
                // 對帳時要看得到。名字進標籤、UUID 進 tooltip——反過來就等於要他背
                // 一串 36 個字元去分辨三台螢幕，那正是這個 task 要修的事。
                .help(display.uuid)
            }
        } label: {
            Image(systemName: "display")
        }
        .menuStyle(.borderlessButton)
        .frame(width: 42)
        .disabled(displays.isEmpty)
        .help(help)
    }
}

/// 一個地點自己的面板：名稱、說明、螢幕角色、以及底下的 profile。
///
/// 這一層**沒有任何測試驗得到**（`DependencyRuleTests` 的三條禁令就是為了讓判斷寫
/// 不進來），所以每個「能不能按」都取自 Model 的守衛，不在這裡自己算：刪角色看
/// `displayRoleRemovalRefusal`、刪 profile 看 `profileDeletionRefusal`、名稱合不合法
/// 看 `locationNameRefusal`／`profileNameRefusal`（它們自己再去問 `LayoutName`），
/// desc 的投影看 `locationDesc`。
///
/// **被拒絕的理由就地顯示（橘字）而不是走 `controller.lastRejection`。** 那個欄位只有
/// `EditorController.edit` 在「文件沒變」時會設，措辭固定講的是「這一列不是編輯器認得
/// 的形狀」——把名稱撞名硬塞進那個 alert 等於告訴使用者一件假的事，而 controller 也
/// 沒有讓外面塞訊息的入口。
struct LocationView: View {
    let controller: EditorController
    let document: LayoutDocument
    let location: String
    /// 改名成功之後側欄的選取要跟著換：選取是 `EditorWindow` 的狀態，而它記的是
    /// 舊名字。不通知的話畫面會停在一個已經不存在的地點上。
    let onRenamed: (String) -> Void

    @State private var nameProblem: String?
    @State private var roleProblem: String?
    @State private var profileProblem: String?
    @State private var newRole = ""
    @State private var newRoleUUID = ""
    @State private var newProfile = ""
    /// 現在接著的螢幕，**查一次記下來**。`controller.connectedDisplays()` 會叫
    /// `yabai -m query --displays`（一次 `Process`），寫在 body 裡等於每次重畫都
    /// 生一個子行程，而重畫是每一步編輯與每次 undo 都會發生的事。
    /// 代價是拔插螢幕之後這份清單是舊的——切到別的地點再切回來（`task(id:)`）會重查。
    @State private var screens: [DisplayChoice] = []

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                identity
                Divider()
                displays
                Divider()
                profiles
            }
            .padding()
        }
        // 選到別的地點時這個 view 會被重用（`detail` 的 switch 走同一個 case），
        // 所以 `onAppear` 不一定再發一次；`task(id:)` 會。
        .task(id: location) { screens = controller.connectedDisplays() }
    }

    // MARK: - 名稱與說明

    private var identity: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("地點").font(.headline)
            LabeledContent("名稱") {
                BufferedField(prompt: "地點名稱", initial: location, commit: rename)
            }
            problem(nameProblem)
            LabeledContent("說明") {
                BufferedField(prompt: "這個地點是什麼", initial: descText) { text in
                    controller.edit { $0.settingLocationDesc(location, to: text) }
                }
            }
        }
    }

    private var descText: String {
        document.locationDesc(location)
    }

    private func rename(to new: String) -> Bool {
        if let why = document.locationNameRefusal(new, excluding: location) {
            nameProblem = why
            return false
        }
        nameProblem = nil
        guard controller.edit({ $0.renamingLocation(location, to: new) }) else { return false }
        onRenamed(new)
        return true
    }

    // MARK: - 螢幕角色

    private var displays: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("螢幕角色").font(.headline)
            Text("角色名同時是 trees 的鍵。改名要新增再刪掉，兩個動作。")
                .font(.caption)
                .foregroundStyle(.secondary)
            ForEach(document.displayRoles(in: location), id: \.self) { role in
                displayRow(role)
            }
            newRoleRow
            problem(roleProblem)
        }
    }

    private func displayRow(_ role: String) -> some View {
        let uuid = document.displayUUID(location: location, role: role) ?? ""
        // 停用的依據是 Model 的守衛，不是這裡自己判 `role == "main"`。
        let refusal = document.displayRoleRemovalRefusal(role, in: location)
        return VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(verbatim: role).frame(width: 90, alignment: .leading)
                BufferedField(prompt: "螢幕 UUID", initial: uuid) { text in
                    controller.edit { $0.settingDisplayUUID(role, to: text, in: location) }
                }
                // 挑到的 UUID 走**同一個動作**（`settingDisplayUUID`），不在這裡自己
                // 組 JSON：路徑怎麼算是 Model 的事，而它有測試。
                DisplayPickerMenu(displays: screens) { picked in
                    controller.apply { $0.settingDisplayUUID(role, to: picked, in: location) }
                }
                Button {
                    controller.apply { $0.removingDisplayRole(role, in: location) }
                } label: {
                    Image(systemName: "minus")
                }
                .buttonStyle(.borderless)
                .disabled(refusal != nil)
                .help(refusal ?? "刪掉這個角色。它的樹不會跟著刪，畫布會把那棵樹標成孤兒。")
            }
            // validate 只查 `displays.main` 這個**鍵**存不存在，空字串照樣過
            // （`LayoutValidator.swift:76`）——所以沒有別人會提這件事。
            if uuid.isEmpty {
                Text(verbatim: "這個角色沒有 UUID，這個地點不會被自動偵測到。")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
    }

    private var newRoleRow: some View {
        HStack {
            TextField("新角色名", text: $newRole).frame(width: 90)
            TextField("螢幕 UUID（可以之後再填）", text: $newRoleUUID)
            Button {
                addRole()
            } label: {
                Image(systemName: "plus")
            }
            .buttonStyle(.borderless)
        }
    }

    /// 撞名與空名都由 `addingDisplayRole` 自己擋（它什麼都不做），所以這裡**不重抄
    /// 那個條件**，只在它真的沒生效時把兩種可能講出來。
    private func addRole() {
        guard controller.edit({ $0.addingDisplayRole(newRole, uuid: newRoleUUID, to: location) })
        else {
            roleProblem = "沒有新增：角色名不能是空的，也不能與現有的角色同名"
                + "（覆蓋會靜默改掉另一台螢幕的身分）。"
            return
        }
        roleProblem = nil
        newRole = ""
        newRoleUUID = ""
    }

    // MARK: - profile

    private var profiles: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("profile").font(.headline)
            ForEach(document.profiles(in: location), id: \.self) { profile in
                profileRow(profile)
            }
            newProfileRow
            problem(profileProblem)
        }
    }

    private func profileRow(_ profile: String) -> some View {
        // 停用的依據是 Model 的守衛（唯一的 profile、default 指著它），不是這裡自己判。
        let refusal = document.profileDeletionRefusal(profile, in: location)
        return HStack {
            BufferedField(prompt: "profile 名稱", initial: profile) { new in
                renameProfile(profile, to: new)
            }
            Button {
                controller.apply { $0.deletingProfile(profile, in: location) }
            } label: {
                Image(systemName: "minus")
            }
            .buttonStyle(.borderless)
            .disabled(refusal != nil)
            .help(refusal ?? "刪掉這個 profile，連同它底下的 trees。")
        }
    }

    private func renameProfile(_ old: String, to new: String) -> Bool {
        if let why = document.profileNameRefusal(new, in: location, excluding: old) {
            profileProblem = why
            return false
        }
        profileProblem = nil
        return controller.edit { $0.renamingProfile(old, to: new, in: location) }
    }

    private var newProfileRow: some View {
        HStack {
            TextField("新 profile 名稱", text: $newProfile)
            Button {
                addProfile()
            } label: {
                Image(systemName: "plus")
            }
            .buttonStyle(.borderless)
        }
    }

    private func addProfile() {
        if let why = document.profileNameRefusal(newProfile, in: location) {
            profileProblem = why
            return
        }
        guard controller.edit({ $0.addingProfile(newProfile, to: location) }) else { return }
        profileProblem = nil
        newProfile = ""
    }

    // MARK: - 共用

    @ViewBuilder private func problem(_ text: String?) -> some View {
        if let text {
            Text(verbatim: text)
                .font(.caption)
                .foregroundStyle(.orange)
        }
    }
}
