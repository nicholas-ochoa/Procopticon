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

    func testCoreTypes() throws {
        var levels: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname("hw.nperflevels", &levels, &size, nil, 0) == 0, levels > 1 else {
            throw XCTSkip("One core type")
        }
        let m = MachineInfo.current
        XCTAssertEqual(m.coreTypes.count, m.logicalCores)
        // The device tree names every core, with the perflevels' names.
        let fromTree = MachineInfo.deviceTreeCoreTypes(count: m.logicalCores, levelNames: ["Performance", "Efficiency"])
        XCTAssertEqual(fromTree, m.coreTypes)
        XCTAssertEqual(fromTree?.filter { $0 == "Performance" }.count, m.performanceCores)
        XCTAssertNil(MachineInfo.deviceTreeCoreTypes(count: m.logicalCores + 1, levelNames: []))
    }
}
