import Testing
@testable import WorkmodeDomain

@Test func packageBuildsAndTestsRun() {
    #expect(WorkmodeDomain.layerName == "Domain")
}
