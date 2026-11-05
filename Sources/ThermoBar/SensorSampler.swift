import Foundation
import SensorBridge

struct PollConfiguration: Sendable {
    let interval: Int
    let readAll: Bool
    let readLoad: Bool
}

struct SensorSnapshot: Sendable {
    let date: Date
    let connected: Bool
    let readings: [Reading]
    let power: BatteryPower
    let cpuLoad: Double?
    let gpuLoad: Double?
    let memory: Double
    let thermal: ProcessInfo.ThermalState
}

// Each provider is transferred to, and used exclusively by, one sampler actor.
// Tests supply an in-memory provider; the app owns one SystemSensorProvider.
protocol SensorProvider: AnyObject {
    func open() -> Bool
    func close()
    func temperatureKeys() -> [String]?
    func temperature(for key: String) -> Double
    func resetCPUUsage()
    func cpuUsage() -> Double
    func gpuUsage() -> Double
    func memoryUsed() -> Double
    func power() -> PowerReading
    func thermalState() -> ProcessInfo.ThermalState
}

final class SystemSensorProvider: SensorProvider {
    deinit { sensor_close() }

    func open() -> Bool { sensor_open() != 0 }
    func close() { sensor_close() }

    func temperatureKeys() -> [String]? {
        let count = sensor_count()
        guard count > 0 else { return nil }
        var result: [String] = []
        for index in 0..<count {
            var key = [CChar](repeating: 0, count: 5)
            // Retry incomplete discovery rather than permanently omitting a key.
            guard sensor_key(index, &key) != 0 else { return nil }
            let name = String(decoding: key.prefix(4).map { UInt8(bitPattern: $0) }, as: UTF8.self)
            if name.hasPrefix("T") { result.append(name) }
        }
        return result
    }

    func temperature(for key: String) -> Double { sensor_read(key) }
    func resetCPUUsage() { cpu_usage_reset() }
    func cpuUsage() -> Double { cpu_usage() }
    func gpuUsage() -> Double { gpu_usage() }
    func memoryUsed() -> Double { memory_used() / 1_073_741_824 }
    func power() -> PowerReading { power_read() }
    func thermalState() -> ProcessInfo.ThermalState { ProcessInfo.processInfo.thermalState }
}

actor SensorSampler {
    private let provider: any SensorProvider
    private var isOpen = false
    private var keys: [String] = []
    private var discoveredAt: Date?
    private var powerFilter = PowerTransitionFilter()
    private var wasReadingLoad = false
    private var sampledAt: Date?

    init(provider: sending any SensorProvider = SystemSensorProvider()) {
        self.provider = provider
    }

    func sample(_ configuration: PollConfiguration, at now: Date = Date()) -> SensorSnapshot {
        if !isOpen { isOpen = provider.open() }
        let discoveryDue = discoveredAt.map { now.timeIntervalSince($0) >= 300 } ?? true
        if isOpen && (keys.isEmpty || discoveryDue), let discovered = provider.temperatureKeys() {
            // Candidate discovery must not depend on this sample's temperature.
            keys = Array(Set(discovered)).sorted()
            discoveredAt = now
        }
        let selected =
            configuration.readAll
            ? keys
            : keys.filter {
                [.cpu, .gpu, .battery].contains(Reading(key: $0, value: 0).group)
            }
        let readings = selected.compactMap { key -> Reading? in
            let value = provider.temperature(for: key)
            guard value.isFinite, value > 0, value < 130 else { return nil }
            return Reading(key: key, value: value)
        }
        if isOpen && (keys.isEmpty || (!selected.isEmpty && readings.isEmpty)) {
            provider.close()
            isOpen = false
            keys.removeAll()
            discoveredAt = nil
        }

        var cpuLoad: Double?
        if configuration.readLoad {
            // Re-prime after a hidden dashboard or a long gap such as sleep.
            let longGap =
                sampledAt.map { now.timeIntervalSince($0) > Double(configuration.interval * 2 + 1) } ?? true
            let prime = !wasReadingLoad || longGap
            if prime { provider.resetCPUUsage() }
            let value = provider.cpuUsage()
            cpuLoad = prime ? nil : valid(value)
        }
        wasReadingLoad = configuration.readLoad
        sampledAt = now
        return SensorSnapshot(
            date: now,
            connected: isOpen,
            readings: readings,
            power: powerFilter.ingest(provider.power()),
            cpuLoad: cpuLoad,
            gpuLoad: configuration.readLoad ? valid(provider.gpuUsage()) : nil,
            memory: configuration.readLoad ? provider.memoryUsed() : .nan,
            thermal: provider.thermalState()
        )
    }
}
