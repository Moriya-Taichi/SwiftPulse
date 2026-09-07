import Foundation
import Testing
@testable import PulseLoad

@Test func histogramUsesBoundedApproximation() {
    var histogram = LatencyHistogram()
    for i in 1...1000 { histogram.record(Double(i)) }
    #expect(histogram.percentile(0.50) >= 500)
    #expect(histogram.percentile(0.50) <= 510)
    #expect(histogram.percentile(0.99) >= 990)
    #expect(histogram.summary.max == 1000)
    #expect(histogram.summary.mean == 500.5)
}

@Test func invalidLoadConfiguration() {
    var config = LoadConfiguration(url: "file:///tmp/data")
    #expect(throws: LoadError.self) { try config.validate() }
    config.url = "http://localhost/"; config.rate = .nan
    #expect(throws: LoadError.self) { try config.validate() }
}
