import Testing

@testable import ThermoBar

struct PowerTransitionTests {
    @Test func missingTimestampDoesNotReleaseAnUnchangedSample() {
        var filter = PowerTransitionFilter()
        _ = filter.ingest(powerReading(time: .nan))
        let stale = filter.ingest(powerReading(source: 1, time: .nan))
        #expect(stale.waiting)
        #expect(stale.battery == nil)
        #expect(stale.adapter == nil)
        let fresh = filter.ingest(powerReading(source: 1, time: .nan, current: 1))
        #expect(!fresh.waiting)
        #expect(fresh.battery == 12)
    }

    @Test func timestampMustAdvance() {
        var filter = PowerTransitionFilter()
        _ = filter.ingest(powerReading())
        #expect(filter.ingest(powerReading(source: 1)).waiting)
        #expect(filter.ingest(powerReading(source: 1, time: 99)).waiting)
        #expect(!filter.ingest(powerReading(source: 1, time: 101)).waiting)
    }

    @Test func missingElectricalValuesDoNotLookLikeChanges() {
        var filter = PowerTransitionFilter()
        _ = filter.ingest(powerReading(time: .nan, current: .nan, voltage: .nan))
        #expect(filter.ingest(powerReading(source: 1, time: .nan, current: .nan, voltage: .nan)).waiting)
        // Newly available, complete electrical data can recover without a timestamp.
        #expect(!filter.ingest(powerReading(source: 1, time: .nan, current: 1)).waiting)
    }

    @Test func unknownSourceDoesNotForgetAPendingTransition() {
        var filter = PowerTransitionFilter()
        _ = filter.ingest(powerReading())
        #expect(filter.ingest(powerReading(source: -1)).waiting)
        #expect(filter.ingest(powerReading(source: 1)).waiting)
        #expect(filter.ingest(powerReading(source: -1, time: 101)).waiting)
        #expect(!filter.ingest(powerReading(source: 1, time: 101, current: 1)).waiting)
    }

    @Test func unpluggingHidesStaleChargingButKeepsZeroAdapterInput() {
        var filter = PowerTransitionFilter()
        _ = filter.ingest(powerReading(source: 1, current: 1))
        let stale = filter.ingest(powerReading(current: 1))
        #expect(stale.waiting)
        #expect(stale.battery == nil)
        #expect(stale.adapter == 0)
        #expect(!filter.ingest(powerReading(time: 101)).waiting)
    }

    @Test func zeroBatteryFlowIsNotCharging() {
        var filter = PowerTransitionFilter()
        let result = filter.ingest(powerReading(current: 0))
        #expect(!result.waiting)
        #expect(result.battery == 0)
    }
}
