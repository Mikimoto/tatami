import SwiftUI
import WorkmodeEditorModel

/// 一格窗格的落點。
///
/// **存在的理由是座標**：`.dropDestination(for:action:isTargeted:)` 的 `isTargeted`
/// 只給 `Bool`，而放置預覽要知道游標落在這一格的哪一區。只有 `DropDelegate` 的
/// `dropUpdated(info:)` 給得到 `info.location`（單位是被修飾的那個 view 自己的
/// 座標空間，除以 `GeometryReader` 的尺寸就是 0…1）。
struct PaneDropDelegate: DropDelegate {
    /// 這一格的尺寸，用來把 `info.location` 換成 0…1。由 `GeometryReader` 給。
    let size: CGSize
    /// 這個 profile 生效的 label。索引來自拖放的酬載。
    let labels: [LabelChoice]
    let onPlace: (LabelChoice, DropZone) -> Void
    /// 這一格現在要亮哪一區。nil ＝ 不亮。
    @Binding var preview: DropZone?

    func validateDrop(info: DropInfo) -> Bool {
        info.hasItemsConforming(to: [.text])
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        // **拖窗格過來時也會亮，那是已知的落差。** 原本靠一個 `DragKind` 旗標區分，
        // 而那個旗標由 palette 的 `.onDrag` 寫進 `CanvasView` 的 `@State`——寫進去
        // 會在拖曳進行中重建整個畫布的 view tree，實測的結果是預覽完全不出現
        // （2026-08-28）。旗標拿掉之後才亮得起來。
        //
        // 代價是拖窗格到別格會亮一塊而放開沒有反應（`performDrop` 從酬載讀，
        // 認得出那不是 label）。搬移窗格本來就不支援，而窗格的目的地是上方那條
        // 刪除區，所以這個落差碰得到但不常。
        guard size.width > 0, size.height > 0 else {
            preview = nil
            return DropProposal(operation: .cancel)
        }
        preview = DropZone.at(x: info.location.x / size.width,
                              y: info.location.y / size.height)
        return DropProposal(operation: preview == nil ? .cancel : .copy)
    }

    func dropExited(info _: DropInfo) {
        preview = nil
    }

    func performDrop(info: DropInfo) -> Bool {
        // **落點用最後一次 `dropUpdated` 算好的那個**，不重算：重算要再拿一次
        // 座標，而放手那一刻的座標與畫面上亮著的那一區未必是同一格。
        let zone = preview
        preview = nil
        guard let zone, let provider = info.itemProviders(for: [.text]).first
        else { return false }
        // 讀 item 是非同步的，而 `performDrop` 要同步回 `Bool`。回 true 之後才真的
        // 動文件是 SwiftUI drop 的常態；`zone` 已經算好，那個間隙不會讓落點漂掉。
        _ = provider.loadObject(ofClass: String.self) { text, _ in
            guard let text, case let .label(index)? = DragPayload(text: text),
                  labels.indices.contains(index) else { return }
            let choice = labels[index]
            DispatchQueue.main.async { onPlace(choice, zone) }
        }
        return true
    }
}
