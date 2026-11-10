import Foundation
import Testing
@testable import FCPLibraryCleanerCore

struct CleanupValidationThrottleTests {
    @Test("validation is due initially and after the interval, and only success advances it")
    func intervalAndFailure() {
        var throttle = CleanupValidationThrottle()
        let start = ContinuousClock.now
        #expect(throttle.isDue(at: start))
        #expect(throttle.isDue(at: start.advanced(by: .milliseconds(100))))
        throttle.didValidate(at: start)
        #expect(!throttle.isDue(at: start.advanced(by: .milliseconds(999))))
        #expect(throttle.isDue(at: start.advanced(by: .seconds(1))))
        #expect(throttle.isDue(at: start.advanced(by: .seconds(2))))
        throttle.didValidate(at: start.advanced(by: .seconds(2)))
        #expect(!throttle.isDue(at: start.advanced(by: .milliseconds(2500))))
    }
}
