import Combine
import Foundation
import SensorBridge

@MainActor
final class Monitor: ObservableObject {
    @Published private(set) var power: BatteryPower?
    @Published private(set) var readings: [Reading] = []
    @Published private var history = SampleHistory()
    @Published private(set) var connected = false
    @Published private(set) var lastUpdate: Date?
    @Published private(set) var thermal = ProcessInfo.processInfo.thermalState
    @Published var threshold: Double {
        didSet {
            let value = safeThreshold(threshold)
            if value != threshold { threshold = value }
            defaults.set(value, forKey: "threshold")
        }
    }
    @Published var economy: Bool {
        didSet {
            defaults.set(economy, forKey: "economy")
            configurePolling()
        }
    }
    @Published var minimalist: Bool {
        didSet {
            defaults.set(minimalist, forKey: "minimalist")
            onHUDChange?()
        }
    }
    @Published var hudMetric: HUDMetric {
        didSet {
            defaults.set(hudMetric.rawValue, forKey: "hudMetric")
            onHUDChange?()
        }
    }
    @Published var dashboardVisible = false { didSet { configurePolling() } }
    @Published var pinned = false
    @Published var details = false { didSet { configurePolling() } }
    @Published var minutes = 5

    var onHUDChange: (() -> Void)?
    var onUpdate: (() -> Void)?
    let totalMemory: Double
    private let defaults: UserDefaults
    private let sampler: SensorSampler
    private var pollingTask: Task<Void, Never>?
    private let pollingEnabled: Bool

    var samples: [Sample] { history.samples }
    var interval: Int { economy ? 5 : 2 }
    var cpu: Double? { maximum(in: .cpu) }
    var gpu: Double? { maximum(in: .gpu) }
    var battery: Double? { maximum(in: .battery) }
    var ssd: Double? { maximum(in: .storage) }
    var peak: Double? { samples.compactMap(\.cpu).max() }
    var hot: Bool { max(cpu ?? 0, gpu ?? 0) >= threshold }
    var thermalText: String { thermalDescription(thermal) }

    init(
        sampler: SensorSampler = SensorSampler(),
        defaults: UserDefaults = .standard,
        startPolling: Bool = true
    ) {
        self.sampler = sampler
        self.defaults = defaults
        self.pollingEnabled = startPolling
        totalMemory = memory_total() / 1_073_741_824
        threshold = safeThreshold(defaults.double(forKey: "threshold"))
        economy = defaults.object(forKey: "economy") as? Bool ?? true
        minimalist = defaults.bool(forKey: "minimalist")
        hudMetric = defaults.string(forKey: "hudMetric").flatMap(HUDMetric.init(rawValue:)) ?? .cpu
        configurePolling()
    }

    deinit { pollingTask?.cancel() }

    private func maximum(in group: SensorGroup) -> Double? {
        readings.filter { $0.group == group }.map(\.value).max()
    }

    private func configurePolling() {
        guard pollingEnabled else { return }
        pollingTask?.cancel()
        let configuration = PollConfiguration(
            interval: interval,
            readAll: !economy || (dashboardVisible && details),
            readLoad: !economy || dashboardVisible
        )
        let sampler = sampler
        pollingTask = Task { [weak self] in
            while !Task.isCancelled {
                let snapshot = await sampler.sample(configuration)
                guard !Task.isCancelled else { return }
                self?.accept(snapshot)
                do { try await Task.sleep(for: .seconds(configuration.interval)) } catch { return }
            }
        }
    }

    func accept(_ snapshot: SensorSnapshot) {
        power = snapshot.power
        connected = snapshot.connected
        readings = snapshot.readings
        thermal = snapshot.thermal
        lastUpdate = snapshot.date
        history.append(
            Sample(
                date: snapshot.date, cpu: cpu, gpu: gpu, battery: battery,
                batteryWatts: snapshot.power.battery, adapterWatts: snapshot.power.adapter,
                powerUpdated: snapshot.power.updated, cpuLoad: snapshot.cpuLoad,
                gpuLoad: snapshot.gpuLoad, memory: snapshot.memory, thermal: thermalText
            ))
        onUpdate?()
    }

    func reset() {
        history.clear()
        onUpdate?()
    }
    func csv() -> String { CSVExporter.render(samples) }
}
