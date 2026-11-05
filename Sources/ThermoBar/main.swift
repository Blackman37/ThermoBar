import AppKit
import SensorBridge

if CommandLine.arguments.contains("--self-test") {
    let monitor = Monitor()
    monitor.dashboardVisible = true
    RunLoop.main.run(until: Date().addingTimeInterval(11))
    let csv = monitor.csv()
    let rows = csv.split(separator: "\n")
    let success =
        monitor.connected && monitor.readings.count > 0 && monitor.samples.count >= 2 && monitor.cpu != nil
        && monitor.gpu != nil && monitor.power?.battery != nil && monitor.samples.last?.cpuLoad != nil
        && rows.count == monitor.samples.count + 1
        && rows.allSatisfy { $0.split(separator: ",", omittingEmptySubsequences: false).count == 11 }
    print(
        "Live integration: \(success ? "PASS" : "FAIL") · \(monitor.readings.count) sensors · \(monitor.samples.count) samples · \(rows.count - 1) CSV rows"
    )
    print(
        "Power: \(monitor.power?.direction ?? "—") \(watts(monitor.power?.battery, signed: true)) · Adapter \(watts(monitor.power?.adapter))"
    )
    print(
        "Battery \(degrees(monitor.battery))C · CPU \(degrees(monitor.cpu))C · GPU \(degrees(monitor.gpu))C · CPU load \(percent(monitor.samples.last?.cpuLoad)) · GPU load \(percent(monitor.samples.last?.gpuLoad))"
    )
    if let index = CommandLine.arguments.firstIndex(of: "--csv"), CommandLine.arguments.count > index + 1 {
        do {
            try csv.write(toFile: CommandLine.arguments[index + 1], atomically: true, encoding: .utf8)
        } catch {
            fputs("CSV export failed: \(error)\n", stderr)
            exit(1)
        }
    }
    exit(success ? 0 : 1)
} else if CommandLine.arguments.contains("--diagnostics") {
    Task { @MainActor in
        let sampler = SensorSampler()
        let snapshot = await sampler.sample(PollConfiguration(interval: 5, readAll: true, readLoad: true))
        let report: [String: Any] = [
            "smcConnected": snapshot.connected,
            "temperatureSensors": Dictionary(
                uniqueKeysWithValues: snapshot.readings.map { ($0.key, $0.value) }),
            "gpuLoad": snapshot.gpuLoad as Any? ?? NSNull(),
            "memoryGiB": valid(snapshot.memory) as Any? ?? NSNull(),
        ]
        do {
            let data = try JSONSerialization.data(
                withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            print(String(decoding: data, as: UTF8.self))
            exit(0)
        } catch {
            fputs("Diagnostics failed: \(error)\n", stderr)
            exit(1)
        }
    }
    RunLoop.main.run()
} else {
    let application = NSApplication.shared
    application.setActivationPolicy(.accessory)
    let delegate = AppDelegate()
    application.delegate = delegate
    application.run()
}
