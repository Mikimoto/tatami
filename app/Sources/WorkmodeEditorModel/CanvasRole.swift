/// 畫布上的一格。
///
/// **格子的來源是「display 角色」與「tree 角色」的聯集，不是前者。** 產品的套用
/// 路徑走的是後者——`ApplyLayout.swift:262` 是 `for role in reading.roles(of:
/// context.treeMap)`，而 `:263-265` 對「這個 tree 角色沒有對應的 display」有專屬事件
/// `.treeRoleHasNoDisplay`（`HumanPhrases+Layout.swift:68` 印「trees 有「X」但
/// displays 沒定義這個角色，跳過」）。
///
/// 只照 display 角色列的話那棵樹在編輯器裡完全不存在：`validate` 對它一聲不吭
/// （它只查樹引用的 label 在不在生效清單裡，不查角色有沒有螢幕），套用時只在
/// stderr 閃過一行。`PaneNode` 的「藏起來的節點沒有辦法被修好」講的就是這件事。
///
/// 反過來「有 display 沒 tree」照樣要列（`hasDisplay: true`，畫成「未指定」）：
/// 那是使用者還沒替那台螢幕安排東西，而那正是他要在編輯器裡做的事。
public struct CanvasRole: Equatable, Sendable {
    public let role: String
    public let hasDisplay: Bool

    public init(role: String, hasDisplay: Bool) {
        self.role = role
        self.hasDisplay = hasDisplay
    }
}
