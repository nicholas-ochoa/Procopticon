import XCTest
@testable import ProcopticonCore

final class SystemMonitorTests: XCTestCase {
    func testPerCoreKernelShare() {
        let monitor = SystemMonitor()
        var first = SystemSampler.sample()
        var second = first
        // Over the interval, core 0 spends 30 of 100 ticks in the kernel and 20 in user code.
        first.cpus = [CPUTicks(user: 0, system: 0, idle: 0, nice: 0)]
        second.cpus = [CPUTicks(user: 15, system: 30, idle: 50, nice: 5)]
        second.timestamp = first.timestamp + 1
        let processes = [ProcessKey: ProcessItem]().values
        monitor.update(first, processes: processes)
        monitor.update(second, processes: processes)
        XCTAssertEqual(monitor.perCore.first?.last, 50)
        XCTAssertEqual(monitor.perCoreKernel.first?.last, 30)
        XCTAssertEqual(monitor.perCoreKernel.count, monitor.perCore.count)
    }

    func testCoreTypesCoverEveryLogicalCPU() {
        let machine = MachineInfo.current
        // Empty on Macs with one core type.
        if !machine.coreTypes.isEmpty {
            XCTAssertEqual(machine.coreTypes.count, machine.logicalCores)
            XCTAssertGreaterThan(Set(machine.coreTypes).count, 1)
            XCTAssertFalse(machine.coreTypes.contains(""))
        }
    }
}
