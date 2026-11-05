import Foundation
import Testing

@testable import ThermoBar

struct HistoryAndExportTests {
    private let start = Date(timeIntervalSince1970: 0)

    @Test func historyRetainsTwoHoursAndResets() {
        var history = SampleHistory()
        history.append(sample(at: start))
        history.append(sample(at: start.addingTimeInterval(7200)))
        #expect(history.samples.count == 2)
        history.append(sample(at: start.addingTimeInterval(7201)))
        #expect(history.samples.count == 2)
        #expect(history.samples.first?.date == start.addingTimeInterval(7200))
        history.clear()
        #expect(history.samples.isEmpty)
    }

    @Test func csvHasStableColumnsDecimalsAndEmptyUnavailableValues() {
        let csv = CSVExporter.render([sample(at: start, cpu: 50.25, gpu: .nan)])
        let rows = csv.split(separator: "\n")
        #expect(rows.count == 2)
        #expect(rows[0] == Substring(CSVExporter.header))
        let columns = rows[1].split(separator: ",", omittingEmptySubsequences: false)
        #expect(columns.count == 11)
        #expect(columns[0] == "1970-01-01T00:00:00Z")
        #expect(columns[1] == "50.25")
        #expect(columns[2].isEmpty)
        #expect(columns[6].isEmpty)
        #expect(columns[8] == "-12.50")
        #expect(columns[9].isEmpty)
        #expect(columns[10].isEmpty)
        #expect(!csv.contains("nan"))
        #expect(CSVExporter.render([]) == CSVExporter.header + "\n")
    }

    @Test func csvEscapesTextFields() {
        let csv = CSVExporter.render([sample(at: start, thermal: "Test, \"quoted\"\nline")])
        #expect(csv.contains("\"Test, \"\"quoted\"\"\nline\""))
    }

    @Test func chartIncludesBothSeriesAndLowTemperatures() {
        #expect(chartTemperatureRange([sample(at: start, cpu: 60, gpu: 120)]).upperBound == 125)
        #expect(chartTemperatureRange([sample(at: start, cpu: nil, gpu: 10)]).lowerBound == 5)
        #expect(chartTemperatureRange([]) == 20...110)
    }

    @Test @MainActor func monitorUsesSafeSettingsAndResetClearsExportedHistory() throws {
        let suite = "ThermoBarTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("invalid", forKey: "hudMetric")
        defaults.set(999, forKey: "threshold")
        let monitor = Monitor(
            sampler: SensorSampler(provider: FakeSensorProvider()), defaults: defaults, startPolling: false)
        #expect(monitor.hudMetric == .cpu)
        #expect(monitor.threshold == 90)
        monitor.accept(
            SensorSnapshot(
                date: start, connected: true, readings: [Reading(key: "Tp01", value: 70)],
                power: BatteryPower(powerReading()), cpuLoad: 10, gpuLoad: 20, memory: 4, thermal: .nominal
            ))
        #expect(monitor.cpu == 70)
        #expect(monitor.samples.count == 1)
        monitor.reset()
        #expect(monitor.samples.isEmpty)
        #expect(monitor.csv() == CSVExporter.header + "\n")
        monitor.hudMetric = .combinedPower
        #expect(defaults.string(forKey: "hudMetric") == HUDMetric.combinedPower.rawValue)
    }
}
