import Foundation
import Darwin
import SystemConfiguration

struct SystemReading {
    var interface = "—"
    var download: Double?
    var upload: Double?
    var cpu: Double?
    var memoryUsed: UInt64 = 0
    var memoryTotal: UInt64 = ProcessInfo.processInfo.physicalMemory
    var diskTotal: Int64 = 0
    var diskAvailable: Int64 = 0
    var history: [Double] = []
    var json: [String: Any] {
        ["interface": interface, "download": download.map { $0 as Any } ?? NSNull(),
         "upload": upload.map { $0 as Any } ?? NSNull(), "cpu": cpu.map { $0 as Any } ?? NSNull(),
         "memoryUsed": memoryUsed, "memoryTotal": memoryTotal,
         "diskTotal": diskTotal, "diskAvailable": diskAvailable, "history": history]
    }
}

final class SystemSampler {
    private var lastNetwork: (name: String, input: UInt64, output: UInt64, time: TimeInterval)?
    private var lastCPU: [UInt32]?
    private var lastDisk = Date.distantPast
    private var reading = SystemReading()
    var preferredInterface: String = ""

    func reset() { lastNetwork = nil; lastCPU = nil; reading.history = []; lastDisk = .distantPast }
    func sample() -> SystemReading {
        sampleNetwork(); sampleCPU(); sampleMemory()
        if Date().timeIntervalSince(lastDisk) >= 60 { sampleDisk(); lastDisk = Date() }
        return reading
    }
    func refreshDisk() { lastDisk = .distantPast }

    static func counterDelta(_ current: UInt64, _ previous: UInt64) -> UInt64? {
        if current >= previous { return current - previous }
        // getifaddrs exposes the legacy 32-bit interface byte counters.
        if previous > 0xf0000000 && current < 0x10000000 { return (1 << 32) - previous + current }
        return nil
    }
    static func speed(current: UInt64, previous: UInt64, elapsed: TimeInterval) -> Double? {
        guard elapsed > 0, elapsed <= 10, let delta = counterDelta(current, previous) else { return nil }
        return Double(delta) / elapsed
    }
    private func primaryInterface() -> String? {
        guard let store = SCDynamicStoreCreate(nil, "DeskKit" as CFString, nil, nil) else { return nil }
        for key in ["State:/Network/Global/IPv4", "State:/Network/Global/IPv6"] {
            if let state = SCDynamicStoreCopyValue(store, key as CFString) as? [String: Any],
               let name = state["PrimaryInterface"] as? String { return name }
        }
        return nil
    }
    private func sampleNetwork() {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { reading.download = nil; reading.upload = nil; return }
        defer { freeifaddrs(first) }
        var counters: [String: (UInt64, UInt64)] = [:]
        var next: UnsafeMutablePointer<ifaddrs>? = first
        while let current = next {
            let item = current.pointee; next = item.ifa_next
            guard item.ifa_addr?.pointee.sa_family == UInt8(AF_LINK),
                  item.ifa_flags & UInt32(IFF_UP) != 0,
                  item.ifa_flags & UInt32(IFF_LOOPBACK) == 0,
                  let data = item.ifa_data else { continue }
            let stats = data.assumingMemoryBound(to: if_data.self).pointee
            counters[String(cString: item.ifa_name)] = (UInt64(stats.ifi_ibytes), UInt64(stats.ifi_obytes))
        }
        let automatic = primaryInterface()
        let name = preferredInterface.isEmpty ? (automatic ?? "") : preferredInterface
        guard let counts = counters[name] else {
            reading.interface = name.isEmpty ? "未连接" : name
            reading.download = nil; reading.upload = nil; lastNetwork = nil; return
        }
        let now = ProcessInfo.processInfo.systemUptime
        reading.interface = name
        if let last = lastNetwork, last.name == name {
            reading.download = Self.speed(current: counts.0, previous: last.input, elapsed: now - last.time)
            reading.upload = Self.speed(current: counts.1, previous: last.output, elapsed: now - last.time)
        } else { reading.download = nil; reading.upload = nil }
        lastNetwork = (name, counts.0, counts.1, now)
        if let speed = reading.download { reading.history.append(speed); reading.history = Array(reading.history.suffix(45)) }
    }
    private func sampleCPU() {
        var info = host_cpu_load_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info_data_t>.size / MemoryLayout<integer_t>.size)
        let status = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count) }
        }
        guard status == KERN_SUCCESS else { reading.cpu = nil; return }
        let ticks = [info.cpu_ticks.0, info.cpu_ticks.1, info.cpu_ticks.2, info.cpu_ticks.3]
        if let previous = lastCPU {
            let delta = zip(ticks, previous).map { UInt64($0 &- $1) }
            let total = delta.reduce(0, +)
            reading.cpu = total > 0 ? Double(total - delta[Int(CPU_STATE_IDLE)]) / Double(total) * 100 : 0
        }
        lastCPU = ticks
    }
    private func sampleMemory() {
        var info = vm_statistics64_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        let status = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count) }
        }
        guard status == KERN_SUCCESS else { return }
        let pages = Int64(info.active_count) + Int64(info.inactive_count) + Int64(info.speculative_count)
            + Int64(info.wire_count) + Int64(info.compressor_page_count)
            - Int64(info.purgeable_count) - Int64(info.external_page_count)
        reading.memoryUsed = min(reading.memoryTotal, UInt64(max(0, pages)) * UInt64(getpagesize()))
    }
    private func sampleDisk() {
        guard let values = try? URL(fileURLWithPath: NSHomeDirectory()).resourceValues(forKeys: [.volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey]) else { return }
        reading.diskTotal = Int64(values.volumeTotalCapacity ?? 0)
        reading.diskAvailable = values.volumeAvailableCapacityForImportantUsage ?? 0
    }
}
