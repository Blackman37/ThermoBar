import AppKit
import SwiftUI
import Charts
import Combine

struct Reading: Identifiable {
    let key: String
    let value: Double
    var id: String { key }
    var group: String {
        if key.hasPrefix("Tp") || key.hasPrefix("Te") || key.hasPrefix("Tf") || ["TCMz", "TCMb"].contains(key) { return "CPU" }
        if key.hasPrefix("Tg") { return "GPU" }
        if key.hasPrefix("TB") { return "Baterie" }
        if key == "TH0T" || key == "TH0x" { return "SSD / NAND" }
        return "Další čidla"
    }
}
struct Sample: Identifiable {
    let id = UUID()
    let date: Date
    let cpu: Double?
    let gpu: Double?
    let battery: Double?
    let batteryWatts: Double?
    let adapterWatts: Double?
    let powerUpdated: Date?
    let cpuLoad: Double?
    let gpuLoad: Double?
    let memory: Double
    let thermal: String
}
func valid(_ value: Double) -> Double? { value.isFinite ? value : nil }
func degrees(_ value: Double?) -> String { value.map { String(format: "%.0f°", $0) } ?? "—" }
func percent(_ value: Double?) -> String { value.map { String(format: "%.0f %%", $0) } ?? "—" }
func watts(_ value: Double?, signed: Bool = false) -> String {
    value.map { String(format: signed && abs($0) >= 0.05 ? "%+.1f W" : "%.1f W", abs($0) < 0.05 ? 0 : $0) } ?? "—"
}
struct BatteryPower {
    let waiting: Bool
    let battery: Double?
    let adapter: Double?
    let voltage: Double?
    let amperage: Double?
    let updated: Date?
    let external: Int32
    init(_ raw: PowerReading, waiting: Bool = false) {
        self.waiting = waiting
        battery = waiting ? nil : valid(raw.battery_watts)
        adapter = waiting && raw.external_connected == 1 ? nil : valid(raw.adapter_watts)
        voltage = valid(raw.voltage); amperage = valid(raw.amperage)
        updated = valid(raw.updated_unix).flatMap { $0 > 0 ? Date(timeIntervalSince1970: $0) : nil }
        external = raw.external_connected
    }
    var direction: String {
        guard let battery else { return waiting ? "Čekám na nový údaj baterie" : "Údaj baterie není dostupný" }
        if battery >= 0.05 { return "Nabíjení baterie" }
        if battery <= -0.05 { return "Vybíjení baterie" }
        return "Baterie bez toku energie"
    }
    var source: String { external == 1 ? "Adaptér připojen" : (external == 0 ? "Napájení z baterie" : "Zdroj napájení neznámý") }
    var age: String {
        guard let updated else { return "Stáří údajů není dostupné" }
        let elapsed = Date().timeIntervalSince(updated)
        guard elapsed.isFinite,
              let seconds = Int(exactly: max(0, elapsed).rounded(.down)) else {
            return "Stáří údajů není dostupné"
        }
        return "Stáří údajů systému: \(seconds) s"
    }
}
// IORegistry can change ExternalConnected before refreshing current/voltage.
// Hide the previous flow until a new electrical sample arrives.
struct PowerTransitionFilter {
    private var previous: PowerReading?
    private var awaiting: PowerReading?
    mutating func ingest(_ raw: PowerReading) -> BatteryPower {
        if let previous, raw.external_connected != previous.external_connected,
           raw.external_connected >= 0, previous.external_connected >= 0 {
            awaiting = previous
        }
        if let old = awaiting {
            if raw.updated_unix != old.updated_unix || raw.amperage != old.amperage || raw.voltage != old.voltage {
                awaiting = nil
            }
        }
        previous = raw
        // A running Mac cannot be charging its battery without external power.
        let inconsistent = raw.external_connected == 0 && raw.battery_watts >= 0
        return BatteryPower(raw, waiting: awaiting != nil || inconsistent)
    }
}
let orange = Color(red: 1, green: 0.64, blue: 0.35)
let cyan = Color(red: 0.28, green: 0.83, blue: 0.88)
let canvas = Color(red: 0.055, green: 0.065, blue: 0.09)
let panel = Color(red: 0.09, green: 0.105, blue: 0.14)

func safeThreshold(_ value: Double) -> Double { value.isFinite && (60...110).contains(value) ? value : 90 }

final class Monitor: ObservableObject {
    @Published var power: BatteryPower?
    @Published var readings: [Reading] = []
    @Published var samples: [Sample] = []
    @Published var connected = false
    @Published var lastUpdate: Date?
    @Published var thermal = ProcessInfo.processInfo.thermalState
    @Published var threshold = safeThreshold(UserDefaults.standard.double(forKey: "threshold")) {
        didSet { let value = safeThreshold(threshold); if value != threshold { threshold = value }; UserDefaults.standard.set(value, forKey: "threshold") }
    }
    @Published var economy = UserDefaults.standard.object(forKey: "economy") as? Bool ?? true {
        didSet { UserDefaults.standard.set(economy, forKey: "economy"); configurePolling() }
    }
    @Published var minimalist = UserDefaults.standard.bool(forKey: "minimalist") {
        didSet { UserDefaults.standard.set(minimalist, forKey: "minimalist"); onHUDChange?() }
    }
    @Published var hudMetric = UserDefaults.standard.string(forKey: "hudMetric") ?? "CPU" {
        didSet { UserDefaults.standard.set(hudMetric, forKey: "hudMetric"); onHUDChange?() }
    }
    @Published var dashboardVisible = false { didSet { configurePolling() } }
    var onHUDChange: (() -> Void)?
    var interval: Int { economy ? 5 : 2 }
    var hudValue: Double? { hudMetric == "Baterie" ? battery : (hudMetric == "GPU" ? gpu : cpu) }
    var hudCombined: Bool { hudMetric == "Adaptér + baterie" }
    var hudWidth: CGFloat { hudCombined ? 146 : (hudIsPower ? 126 : 72) }
    var hudHeight: CGFloat { hudCombined ? 62 : 38 }
    var hudIsPower: Bool { ["Výkon baterie", "Příkon adaptéru", "Adaptér + baterie"].contains(hudMetric) }
    var hudText: String { hudMetric == "Výkon baterie" ? watts(power?.battery, signed: true) : (hudMetric == "Příkon adaptéru" ? watts(power?.adapter) : degrees(hudValue)) }
    @Published var pinned = false
    @Published var details = false { didSet { configurePolling() } }
    @Published var minutes = 5
    var onUpdate: (() -> Void)?
    private let queue = DispatchQueue(label: "cz.thermobar.sensors", qos: .utility)
    private var timer: DispatchSourceTimer?
    private var keys: [String] = []
    private var isOpen = false
    private var powerFilter = PowerTransitionFilter()
    // These settings are accessed only on the sensor queue.
    private var readAll = false
    private var readLoad = false
    let totalMemory = memory_total() / 1_073_741_824
    var cpu: Double? { readings.filter { $0.group == "CPU" }.map(\.value).max() }
    var gpu: Double? { readings.filter { $0.group == "GPU" }.map(\.value).max() }
    var battery: Double? { readings.filter { $0.group == "Baterie" }.map(\.value).max() }
    var ssd: Double? { readings.filter { $0.group == "SSD / NAND" }.map(\.value).max() }
    var peak: Double? { samples.compactMap(\.cpu).max() }
    var hot: Bool { max(cpu ?? 0, gpu ?? 0) >= threshold }
    var thermalText: String {
        switch thermal { case .nominal: return "Normální tepelný stav"; case .fair: return "Zvýšená tepelná zátěž"; case .serious: return "Vysoká tepelná zátěž"; case .critical: return "Kritická tepelná zátěž"; @unknown default: return "Neznámý stav" }
    }
    var thermalColor: Color { thermal == .nominal ? .mint : (thermal == .fair ? .yellow : .red) }
    init() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.setEventHandler { [weak self] in self?.poll() }
        timer.schedule(deadline: .now(), repeating: .seconds(interval), leeway: .milliseconds(500))
        timer.resume()
        self.timer = timer
        configurePolling()
    }
    private func configurePolling() {
        let seconds = interval
        let all = !economy || (dashboardVisible && details)
        let load = !economy || dashboardVisible
        queue.async { [weak self] in
            guard let self else { return }
            self.readAll = all
            self.readLoad = load
            self.timer?.schedule(deadline: .now(), repeating: .seconds(seconds), leeway: .milliseconds(500))
        }
    }
    private func poll() {
        if !isOpen { isOpen = sensor_open() != 0 }
        if isOpen && keys.isEmpty {
            for index in 0..<sensor_count() {
                var key = [CChar](repeating: 0, count: 5)
                if sensor_key(Int32(index), &key) != 0 {
                    let name = String(cString: key)
                    if name.hasPrefix("T"), let v = valid(sensor_read(name)), v > 0, v < 130 { keys.append(name) }
                }
            }
        }
        let selectedKeys = readAll ? keys : keys.filter {
            ["CPU", "GPU", "Baterie"].contains(Reading(key: $0, value: 0).group)
        }
        let values = selectedKeys.compactMap { key -> Reading? in
            guard let v = valid(sensor_read(key)), v > 0, v < 130 else { return nil }
            return Reading(key: key, value: v)
        }
        // Retry a disconnected SMC after wake, without retaining stale values.
        if isOpen && values.isEmpty { sensor_close(); isOpen = false; keys = [] }
        let cpuLoad = readLoad ? valid(cpu_usage()) : nil
        let gpuLoad = readLoad ? valid(gpu_usage()) : nil
        let memory = readLoad ? memory_used() / 1_073_741_824 : Double.nan
        let power = powerFilter.ingest(power_read())
        let state = ProcessInfo.processInfo.thermalState
        let open = isOpen
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.power = power
            self.connected = open
            self.readings = values
            self.thermal = state
            let now = Date()
            self.lastUpdate = now
            self.samples.append(Sample(date: now, cpu: self.cpu, gpu: self.gpu, battery: self.battery, batteryWatts: power.battery, adapterWatts: power.adapter, powerUpdated: power.updated, cpuLoad: cpuLoad, gpuLoad: gpuLoad, memory: memory, thermal: self.thermalText))
            self.samples.removeAll { $0.date < now.addingTimeInterval(-7200) }
            self.onUpdate?()
        }
    }
    func reset() { samples = []; onUpdate?() }
    func export() {
        let dialog = NSSavePanel()
        dialog.nameFieldStringValue = "ThermoBar-\(Date().formatted(.iso8601.year().month().day())) .csv".replacingOccurrences(of: " .", with: ".")
        dialog.allowedContentTypes = [.commaSeparatedText]
        guard dialog.runModal() == .OK, let url = dialog.url else { return }
        do { try csv().write(to: url, atomically: true, encoding: .utf8) }
        catch { let alert = NSAlert(error: error); alert.runModal() }
    }
    func csv() -> String {
        let formatter = ISO8601DateFormatter()
        func number(_ v: Double?) -> String { v.map { String(format: "%.2f", locale: Locale(identifier: "en_US_POSIX"), $0) } ?? "" }
        var csv = "timestamp,cpu_area_max_c,gpu_area_max_c,battery_max_c,cpu_load_percent,gpu_load_percent,memory_used_gib,macos_thermal_state,battery_power_w,adapter_input_w,power_source_updated_at\n"
        for s in samples { csv += "\(formatter.string(from: s.date)),\(number(s.cpu)),\(number(s.gpu)),\(number(s.battery)),\(number(s.cpuLoad)),\(number(s.gpuLoad)),\(number(valid(s.memory))),\(s.thermal),\(number(s.batteryWatts)),\(number(s.adapterWatts)),\(s.powerUpdated.map { formatter.string(from: $0) } ?? "")\n" }
        return csv
    }
}

struct PowerCard: View {
    @ObservedObject var monitor: Monitor
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 5) {
                    Label(monitor.power?.direction ?? "Výkon baterie", systemImage: "battery.100percent")
                    Text(watts(monitor.power?.battery, signed: true)).font(.system(size: 30, weight: .medium, design: .rounded)).monospacedDigit().foregroundStyle(.mint)
                    Text("+ do baterie · − z baterie").font(.system(size: 10)).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, alignment: .leading)
                VStack(alignment: .leading, spacing: 5) {
                    Label("Příkon adaptéru / USB‑C", systemImage: "powerplug")
                    Text(watts(monitor.power?.adapter)).font(.system(size: 30, weight: .medium, design: .rounded)).monospacedDigit().foregroundStyle(cyan)
                    Text("Celkem do Macu, včetně nabíjení").font(.system(size: 10)).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            Text("Orientační údaje systému; mohou se obnovovat pomaleji než zobrazení. Příkon adaptéru není jeho jmenovitý výkon ani odběr ze zásuvky.").font(.system(size: 10)).foregroundStyle(.secondary)
            Text("\(monitor.power?.source ?? "Čekám na zdroj") · \(monitor.power?.age ?? "Čekám na údaje napájení")").font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
        }.font(.system(size: 12, weight: .medium)).padding(18).background(panel, in: RoundedRectangle(cornerRadius: 18))
    }
}

struct MetricCard: View {
    let title: String
    let icon: String
    let value: Double?
    let subtitle: String
    let color: Color
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack { Image(systemName: icon).foregroundStyle(color); Text(title).font(.system(size: 12, weight: .semibold)); Spacer() }
            Text(degrees(value)).font(.system(size: 44, weight: .medium, design: .rounded)).monospacedDigit().foregroundStyle(value == nil ? .secondary : color)
            Text(subtitle).font(.system(size: 10)).foregroundStyle(.secondary)
        }.frame(maxWidth: .infinity, alignment: .leading).padding(18).background(panel, in: RoundedRectangle(cornerRadius: 18))
    }
}
struct LoadRow: View {
    let title: String
    let value: Double?
    let color: Color
    var body: some View {
        HStack(spacing: 14) {
            Text(title).font(.system(size: 12)).frame(width: 32, alignment: .leading)
            GeometryReader { g in
                ZStack(alignment: .leading) { Capsule().fill(.white.opacity(0.07)); Capsule().fill(color).frame(width: g.size.width * min(1, max(0, (value ?? 0)/100))) }
            }.frame(height: 5)
            Text(percent(value)).font(.system(size: 12, weight: .medium, design: .monospaced)).frame(width: 50, alignment: .trailing)
        }
    }
}
struct Dashboard: View {
    @ObservedObject var monitor: Monitor
    let toggleHUD: () -> Void
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                HStack {
                    Image(systemName: "thermometer.medium").font(.system(size: 24)).foregroundStyle(orange).padding(12).background(orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 14))
                    VStack(alignment: .leading, spacing: 3) {
                        Text("ThermoBar").font(.system(size: 25, weight: .semibold, design: .rounded))
                        Text("MACBOOK AIR  /  APPLE M3  /  16 GB").font(.system(size: 10, weight: .medium, design: .monospaced)).tracking(1).foregroundStyle(.secondary)
                    }
                    Spacer()
                    HStack(spacing: 6) { Circle().fill(monitor.connected ? Color.mint : .orange).frame(width: 6, height: 6); Text(monitor.connected ? "ŽIVĚ · \(monitor.interval) s" : "ČEKÁM NA ČIDLA").font(.system(size: 10, weight: .semibold, design: .monospaced)) }.foregroundStyle(.secondary)
                }
                HStack(spacing: 10) {
                    Circle().fill(monitor.thermalColor).frame(width: 8, height: 8)
                    Text(monitor.thermalText).font(.system(size: 13, weight: .medium))
                    Spacer()
                    Text("TEPELNÝ STAV macOS").font(.system(size: 9, design: .monospaced)).foregroundStyle(.secondary)
                }.padding(14).background(monitor.thermalColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
                HStack(spacing: 12) {
                    MetricCard(title: "CPU", icon: "cpu", value: monitor.cpu, subtitle: "Nejteplejší čidlo oblasti CPU", color: orange)
                    MetricCard(title: "GPU", icon: "square.stack.3d.up", value: monitor.gpu, subtitle: "Nejteplejší čidlo oblasti GPU", color: cyan)
                    MetricCard(title: "Baterie", icon: "battery.75percent", value: monitor.battery, subtitle: "Maximum čidel baterie", color: Color(red: 0.77, green: 0.69, blue: 0.99))
                }
                PowerCard(monitor: monitor)
                VStack(alignment: .leading, spacing: 16) {
                    HStack {
                        Text("Průběh teplot").font(.system(size: 14, weight: .semibold))
                        Spacer()
                        Picker("Historie", selection: $monitor.minutes) { Text("5 min").tag(5); Text("30 min").tag(30); Text("2 h").tag(120) }.pickerStyle(.segmented).labelsHidden().frame(width: 200)
                    }
                    Chart {
                        ForEach(monitor.samples.filter { $0.date >= Date().addingTimeInterval(Double(-monitor.minutes*60)) }) { s in
                            if let cpu = s.cpu { LineMark(x: .value("Čas", s.date), y: .value("°C", cpu), series: .value("Čidlo", "CPU")).foregroundStyle(orange).interpolationMethod(.linear) }
                            if let gpu = s.gpu { LineMark(x: .value("Čas", s.date), y: .value("°C", gpu), series: .value("Čidlo", "GPU")).foregroundStyle(cyan).interpolationMethod(.linear) }
                        }
                        RuleMark(y: .value("Upozornění", monitor.threshold)).foregroundStyle(.white.opacity(0.22)).lineStyle(StrokeStyle(lineWidth: 1, dash: [4,4]))
                    }
                    .chartYScale(domain: 20...max(110, (monitor.samples.compactMap(\.cpu).max() ?? 0)+5))
                    .chartXScale(domain: Date().addingTimeInterval(Double(-monitor.minutes*60))...Date())
                    .chartXAxis { AxisMarks(values: .automatic(desiredCount: 4)) { _ in AxisGridLine().foregroundStyle(.white.opacity(0.04)); AxisValueLabel(format: .dateTime.hour().minute()).foregroundStyle(.secondary) } }
                    .chartYAxis { AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { _ in AxisGridLine().foregroundStyle(.white.opacity(0.06)); AxisValueLabel().foregroundStyle(.secondary) } }
                    .frame(height: 155)
                    HStack(spacing: 18) {
                        Label("CPU", systemImage: "circle.fill").foregroundStyle(orange)
                        Label("GPU", systemImage: "circle.fill").foregroundStyle(cyan)
                        Spacer()
                        Text("CPU maximum historie  \(degrees(monitor.peak))C").foregroundStyle(.secondary)
                    }.font(.system(size: 10, weight: .medium))
                }.padding(18).background(panel, in: RoundedRectangle(cornerRadius: 18))
                HStack(alignment: .top, spacing: 24) {
                    VStack(alignment: .leading, spacing: 18) {
                        Text("Aktuální zátěž").font(.system(size: 13, weight: .semibold))
                        LoadRow(title: "CPU", value: monitor.samples.last?.cpuLoad, color: orange)
                        LoadRow(title: "GPU", value: monitor.samples.last?.gpuLoad, color: cyan)
                        LoadRow(title: "RAM", value: monitor.samples.last.map { $0.memory / monitor.totalMemory * 100 }, color: .purple)
                        Text(String(format: "Paměť %.1f / %.0f GiB · aktivní + wired + komprimovaná", monitor.samples.last?.memory ?? 0, monitor.totalMemory)).font(.system(size: 9)).foregroundStyle(.secondary)
                    }.frame(maxWidth: .infinity)
                    VStack(alignment: .leading, spacing: 15) {
                        Text("Další údaje").font(.system(size: 13, weight: .semibold))
                        HStack { Text("SSD / NAND"); Spacer(); Text(monitor.ssd == nil && monitor.economy ? "V detailech" : "\(degrees(monitor.ssd))C").monospacedDigit() }
                        HStack { Text("Chlazení"); Spacer(); Text("Pasivní").foregroundStyle(.secondary) }
                        Text("MacBook Air nemá ventilátor.").foregroundStyle(.secondary)
                    }.font(.system(size: 11)).frame(width: 195)
                }.padding(18).background(panel, in: RoundedRectangle(cornerRadius: 18))
                HStack {
                    Image(systemName: monitor.hot ? "exclamationmark.triangle.fill" : "bell").foregroundStyle(monitor.hot ? .orange : .secondary)
                    Text(monitor.hot ? "Teplota překročila tvůj práh" : "Zvýraznit teplotu od").font(.system(size: 12))
                    Stepper(value: $monitor.threshold, in: 60...110, step: 5) { Text("\(Int(monitor.threshold)) °C").font(.system(size: 12, weight: .semibold, design: .monospaced)) }.frame(width: 110)
                    Spacer()
                    Button(action: toggleHUD) { Label(monitor.pinned ? "Skrýt miniokno" : "Miniokno nad aplikacemi", systemImage: "pin") }.controlSize(.small)
                }
                VStack(alignment: .leading, spacing: 12) {
                    Toggle("Úsporné načítání · každých 5 s", isOn: $monitor.economy)
                    Text("CPU, GPU a baterie se měří průběžně. Ostatní čidla jen v otevřených detailech; zátěž a RAM jen v přehledu.").font(.system(size: 10)).foregroundStyle(.secondary)
                    Toggle("Průhledné miniokno · jen malé číslo", isOn: $monitor.minimalist)
                    Picker("Údaj v průhledném miniokně", selection: $monitor.hudMetric) {
                        Text("CPU").tag("CPU"); Text("GPU").tag("GPU"); Text("Baterie °C").tag("Baterie"); Text("Baterie W").tag("Výkon baterie"); Text("Adaptér W").tag("Příkon adaptéru"); Text("Obojí W").tag("Adaptér + baterie")
                    }.pickerStyle(.segmented)
                }.font(.system(size: 12)).padding(14).background(panel, in: RoundedRectangle(cornerRadius: 12))
                DisclosureGroup(isExpanded: $monitor.details) {
                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                        ForEach(monitor.readings) { r in
                            HStack { VStack(alignment: .leading, spacing: 3) { Text(r.key).font(.system(size: 11, design: .monospaced)); Text(r.group).font(.system(size: 9)).foregroundStyle(.secondary) }; Spacer(); Text(String(format: "%.1f °C", r.value)).font(.system(size: 11, design: .monospaced)) }.padding(9).background(panel, in: RoundedRectangle(cornerRadius: 8))
                        }
                    }.padding(.top, 10)
                } label: { Text("Všechna čidla · rozbalením načíst detaily (\(monitor.readings.count))").font(.system(size: 12)) }
                if !monitor.connected { Text("AppleSMC není dostupné. Teploty nelze přečíst; aplikaci spusť přímo v macOS mimo vývojový sandbox.").font(.system(size: 11)).foregroundStyle(.orange) }
                Text("CPU/GPU jsou maxima dostupných čidel dané oblasti; přesné umístění Apple veřejně nepopisuje. Přerušovaná čára je tvůj práh upozornění, nikoli limit výrobce. Historie zůstává v paměti nejvýše 2 hodiny.").font(.system(size: 10)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button("Export CSV…") { monitor.export() }
                    Button("Nová relace") { monitor.reset() }
                    Spacer()
                    Text("LOKÁLNĚ · BEZ ÚČTU").font(.system(size: 9, design: .monospaced)).tracking(1).foregroundStyle(.tertiary)
                }.controlSize(.small)
            }.padding(26)
        }.frame(minWidth: 700, idealWidth: 750, minHeight: 700).background(canvas).preferredColorScheme(.dark)
    }
}
struct HUD: View {
    @ObservedObject var monitor: Monitor
    let close: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack { Circle().fill(monitor.thermalColor).frame(width: 6, height: 6); Text("THERMOBAR").font(.system(size: 9, weight: .semibold, design: .monospaced)).tracking(1); Spacer(); Button(action: close) { Image(systemName: "xmark") }.buttonStyle(.plain).foregroundStyle(.secondary) }
            HStack(spacing: 24) {
                VStack(alignment: .leading, spacing: 3) { Text("CPU").font(.system(size: 10)).foregroundStyle(.secondary); Text(degrees(monitor.cpu)).foregroundStyle(orange).font(.system(size: 32, weight: .medium, design: .rounded)) }
                VStack(alignment: .leading, spacing: 3) { Text("GPU").font(.system(size: 10)).foregroundStyle(.secondary); Text(degrees(monitor.gpu)).foregroundStyle(cyan).font(.system(size: 32, weight: .medium, design: .rounded)) }
                Spacer(minLength: 0)
            }.monospacedDigit()
            Text("Baterie  \(degrees(monitor.battery))C").font(.system(size: 12, weight: .medium, design: .monospaced)).foregroundStyle(.mint)
            Text("\(monitor.power?.direction ?? "Baterie")  \(watts(monitor.power?.battery, signed: true))").font(.system(size: 11, weight: .medium, design: .monospaced)).foregroundStyle(.mint)
            Text("Adaptér / USB‑C  \(watts(monitor.power?.adapter))").font(.system(size: 11, weight: .medium, design: .monospaced)).foregroundStyle(cyan)
            if monitor.hot { Text("Překročen práh \(Int(monitor.threshold)) °C").font(.system(size: 10)).foregroundStyle(.orange) }
        }.padding(16).frame(width: 242).background(canvas.opacity(0.96)).preferredColorScheme(.dark)
    }
}

struct MinimalHUD: View {
    @ObservedObject var monitor: Monitor
    var body: some View {
        Group {
            if monitor.hudCombined {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 5) { Text("IN").font(.system(size: 10, weight: .bold)); Spacer(); Text(watts(monitor.power?.adapter)) }
                    HStack(spacing: 5) { Text("BAT").font(.system(size: 10, weight: .bold)); Spacer(); Text(watts(monitor.power?.battery, signed: true)) }
                }.font(.system(size: 18, weight: .semibold, design: .rounded)).padding(.horizontal, 6)
            } else {
                Text(monitor.hudText).font(.system(size: 22, weight: .semibold, design: .rounded))
            }
        }.monospacedDigit()
            .foregroundStyle(!monitor.hudIsPower && monitor.hudMetric != "Baterie" && monitor.hot ? Color.orange : Color.white)
            .shadow(color: .black, radius: 2).shadow(color: .black, radius: 1)
            .frame(width: monitor.hudWidth, height: monitor.hudHeight)
            .contentShape(Rectangle())
            .help("\(monitor.hudMetric) · IN = příkon adaptéru, BAT = + nabíjení / − vybíjení · přesun tažením")
    }
}

// SwiftUI consumes mouse events over labels, so background dragging alone is
// insufficient for a borderless panel. Handle the drag across the whole panel.
final class DraggablePanel: NSPanel {
    var hasCloseButton = true
    private var dragStart: NSPoint?
    private var originalOrigin: NSPoint?
    override func sendEvent(_ event: NSEvent) {
        if event.type == .leftMouseDown, let contentView {
            let point = event.locationInWindow
            let closeArea = NSRect(x: contentView.bounds.width - 44,
                                   y: contentView.bounds.height - 44,
                                   width: 44, height: 44)
            if !hasCloseButton || !closeArea.contains(point) {
                dragStart = convertPoint(toScreen: point)
                originalOrigin = frame.origin
                return
            }
        }
        if event.type == .leftMouseDragged, let start = dragStart, let origin = originalOrigin {
            let current = convertPoint(toScreen: event.locationInWindow)
            setFrameOrigin(NSPoint(x: origin.x + current.x - start.x, y: origin.y + current.y - start.y))
            return
        }
        if event.type == .leftMouseUp, dragStart != nil {
            dragStart = nil
            originalOrigin = nil
            return
        }
        super.sendEvent(event)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    let monitor = Monitor()
    var status: NSStatusItem!
    var window: NSWindow!
    var hud: NSPanel?
    var minimalMenu: NSMenuItem!
    var economyMenu: NSMenuItem!
    func applicationDidFinishLaunching(_ notification: Notification) {
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: "cz.local.ThermoBar").filter { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }
        if let other = others.first { other.activate(options: []); NSApp.terminate(nil); return }
        status = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        status.button?.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        let menu = NSMenu()
        menu.addItem(withTitle: "Otevřít přehled", action: #selector(showWindow), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Zobrazit / skrýt miniokno", action: #selector(toggleHUD), keyEquivalent: "").target = self
        minimalMenu = menu.addItem(withTitle: "Průhledné miniokno · jen číslo", action: #selector(toggleMinimal), keyEquivalent: "")
        minimalMenu.target = self
        economyMenu = menu.addItem(withTitle: "Úsporné načítání (5 s)", action: #selector(toggleEconomy), keyEquivalent: "")
        economyMenu.target = self
        let metricMenu = NSMenu()
        for name in ["CPU", "GPU", "Baterie", "Výkon baterie", "Příkon adaptéru", "Adaptér + baterie"] {
            let item = metricMenu.addItem(withTitle: name, action: #selector(selectMetric(_:)), keyEquivalent: "")
            item.target = self
        }
        let metricItem = menu.addItem(withTitle: "Údaj v průhledném miniokně", action: nil, keyEquivalent: "")
        metricItem.submenu = metricMenu
        menu.addItem(.separator())
        menu.addItem(withTitle: "Ukončit ThermoBar", action: #selector(quit), keyEquivalent: "q").target = self
        status.menu = menu
        monitor.onUpdate = { [weak self] in
            guard let self else { return }
            self.status.button?.title = "\(self.monitor.hot ? "⚠ " : "")CPU \(degrees(self.monitor.cpu))"
            self.minimalMenu.state = self.monitor.minimalist ? .on : .off
            self.economyMenu.state = self.monitor.economy ? .on : .off
            for item in metricMenu.items { item.state = item.title == self.monitor.hudMetric ? .on : .off }
            self.status.button?.toolTip = "CPU \(degrees(self.monitor.cpu))C · GPU \(degrees(self.monitor.gpu))C · Baterie \(degrees(self.monitor.battery))C\n\(self.monitor.power?.direction ?? "Baterie"): \(watts(self.monitor.power?.battery, signed: true)) · Adaptér: \(watts(self.monitor.power?.adapter))\n\(self.monitor.thermalText)"
        }
        window = NSWindow(contentRect: NSRect(x: 0,y: 0,width: 750,height: 850), styleMask: [.titled,.closable,.miniaturizable,.resizable], backing: .buffered, defer: false)
        monitor.onHUDChange = { [weak self] in self?.rebuildHUD() }
        window.delegate = self
        window.title = "ThermoBar · Teploty Macu"
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 710,height: 600)
        window.contentView = NSHostingView(rootView: Dashboard(monitor: monitor, toggleHUD: { [weak self] in self?.toggleHUD() }))
        window.center()
        showWindow()
    }
    @objc func showWindow() { monitor.dashboardVisible = true; window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true) }
    func windowWillClose(_ notification: Notification) { monitor.dashboardVisible = false }
    func windowDidMiniaturize(_ notification: Notification) { monitor.dashboardVisible = false }
    func windowDidDeminiaturize(_ notification: Notification) { monitor.dashboardVisible = true }
    func windowDidMove(_ notification: Notification) {
        guard let panel = notification.object as? DraggablePanel, panel.isVisible else { return }
        UserDefaults.standard.set(panel.frame.minX, forKey: "hudX")
        UserDefaults.standard.set(panel.frame.maxY, forKey: "hudTop")
    }
    @objc func toggleMinimal() { monitor.minimalist.toggle() }
    @objc func toggleEconomy() { monitor.economy.toggle() }
    @objc func selectMetric(_ sender: NSMenuItem) { monitor.hudMetric = sender.title }
    func rebuildHUD() {
        guard let hud else { return }
        let visible = hud.isVisible
        let origin = NSPoint(x: hud.frame.minX, y: hud.frame.maxY)
        hud.orderOut(nil)
        self.hud = nil
        if visible { toggleHUD(); self.hud?.setFrameTopLeftPoint(origin) }
    }
    @objc func toggleHUD() {
        if let hud, hud.isVisible { hud.orderOut(nil); monitor.pinned = false; return }
        if hud == nil {
            let p = DraggablePanel(contentRect: NSRect(x: 0,y: 0,width: 274,height: 150), styleMask: [.borderless,.nonactivatingPanel], backing: .buffered, defer: false)
            p.hasCloseButton = !monitor.minimalist
            p.level = .floating
            p.collectionBehavior = [.canJoinAllSpaces,.fullScreenAuxiliary]
            p.isMovableByWindowBackground = false
            p.hidesOnDeactivate = false
            p.isOpaque = false
            p.backgroundColor = .clear
            p.hasShadow = !monitor.minimalist
            if monitor.minimalist {
                p.contentView = NSHostingView(rootView: MinimalHUD(monitor: monitor))
                p.setContentSize(NSSize(width: monitor.hudWidth, height: monitor.hudHeight))
            } else {
                let view = NSHostingView(rootView: HUD(monitor: monitor, close: { [weak self] in self?.toggleHUD() }))
                view.wantsLayer = true; view.layer?.cornerRadius = 16; view.layer?.masksToBounds = true
                p.contentView = view
                p.setContentSize(NSSize(width: 274, height: 210))
            }
            if let screen = NSScreen.main { p.setFrameTopLeftPoint(NSPoint(x: screen.visibleFrame.maxX - 295,y: screen.visibleFrame.maxY - 20)) }
            if let x = UserDefaults.standard.object(forKey: "hudX") as? Double,
               let top = UserDefaults.standard.object(forKey: "hudTop") as? Double,
               x.isFinite, top.isFinite {
                let candidate = NSRect(x: x, y: top - p.frame.height, width: p.frame.width, height: p.frame.height)
                if NSScreen.screens.contains(where: { $0.visibleFrame.contains(candidate) }) {
                    p.setFrameTopLeftPoint(NSPoint(x: x, y: top))
                }
            }
            p.delegate = self
            hud = p
        }
        hud?.orderFrontRegardless(); monitor.pinned = true
    }
    @objc func quit() { NSApp.terminate(nil) }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { showWindow(); return true }
}

if CommandLine.arguments.contains("--self-test") {
    let monitor = Monitor()
    monitor.dashboardVisible = true
    RunLoop.main.run(until: Date().addingTimeInterval(11))
    let csv = monitor.csv()
    let rows = csv.split(separator: "\n")
    let success = monitor.connected && monitor.readings.count > 0 && monitor.samples.count >= 2 && monitor.cpu != nil && monitor.gpu != nil && monitor.power?.battery != nil && monitor.samples.last?.cpuLoad != nil && rows.count == monitor.samples.count + 1 && rows.allSatisfy { $0.split(separator: ",", omittingEmptySubsequences: false).count == 11 }
    print("Live integration: \(success ? "PASS" : "FAIL") · \(monitor.readings.count) sensors · \(monitor.samples.count) samples · \(rows.count - 1) CSV rows")
    print("Power: \(monitor.power?.direction ?? "—") \(watts(monitor.power?.battery, signed: true)) · Adapter \(watts(monitor.power?.adapter))")
    print("Battery \(degrees(monitor.battery))C · CPU \(degrees(monitor.cpu))C · GPU \(degrees(monitor.gpu))C · CPU load \(percent(monitor.samples.last?.cpuLoad)) · GPU load \(percent(monitor.samples.last?.gpuLoad))")
    if let index = CommandLine.arguments.firstIndex(of: "--csv"), CommandLine.arguments.count > index+1 { try csv.write(toFile: CommandLine.arguments[index+1], atomically: true, encoding: .utf8) }
    exit(success ? 0 : 1)
} else if CommandLine.arguments.contains("--diagnostics") {
    let open = sensor_open() != 0
    var readings: [String: Double] = [:]
    if open {
        for i in 0..<sensor_count() {
            var key = [CChar](repeating: 0, count: 5)
            if sensor_key(Int32(i), &key) != 0 { let name = String(cString: key); if name.hasPrefix("T"), let v = valid(sensor_read(name)), v > 0, v < 130 { readings[name] = v } }
        }
    }
    let report: [String: Any] = ["smcConnected": open, "temperatureSensors": readings, "gpuLoad": valid(gpu_usage()) as Any? ?? NSNull(), "memoryGiB": memory_used()/1_073_741_824]
    if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted,.sortedKeys]), let s = String(data: data, encoding: .utf8) { print(s) }
    sensor_close()
} else {
    let application = NSApplication.shared
    application.setActivationPolicy(.accessory)
    let delegate = AppDelegate()
    application.delegate = delegate
    application.run()
}
