import Foundation
import Testing
@testable import WorkmodeWire

@Test func successEnvelopeHasStableKeyOrderAndOneLine() throws {
    let line = try JSONEnvelope.success(command: "displays", data: ["indices": [2]])
    #expect(line == #"{"command":"displays","data":{"indices":[2]},"ok":true,"schema":1}"#)
    #expect(!line.contains("\n"), "封套必須是一行，否則管線與逐行斷言都會壞")
}

@Test func failureEnvelopeCarriesKindAndMessage() throws {
    let line = try JSONEnvelope.failure(command: "displays",
                                        kind: "not_an_array",
                                        message: "根不是陣列")
    #expect(line == #"{"command":"displays","error":{"kind":"not_an_array","message":"根不是陣列"},"ok":false,"schema":1}"#)
}

/// 成功與失敗互斥：多帶一個欄位會讓消費端要處理不存在的狀態。
@Test func successHasNoErrorKeyAndFailureHasNoDataKey() throws {
    let line = try JSONEnvelope.success(command: "x", data: [:])
    let bad = try JSONEnvelope.failure(command: "x", kind: "k", message: "m")
    #expect(!line.contains("\"error\""))
    #expect(!bad.contains("\"data\""))
}

/// validate --json 的成功路徑。`--json` 沒有差分基準（bash 沒這個表面），所以
/// 成功與失敗各要一條逐位元組的 schema 斷言，否則等於沒驗。
@Test func validateVerdictSuccessShape() throws {
    let line = try JSONEnvelope.verdict(command: "validate", succeeded: true,
                                        data: ["problems": [String]()])
    #expect(line == #"{"command":"validate","data":{"problems":[]},"ok":true,"schema":1}"#)
    #expect(!line.contains("\n"))
}

/// 失敗路徑：ok 為 false，但 data.problems 照樣在——`ok` 報的是檢查結果，
/// 不是命令有沒有跑起來。抬頭與縮排不進去，那是預設模式的格式。
@Test func validateVerdictFailureKeepsProblems() throws {
    let line = try JSONEnvelope.verdict(
        command: "validate", succeeded: false,
        data: ["problems": ["home.desc（要非空字串）", "home：profiles 不存在或是空的"]]
    )
    #expect(line == #"{"command":"validate","data":{"problems":["home.desc（要非空字串）","#
        + #""home：profiles 不存在或是空的"]},"ok":false,"schema":1}"#)
    #expect(!line.contains("! layout.json"))
    #expect(!line.contains("\n"))
}

/// 輸入根本不是 JSON 時沒有結果可以報，走的是 kind/message 那個形狀而不是 verdict。
@Test func validateInvalidJSONUsesErrorEnvelope() throws {
    let line = try JSONEnvelope.failure(command: "validate", kind: "invalid_json",
                                        message: "輸入在中途結束")
    #expect(line == #"{"command":"validate","error":{"kind":"invalid_json","#
        + #""message":"輸入在中途結束"},"ok":false,"schema":1}"#)
    #expect(!line.contains("\"data\""))
}

/// 中文不得被跳脫成 \uXXXX——AI 與人都要讀得懂，而且逐位元組斷言才對得起來。
@Test func chineseIsNotEscaped() throws {
    let line = try JSONEnvelope.failure(command: "x", kind: "k", message: "找不到設定檔")
    #expect(line.contains("找不到設定檔"))
}
