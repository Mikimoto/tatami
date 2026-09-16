import Foundation
import WorkmodeCore

// renderer 與外界的接縫：誰把字寫出去、寫到哪個 fd。

// 事件 → 文字。這是 Adapters 而不是 CLI 的工作，理由有兩個：把結構變成某個外部
// 表示法就是一種 adapter，而 CLI 是 executable target——放在那裡的 switch
// **測不到**，而這個 switch 是全部 60 多句話唯一的家（Reporter.swift 的約定 5）。

/// 事件的落點。
///
/// 抽成 protocol 只為一件事：renderer 的測試要拿得到「哪句話進了哪個流」。
/// 真正的實作是 `StandardStreams`，它沒有任何邏輯。
public protocol EventSink {
    func write(_ text: String, to channel: OutputChannel)
}

/// 事件 → 一整句文字（含尾端換行）。人看的版本與 `--json` 版本各實作一次。
public protocol EventRenderer {
    func render(_ event: WorkmodeEvent) -> String
}

/// 把 renderer 接到某個 sink 上。
///
/// 事件送到哪個流由**事件自己**決定（`WorkmodeEvent.channel`），不是由 renderer 決定：
/// stdout／stderr 的分別在 bash 是有作用的（`save_layout` 用 `2>/dev/null` 壓掉
/// 整批「找不到」訊息，workmode.sh:1106），renderer 只負責字。
public struct TextReporter<Renderer: EventRenderer>: Reporter {
    private let renderer: Renderer
    private let sink: any EventSink

    public init(renderer: Renderer, sink: any EventSink) {
        self.renderer = renderer
        self.sink = sink
    }

    public func report(_ event: WorkmodeEvent) {
        sink.write(renderer.render(event), to: event.channel)
    }
}

/// 真的 fd 1 與 fd 2。
///
/// 用 `FileHandle.write` 而不是 `print`：`print` 只有 stdout，而 stderr 是這個
/// 設計要保留的東西（見 Reporter.swift 理由 2）。而且 `write` 是無緩衝的——
/// 套版面要跑好幾秒、使用者是邊看邊等的（理由 3），緩衝會讓訊息成批出現。
public struct StandardStreams: EventSink, Sendable {
    public init() {}

    public func write(_ text: String, to channel: OutputChannel) {
        let handle = channel == .stderr ? FileHandle.standardError : FileHandle.standardOutput
        handle.write(Data(text.utf8))
    }
}

/// 把事件文字交給一個閉包，而不是寫進 `FileHandle`。
///
/// 編輯器要把 `ApplyLayout` 發出的事件顯示在視窗裡，而不是印到一個沒有人看的 stdout。
/// 它住在 Adapters 而不是 CLI，理由與 `StandardStreams` 相同：它們是 `Reporter`
/// 這個 port 實作的共同協作者，而且**只有在這裡它才有測試**（CLI 沒有測試）。
///
/// **收閉包而不是自己存陣列**：存陣列要一個可變的 class（測試裡的 `RecordingSink`
/// 就是），而 struct 加閉包讓呼叫端用一個區域 `var` 接就好，不必為了一條同步路徑
/// 多一個有身分的物件。`EventSink` 本身不要求 `Sendable`（`TextReporter` 持有的是
/// `any EventSink`），所以兩種寫法都編得過——這是取捨不是限制。
///
/// **`channel` 刻意不分**：見 `itKeepsBothChannelsInOrder` 的註解。
public struct CallbackSink: EventSink {
    private let append: (String) -> Void

    public init(_ append: @escaping (String) -> Void) {
        self.append = append
    }

    public func write(_ text: String, to _: OutputChannel) {
        append(text)
    }
}
