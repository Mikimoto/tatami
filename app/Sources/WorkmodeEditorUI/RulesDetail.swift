import SwiftUI
import WorkmodeEditorControl
import WorkmodeEditorModel

/// 側欄選「視窗規則」時的 detail。**從 `EditorWindow` 搬出來的理由是 lint**：yabairc
/// 分頁接上之後那個 struct 的 body 是 272 行（上限 250），而 `.swiftlint.yml` 開頭明寫
/// 不准為了讓數字消失去調參數。搬這一塊是因為它是唯一**一個 `@State` 都不需要**的
/// 區塊——收 `controller` 與 `document` 就夠（跨檔案看不見 `private`，見
/// `ApplyButton.swift` 的檔頭）。內容逐字未動。
struct RulesDetail: View {
    let controller: EditorController
    let document: LayoutDocument

    var body: some View {
        content
    }

    /// 三行提示的條件都在 `LayoutDocument`，這裡只負責畫。判斷不寫在 view body 的
    /// 理由與 `CanvasRole` 同一條：這一層沒有任何測試驗得到，而這些條件錯掉的
    /// 症狀都是「提示永遠出現」或「永遠不出現」，畫面上分不出來。
    private var content: some View {
        let replacing = document.profileLayersReplacingWithNothing.count
        let broken = document.layersWithNonArrayRules.count
        // 下面第一句寫成字面值是因為 `**取代**` 要走 markdown（`Text` 的
        // `LocalizedStringKey` init）；這兩句是組出來的 `String`，所以明寫 `verbatim:`
        // ——不寫的話它照樣編得過，只是走另一條 init，差別在畫面上看不出來。
        let replacingWarning = "有 \(replacing) 個 profile 寫了空的 windows："
            + "那會把共用層與地點層整組取代成零條，而 validate 不會提。"
        let brokenWarning = "有 \(broken) 層的 windows 不是陣列："
            + "套用時會直接失敗，而 validate 不會提。"
        return VStack(alignment: .leading, spacing: 0) {
            // **只在真的有 profile 層規則時**出現。沒有的時候（使用者現在那份檔
            // 就是）多講一句取代規則只是噪音，而使用者要找的是自己那六條寫在哪。
            if document.anyProfileLayerDeclaresRules {
                Text("profile 層的規則會**取代**共用層與地點層整組，不是疊加上去。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal)
                    .padding(.top, 8)
            }
            // 空陣列這一句**只講 profile 層**：共用層與地點層之間永遠是疊加
            // （`ScopedRule.swift` 檔頭的實測），它們寫空陣列什麼都沒做。三種層
            // 一視同仁的舊版本對使用者那份設定講了一句假話（2026-08-29）。
            // `__diff validate` 對這件事回 rc=0，所以這裡是唯一的出聲處。
            if replacing > 0 {
                Text(verbatim: replacingWarning)
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .padding(.horizontal)
                    .padding(.top, 8)
            }
            // 非陣列與層無關：`windows_for` 對它是 rc=5 的硬錯，所以這份檔存得
            // 下去而 `workmode` 跑起來會壞；`__diff validate` 一樣回 rc=0，而表格
            // 對那一層一列都不畫。不講的話那個洞完全沒有訊號。
            if broken > 0 {
                Text(verbatim: brokenWarning)
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .padding(.horizontal)
                    .padding(.top, 8)
            }
            RuleTableView(controller: controller, document: document)
        }
    }
}
