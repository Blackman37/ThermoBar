import Foundation
import SensorBridge

@testable import ThermoBar

func powerReading(source: Int32 = 0, time: Double = 100, current: Double = -1, voltage: Double = 12)
    -> PowerReading
{
    PowerReading(
        battery_watts: voltage * current, adapter_watts: source == 0 ? 0 : 30,
        voltage: voltage, amperage: current, updated_unix: time, external_connected: source
    )
}

func sample(at date: Date, cpu: Double? = 50, gpu: Double? = 45, thermal: String = "Normální tepelný stav")
    -> Sample
{
    Sample(
        date: date, cpu: cpu, gpu: gpu, battery: 30,
        batteryWatts: -12.5, adapterWatts: nil, powerUpdated: nil,
        cpuLoad: nil, gpuLoad: nil, memory: .nan, thermal: thermal
    )
}

// Owned by one sampler actor. No live IOKit or SMC requests in these tests.
final class FakeSensorProvider: SensorProvider {
    var cycle = 0
    var cpuPrimed = false
    var closed = false
    let failFirstDiscovery: Bool
    let disconnectOnSecondSample: Bool

    init(failFirstDiscovery: Bool = false, disconnectOnSecondSample: Bool = false) {
        self.failFirstDiscovery = failFirstDiscovery
        self.disconnectOnSecondSample = disconnectOnSecondSample
    }

    func open() -> Bool {
        closed = false
        return true
    }
    func close() { closed = true }
    func temperatureKeys() -> [String]? {
        if failFirstDiscovery && cycle == 0 { return nil }
        return ["Tp01", "Tg01", "TB01", "TH0T"]
    }
    func temperature(for key: String) -> Double {
        if disconnectOnSecondSample && cycle == 1 { return .nan }
        if key == "TB01" && cycle == 0 { return .nan }
        return key == "TB01" ? 35 : 50
    }
    func resetCPUUsage() { cpuPrimed = false }
    func cpuUsage() -> Double {
        defer { cpuPrimed = true }
        return cpuPrimed ? 25 : .nan
    }
    func gpuUsage() -> Double { 20 }
    func memoryUsed() -> Double { 4 }
    func power() -> PowerReading {
        cycle += 1
        return powerReading()
    }
    func thermalState() -> ProcessInfo.ThermalState { .nominal }
}
