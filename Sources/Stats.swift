import Foundation
import IOKit.ps
import IOKit
import Darwin
import SystemConfiguration
import CoreWLAN

// MARK: - 系统状态数据

struct SystemStats: Sendable {
    var cpuBrand = ""
    var coreCount = 0
    var cpuPercent = 0.0
    var cpuPerCore = [Double]()
    var memoryUsedGB = 0.0
    var memoryTotalGB = 0.0
    var memoryPercent = 0.0
    var diskUsedGB = 0.0
    var diskTotalGB = 0.0
    var diskPercent = 0.0
    var batteryPercent: Double? = nil
    var batteryCharging = false
    var batteryPlugged = false
    var hasBattery = false
    var batteryMinutesRemaining: Int? = nil
    var batteryPowerWatts: Double? = nil
    var networkDownBps: UInt64 = 0
    var networkUpBps: UInt64 = 0
    var networkName = ""
    var ipAddress = ""
    var loadAverage = (0.0, 0.0, 0.0)
    var uptimeText = ""

    /// 纯文本摘要，供命令行验证使用
    var summary: String {
        let mem = String(format: "%.1f / %.1f GB", memoryUsedGB, memoryTotalGB)
        let disk = String(format: "%.1f / %.1f GB", diskUsedGB, diskTotalGB)
        let batt: String
        if let p = batteryPercent {
            var suffix: String
            if batteryCharging {
                suffix = "charging"
            } else if let m = batteryMinutesRemaining {
                suffix = "\(m)min left"
            } else {
                suffix = batteryPlugged ? "AC" : "battery"
            }
            if let w = batteryPowerWatts, w != 0 {
                let power = String(format: "%.0fW", abs(w))
                if batteryCharging {
                    suffix += " \(power)"
                } else if !batteryPlugged {
                    suffix += " discharging \(power)"
                }
            }
            batt = String(format: "%.0f%% (%@)", p * 100, suffix)
        } else {
            batt = "none"
        }
        let net = String(format: "↓ %.1f MB/s  ↑ %.1f MB/s",
                         Double(networkDownBps) / 1_048_576,
                         Double(networkUpBps) / 1_048_576)
        return """
        CPU:      \(String(format: "%.0f", cpuPercent * 100))%  (\(coreCount) cores, \(cpuBrand))
        Memory:   \(String(format: "%.0f", memoryPercent * 100))% used  (\(mem))
        Disk:     \(String(format: "%.0f", diskPercent * 100))% used  (\(disk))
        Battery:  \(batt)
        Network:  \(net)  (\(networkName) · \(ipAddress))
        """
    }
}

// MARK: - 采样器

actor SystemStatsSampler {
    private let cpuBrand = readCPUBrand()
    private var previousCPUTicks = [UInt32]()
    private var previousNetwork: NetworkCounters?

    private struct NetworkCounters {
        let interface: String
        let inbound: UInt32
        let outbound: UInt32
        let time: TimeInterval
    }

    func sample() -> SystemStats {
        var s = SystemStats()
        s.cpuBrand = cpuBrand
        s.coreCount = ProcessInfo.processInfo.activeProcessorCount
        (s.cpuPercent, s.cpuPerCore) = cpuUsage()
        (s.memoryUsedGB, s.memoryTotalGB, s.memoryPercent) = Self.memoryUsage()
        (s.diskUsedGB, s.diskTotalGB, s.diskPercent) = Self.diskUsage()
        (s.batteryPercent, s.batteryCharging, s.batteryPlugged, s.hasBattery,
         s.batteryMinutesRemaining, s.batteryPowerWatts) = Self.batteryInfo()
        (s.networkDownBps, s.networkUpBps, s.networkName, s.ipAddress) = networkInfo()
        s.loadAverage = Self.loadAverage()
        s.uptimeText = Self.uptimeText()
        return s
    }

    // MARK: CPU

    private static func readCPUBrand() -> String {
        var size = 0
        guard sysctlbyname("machdep.cpu.brand_string", nil, &size, nil, 0) == 0, size > 0 else {
            return "Apple Silicon"
        }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname("machdep.cpu.brand_string", &buffer, &size, nil, 0) == 0 else {
            return "Apple Silicon"
        }
        let brand = String(decoding: buffer.prefix { $0 != 0 }.map(UInt8.init(bitPattern:)), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return brand.isEmpty ? "Apple Silicon" : brand
    }

    /// 返回 (总占用, 每核心占用)，均为 0...1
    private func cpuUsage() -> (Double, [Double]) {
        var numCPUs: natural_t = 0
        var cpuInfo: processor_info_array_t?
        var numCpuInfo: mach_msg_type_number_t = 0
        let host = mach_host_self()
        defer { mach_port_deallocate(mach_task_self_, host) }
        let result = host_processor_info(host, PROCESSOR_CPU_LOAD_INFO,
                                         &numCPUs, &cpuInfo, &numCpuInfo)
        guard result == KERN_SUCCESS, let info = cpuInfo else {
            return (0, [])
        }
        defer {
            vm_deallocate(mach_task_self_,
                          UInt(bitPattern: info),
                          vm_size_t(numCpuInfo) * vm_size_t(MemoryLayout<integer_t>.size))
        }

        let count = Int(numCPUs)
        let stateCount = Int(CPU_STATE_MAX)
        guard count > 0, count * stateCount <= Int(numCpuInfo) else { return (0, []) }
        let ticks = UnsafeBufferPointer(start: info, count: count * stateCount)
            .map { UInt32(bitPattern: $0) }
        defer { previousCPUTicks = ticks }

        var perCore = [Double](repeating: 0, count: count)
        guard previousCPUTicks.count == ticks.count else { return (0, perCore) }

        var totalBusy: UInt64 = 0
        var totalTicks: UInt64 = 0
        for i in 0..<count {
            let base = i * stateCount
            func delta(_ state: Int32) -> UInt64 {
                let index = base + Int(state)
                return UInt64(ticks[index] &- previousCPUTicks[index])
            }
            let busy = delta(CPU_STATE_USER) + delta(CPU_STATE_SYSTEM) + delta(CPU_STATE_NICE)
            let total = busy + delta(CPU_STATE_IDLE)
            totalBusy += busy
            totalTicks += total
            perCore[i] = total > 0 ? Double(busy) / Double(total) : 0
        }
        let percent = totalTicks > 0 ? Double(totalBusy) / Double(totalTicks) : 0
        return (percent, perCore)
    }

    // MARK: 内存

    static func memoryUsage() -> (Double, Double, Double) {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(
            MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size
        )
        let host = mach_host_self()
        defer { mach_port_deallocate(mach_task_self_, host) }
        let result = withUnsafeMutablePointer(to: &stats) { ptr in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { intPtr in
                host_statistics64(host, HOST_VM_INFO64, intPtr, &count)
            }
        }
        guard result == KERN_SUCCESS else { return (0, 0, 0) }

        var pageSize: vm_size_t = 0
        host_page_size(host, &pageSize)
        let ps = UInt64(pageSize)

        let active = UInt64(stats.active_count) * ps
        let wired = UInt64(stats.wire_count) * ps
        let compressed = UInt64(stats.compressor_page_count) * ps
        let used = active + wired + compressed
        let total = ProcessInfo.processInfo.physicalMemory
        let gb = 1_073_741_824.0
        let usedGB = Double(used) / gb
        let totalGB = Double(total) / gb
        let percent = total > 0 ? min(1, max(0, Double(used) / Double(total))) : 0
        return (usedGB, totalGB, percent)
    }

    // MARK: 存储

    static func diskUsage() -> (Double, Double, Double) {
        do {
            let attrs = try FileManager.default.attributesOfFileSystem(forPath: "/")
            let total = (attrs[.systemSize] as? NSNumber)?.uint64Value ?? 0
            let free = (attrs[.systemFreeSize] as? NSNumber)?.uint64Value ?? 0
            let used = total > free ? total - free : 0
            let gb = 1_073_741_824.0
            let percent = total > 0 ? min(1, max(0, Double(used) / Double(total))) : 0
            return (Double(used) / gb, Double(total) / gb, percent)
        } catch {
            return (0, 0, 0)
        }
    }

    // MARK: 电池

    static func batteryInfo() -> (Double?, Bool, Bool, Bool, Int?, Double?) {
        guard let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(snapshot)?.takeRetainedValue() as? [CFTypeRef]
        else {
            return (nil, false, false, false, nil, nil)
        }

        let currentKey = kIOPSCurrentCapacityKey as String
        let maxKey = kIOPSMaxCapacityKey as String
        let chargingKey = kIOPSIsChargingKey as String
        let externalKey = "ExternalConnected"
        let stateKey = kIOPSPowerSourceStateKey as String
        let acValue = kIOPSACPowerValue as String
        let timeKey = "TimeRemaining"
        let voltageKey = kIOPSVoltageKey as String
        // IOKit.ps 没有公开 Amperage 常量，且 Apple Silicon 上该字典也没有 Voltage，
        // 因此电流键用字面量兼容 "Amperage"/"Current" 两种写法，电压缺失时回退到 IORegistry。
        let amperageKey = "Amperage"
        let currentMAKey = "Current"

        for source in sources {
            guard let desc = IOPSGetPowerSourceDescription(snapshot, source)?
                .takeUnretainedValue() as? [String: Any]
            else { continue }
            guard let current = desc[currentKey] as? Int,
                  let capacity = desc[maxKey] as? Int, capacity > 0
            else { continue }

            let level = min(1, max(0, Double(current) / Double(capacity)))
            let charging = (desc[chargingKey] as? Bool) ?? false
            let external = (desc[externalKey] as? Bool) ?? false
            let state = desc[stateKey] as? String
            let plugged = external || state == acValue
            var minutes: Int? = nil
            if let seconds = desc[timeKey] as? Double, seconds > 0 {
                minutes = max(1, Int(seconds / 60))
            }
            // 功率 = 电压(mV) × 电流(mA) / 1_000_000，正值充电、负值放电
            var powerWatts: Double? = nil
            let amperage = (desc[amperageKey] as? NSNumber)?.doubleValue
                ?? (desc[currentMAKey] as? NSNumber)?.doubleValue
            let voltage = (desc[voltageKey] as? NSNumber)?.doubleValue
                ?? Self.batteryVoltageMillivolts().map(Double.init)
            if let voltage, let amperage {
                powerWatts = voltage * amperage / 1_000_000
            }
            return (level, charging, plugged, true, minutes, powerWatts)
        }
        return (nil, false, false, false, nil, nil)
    }

    /// 从 IORegistry 的 AppleSmartBattery 读取当前电池电压（mV）。
    /// IOKit 电源字典在 Apple Silicon 上不提供 Voltage，需要从电池服务兜底读取。
    private static func batteryVoltageMillivolts() -> Int? {
        guard let matching = IOServiceMatching("AppleSmartBattery") else { return nil }
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == KERN_SUCCESS
        else { return nil }
        defer { IOObjectRelease(iterator) }

        let service = IOIteratorNext(iterator)
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }

        guard let property = IORegistryEntryCreateCFProperty(
            service, "Voltage" as CFString, kCFAllocatorDefault, 0
        )?.takeRetainedValue() as? NSNumber else {
            return nil
        }
        return property.intValue
    }

    // MARK: 运行时间

    static func uptimeText() -> String {
        var boot = timeval()
        var size = MemoryLayout<timeval>.size
        var mib: [Int32] = [CTL_KERN, KERN_BOOTTIME]
        guard sysctl(&mib, 2, &boot, &size, nil, 0) == 0 else { return "" }
        let now = Date().timeIntervalSince1970
        let uptime = max(0, Int(now - Double(boot.tv_sec)))
        let days = uptime / 86400
        let hours = (uptime % 86400) / 3600
        let mins = (uptime % 3600) / 60
        if days > 0 { return "已运行 \(days)天\(hours)小时" }
        if hours > 0 { return "已运行 \(hours)小时\(mins)分" }
        return "已运行 \(mins)分钟"
    }

    // MARK: 负载均值 (1/5/15 分钟)

    static func loadAverage() -> (Double, Double, Double) {
        var avg = [Double](repeating: 0, count: 3)
        getloadavg(&avg, 3)
        return (avg[0], avg[1], avg[2])
    }

    // MARK: 网络

    private func networkInfo() -> (downBps: UInt64, upBps: UInt64, name: String, ip: String) {
        let primary = Self.primaryInterfaceName()

        var ifaddrPtr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddrPtr) == 0, let first = ifaddrPtr else {
            previousNetwork = nil
            return (0, 0, "", "")
        }
        defer { freeifaddrs(ifaddrPtr) }

        var fallback: (name: String, ip: String)?
        var preferred: (name: String, ip: String)?
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let current = cursor {
            let address = current.pointee
            cursor = address.ifa_next
            guard let socket = address.ifa_addr,
                  socket.pointee.sa_family == sa_family_t(AF_INET) else { continue }
            let name = String(cString: address.ifa_name)
            guard name != "lo0", !name.hasPrefix("awdl"), !name.hasPrefix("llw"),
                  !name.hasPrefix("utun") else { continue }
            guard let ip = Self.ipString(from: socket) else { continue }
            if name == primary {
                preferred = (name, ip)
                break
            }
            if fallback == nil { fallback = (name, ip) }
        }

        guard let active = preferred ?? fallback else {
            previousNetwork = nil
            return (0, 0, "", "")
        }

        var download: UInt64 = 0
        var upload: UInt64 = 0
        var counters: NetworkCounters?
        cursor = first
        while let current = cursor {
            let address = current.pointee
            cursor = address.ifa_next
            guard address.ifa_addr?.pointee.sa_family == sa_family_t(AF_LINK),
                  String(cString: address.ifa_name) == active.name,
                  let data = address.ifa_data?.assumingMemoryBound(to: if_data.self).pointee
            else { continue }
            counters = NetworkCounters(interface: active.name,
                                       inbound: data.ifi_ibytes, outbound: data.ifi_obytes,
                                       time: ProcessInfo.processInfo.systemUptime)
            break
        }
        // 接口切换或断开后重新建立基线，避免把不同接口的计数器相减。
        if let counters, let previousNetwork, counters.interface == previousNetwork.interface {
            let elapsed = counters.time - previousNetwork.time
            if elapsed > 0.1 {
                download = UInt64(Double(counters.inbound &- previousNetwork.inbound) / elapsed)
                upload = UInt64(Double(counters.outbound &- previousNetwork.outbound) / elapsed)
            }
        }
        previousNetwork = counters

        let wifi = CWWiFiClient.shared().interfaces()?.first { $0.interfaceName == active.name }
        let name: String
        if let ssid = wifi?.ssid(), !ssid.isEmpty {
            name = "Wi-Fi · \(ssid)"
        } else if wifi != nil {
            name = "Wi-Fi"
        } else if active.name.hasPrefix("en") {
            name = "以太网"
        } else {
            name = active.name
        }
        return (download, upload, name, active.ip)
    }

    private static func primaryInterfaceName() -> String {
        guard let store = SCDynamicStoreCreate(nil, "SystemWidget" as CFString, nil, nil),
              let value = SCDynamicStoreCopyValue(store, "State:/Network/Global/IPv4" as CFString),
              let dict = value as? [String: Any],
              let name = dict["PrimaryInterface"] as? String
        else {
            return ""
        }
        return name
    }

    private static func ipString(from address: UnsafePointer<sockaddr>) -> String? {
        var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        let result = getnameinfo(address,
                                 socklen_t(address.pointee.sa_len),
                                 &host,
                                 socklen_t(host.count),
                                 nil,
                                 0,
                                 NI_NUMERICHOST)
        guard result == 0 else { return nil }
        return host.withUnsafeBufferPointer { buffer in
            buffer.baseAddress.map { String(cString: $0) }
        }
    }
}
