import Foundation
import Testing

@testable import ThermoBar

struct SamplerTests {
    private let config = PollConfiguration(interval: 5, readAll: false, readLoad: true)
    private let start = Date(timeIntervalSince1970: 1_000)

    @Test func initiallyUnavailableSensorRecoversWithoutRestart() async {
        let sampler = SensorSampler(provider: FakeSensorProvider())
        let first = await sampler.sample(config, at: start)
        #expect(!first.readings.contains { $0.group == .battery })
        let recovered = await sampler.sample(config, at: start.addingTimeInterval(5))
        #expect(recovered.readings.first { $0.group == .battery }?.value == 35)
        #expect(!recovered.readings.contains { $0.group == .storage })
        let details = await sampler.sample(
            PollConfiguration(interval: 5, readAll: true, readLoad: true), at: start.addingTimeInterval(10))
        #expect(details.readings.contains { $0.group == .storage })
    }

    @Test func incompleteDiscoveryIsRetried() async {
        let sampler = SensorSampler(provider: FakeSensorProvider(failFirstDiscovery: true))
        #expect(!(await sampler.sample(config, at: start)).connected)
        let next = await sampler.sample(config, at: start.addingTimeInterval(5))
        #expect(next.connected)
        #expect(next.readings.contains { $0.group == .battery })
    }

    @Test func disconnectedSensorsAreReopenedWithoutStaleTemperatures() async {
        let sampler = SensorSampler(provider: FakeSensorProvider(disconnectOnSecondSample: true))
        #expect((await sampler.sample(config, at: start)).connected)
        let disconnected = await sampler.sample(config, at: start.addingTimeInterval(5))
        #expect(!disconnected.connected)
        #expect(disconnected.readings.isEmpty)
        let recovered = await sampler.sample(config, at: start.addingTimeInterval(10))
        #expect(recovered.connected)
        #expect(!recovered.readings.isEmpty)
    }

    @Test func loadIsPrimedAfterPauseAndSleep() async {
        let sampler = SensorSampler(provider: FakeSensorProvider())
        #expect((await sampler.sample(config, at: start)).cpuLoad == nil)
        #expect((await sampler.sample(config, at: start.addingTimeInterval(5))).cpuLoad == 25)
        let hidden = PollConfiguration(interval: 5, readAll: false, readLoad: false)
        let paused = await sampler.sample(hidden, at: start.addingTimeInterval(10))
        #expect(paused.cpuLoad == nil)
        #expect(paused.gpuLoad == nil)
        #expect(paused.memory.isNaN)
        #expect((await sampler.sample(config, at: start.addingTimeInterval(15))).cpuLoad == nil)
        #expect((await sampler.sample(config, at: start.addingTimeInterval(20))).cpuLoad == 25)
        #expect((await sampler.sample(config, at: start.addingTimeInterval(300))).cpuLoad == nil)
        #expect((await sampler.sample(config, at: start.addingTimeInterval(305))).cpuLoad == 25)
    }
}
