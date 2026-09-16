import Foundation
import Testing
import WorkmodeAdapters
import WorkmodeCore
import WorkmodeDomain

// `workmode --space --json` 的封套。`CLAUDE.md`：「`--json` 沒有差分基準」——bash 沒有
// 這個表面，拿差分 harness 去驗只會得到恆真的通過，所以成功與失敗各一條 schema 斷言
// 就是唯一的網子。
//
// 這裡驗的是**結構**（哪些鍵、值是什麼），不是逐字的 JSON 文字：鍵序由
// `.sortedKeys` 決定而那是封套自己的約定，重抄一份字面值只是抄了兩次。

private func decode(_ line: String) throws -> [String: Any] {
    let data = try #require(line.data(using: .utf8))
    return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
}

@Test func theSpaceEnvelopeReportsWhereItRan() throws {
    let line = ApplyEnvelope.line(command: "space",
                                  outcome: SpaceLayout.Outcome.completed(location: "office",
                                                                         profile: "開發"))
    let json = try decode(line)
    #expect(json["command"] as? String == "space")
    #expect(json["ok"] as? Bool == true)
    let data = try #require(json["data"] as? [String: Any])
    #expect(data["location"] as? String == "office")
    #expect(data["profile"] as? String == "開發")
}

/// 三條早退各有自己的 kind。失敗的封套**沒有 data**（見 `JSONEnvelope` 的 doc），
/// 這條同時釘住那件事。
@Test func theSpaceEnvelopeNamesWhyItStopped() throws {
    let cases: [(SpaceLayout.Outcome, String)] = [
        (.layoutUnavailable(.missing(path: "/x/layout.json")), "layout_missing"),
        (.locationUnrecognized, "location_unrecognized"),
        (.profileUnresolved, "profile_unresolved"),
    ]
    for (outcome, kind) in cases {
        let json = try decode(ApplyEnvelope.line(command: "space", outcome: outcome))
        #expect(json["command"] as? String == "space")
        #expect(json["ok"] as? Bool == false)
        let error = try #require(json["error"] as? [String: Any])
        #expect(error["kind"] as? String == kind, "\(outcome) 的 kind 不對")
        #expect(json["data"] == nil, "失敗的封套不該有 data")
    }
}

/// `--space` 與 `--probe` 的封套**只差 `command` 那個欄位**。
///
/// 這條 2026-09-07 換過內容。原本它比的是「`SpaceLayout.Outcome` 與
/// `ApplyLayout.Outcome` 翻出來的 kind 相同」，而 `ApplyLayout` 退役之後只剩一個
/// Outcome——那個性質變成結構上恆真，那條測試就沒有經驗內容了。現在守的是還有
/// 內容的那一半：兩個入口走同一支函式，差別只有 `SpaceCommand` 傳進來的名字。
@Test func probeAndSpaceEnvelopesDifferOnlyInTheCommandName() throws {
    let outcome = SpaceLayout.Outcome.locationUnrecognized
    var space = try decode(ApplyEnvelope.line(command: "space", outcome: outcome))
    var probe = try decode(ApplyEnvelope.line(command: "probe", outcome: outcome))
    #expect(space["command"] as? String == "space")
    #expect(probe["command"] as? String == "probe")
    space["command"] = nil
    probe["command"] = nil
    // 其餘逐個欄位相同。字典不 Equatable，所以比它們序列化之後的字串。
    #expect(String(describing: space.sorted { $0.key < $1.key })
        == String(describing: probe.sorted { $0.key < $1.key }))
}
