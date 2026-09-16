import SwiftUI
import WorkmodeDomain
import WorkmodeEditorControl
import WorkmodeEditorModel

/// 側欄底下那個「新增地點」表單：四個欄位、三道守衛、以及 `main` 的 UUID 挑選器。
///
/// **自己一個 struct 而不是 `EditorWindow` 的一個 `private var`**：留在裡面的話那個
/// struct 的 body 是 260 行（上限 250），而 `.swiftlint.yml` 開頭明寫不准為了讓數字
/// 消失去調參數。搬的單位挑這一組，理由與 Task 5 把 ⌘R 那組搬到 `ApplyButton.swift`
/// 相同——它自己帶著全部的欄位狀態，與側欄其餘部分只靠一個 closure 相連。
/// **2026-08-21 從 `EditorWindow.swift` 搬到自己的檔**：側欄修撞 id 的 bug 時多了
/// 一個 `SidebarRow`，`EditorWindow.swift` 因此破 file_length 的 400 行。這一段原本
/// 寫「留在這個檔是因為它只有這裡在用」，那個理由在 400 行的限制前面站不住。
struct AddLocationForm: View {
    let controller: EditorController
    /// 建好了，名字是這個。呼叫端要關掉 popover 並把側欄選過去（選取是它的狀態）。
    let created: (String) -> Void

    /// 四個欄位都要，因為 validate 對地點要求非空 desc 與非空的 profiles
    /// （`LayoutValidator.swift:64-82`）——只建一個空殼存不了檔，而使用者看不出缺什麼。
    @State private var name = ""
    @State private var desc = ""
    @State private var profile = ""
    /// `main` 的 UUID。2c 把它建成空字串（validate 只查那個**鍵**存不存在），代價是
    /// 那個地點永遠不會被自動偵測到；這裡讓它在建的當下就填得對。
    /// 留空仍然建得起來——那正是 2c 的行為，地點面板上的橘字會講。
    @State private var uuid = ""
    @State private var problem: String?
    /// 挑選器的清單。與 `LocationView` 各記一份：popover 的內容每次打開才出現，
    /// 所以這一份在 `onAppear` 查一次就夠。
    @State private var screens: [DisplayChoice] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("地點名稱", text: $name)
            TextField("說明（validate 要求非空）", text: $desc)
            TextField("第一個 profile 的名稱", text: $profile)
            HStack {
                TextField("main 的螢幕 UUID（可以之後再填）", text: $uuid)
                DisplayPickerMenu(displays: screens) { uuid = $0 }
            }
            if let problem {
                Text(verbatim: problem)
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            HStack {
                Spacer()
                Button("建立") { create() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .frame(width: 320)
        .padding()
        // 拔插螢幕之後重開一次這個表單就是新的清單。
        .onAppear { screens = controller.connectedDisplays() }
    }

    /// 三個名字各過一次守衛。desc 的非空是 validate 的要求——不擋的話那個地點一建
    /// 出來就存不了檔，而使用者要到 ⌘S 才會知道是哪裡。
    private func create() {
        guard let document = controller.document else { return }
        if let why = document.locationNameRefusal(name) {
            problem = why
            return
        }
        if let why = document.locationDescRefusal(desc) {
            problem = why
            return
        }
        // 這個地點還不存在，所以 `profiles(in: name)` 是空的——「撞名」這條對第一個
        // profile 本來就不適用，不必另外表達成空的 existing 清單。上一道守衛已經確認
        // `name` 不是既有地點，所以它不可能查到別人的清單。
        if let why = document.profileNameRefusal(profile, in: name) {
            problem = why
            return
        }
        guard commit() else {
            problem = "沒有新增，而且原因不在上面那三條——這是 bug。"
            return
        }
        let newName = name
        problem = nil
        name = ""
        desc = ""
        profile = ""
        uuid = ""
        created(newName)
    }

    /// **一次編輯裡串兩個動作**（`addingLocation` 把 `main` 建成空字串，接著把挑到的
    /// UUID 設進去），不是兩次 `edit`：兩次會是兩步 undo，而使用者做的是一件事。
    /// UUID 留空時第二段是恆等的（那個鍵本來就是空字串）。
    private func commit() -> Bool {
        // `edit` 收的是非逃逸 closure（`EditorController.swift:141`），所以直接讀欄位
        // 就好——為此開兩個同名的區域變數會被 swiftformat 的 redundantSelf 改成
        // `let name = name`，那看起來像 bug。
        controller.edit {
            $0.addingLocation(name, desc: desc, firstProfile: profile)
                .settingDisplayUUID("main", to: uuid, in: name)
        }
    }
}
