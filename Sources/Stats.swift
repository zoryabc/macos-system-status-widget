import Foundation
import IOKit.ps
import IOKit
import Darwin
import SystemConfiguration
import CoreWLAN

// MARK: - 系统状态数据

struct SystemStats {
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

enum SystemStatsSampler {
    // CPU 负载需要前后两次采样做差值，这里保存上一次的计数器
    private static var lastBusy = [UInt64]()
    private static var lastTotal = [UInt64]()
    // 网络速率同样需要前后两次采样
    private static var lastNetIn: UInt64 = 0
    private static var lastNetOut: UInt64 = 0
    private static var lastNetSample: TimeInterval = 0

    static func sample() -> SystemStats {
        var s = SystemStats()
        s.cpuBrand = Self.cpuBrand()
        s.coreCount = ProcessInfo.processInfo.activeProcessorCount
        (s.cpuPercent, s.cpuPerCore) = Self.cpuUsage()
        (s.memoryUsedGB, s.memoryTotalGB, s.memoryPercent) = Self.memoryUsage()
        (s.diskUsedGB, s.diskTotalGB, s.diskPercent) = Self.diskUsage()
        (s.batteryPercent, s.batteryCharging, s.batteryPlugged, s.hasBattery,
         s.batteryMinutesRemaining, s.batteryPowerWatts) = Self.batteryInfo()
        (s.networkDownBps, s.networkUpBps, s.networkName, s.ipAddress) = Self.networkInfo()
        return s
    }

    // MARK: CPU

    static func cpuBrand() -> String {
        var size = 0
        guard sysctlbyname("machdep.cpu.brand_string", nil, &size, nil, 0) == 0, size > 0 else {
            return "Apple Silicon"
        }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname("machdep.cpu.brand_string", &buffer, &size, nil, 0) == 0 else {
            return "Apple Silicon"
        }
        let brand = String(cString: buffer).trimmingCharacters(in: .whitespacesAndNewlines)
        return brand.isEmpty ? "Apple Silicon" : brand
    }

    /// 返回 (总占用, 每核心占用)，均为 0...1
    static func cpuUsage() -> (Double, [Double]) {
        var numCPUs: natural_t = 0
        var cpuInfo: processor_info_array_t?
        var numCpuInfo: mach_msg_type_number_t = 0
        let result = host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO,
                                         &numCPUs, &cpuInfo, &numCpuInfo)
        guard result == KERN_SUCCESS, let info = cpuInfo, numCPUs > 0 else {
            return (0, [])
        }
        defer {
            vm_deallocate(mach_task_self_,
                          UInt(bitPattern: info),
                          vm_size_t(numCpuInfo) * vm_size_t(MemoryLayout<integer_t>.size))
        }

        let count = Int(numCPUs)
        let stateCount = Int(CPU_STATE_MAX)
        var busy = [UInt64](repeating: 0, count: count)
        var total = [UInt64](repeating: 0, count: count)

        for i in 0..<count {
            let base = i * stateCount
            let user = UInt64(info[base + Int(CPU_STATE_USER)])
            let system = UInt64(info[base + Int(CPU_STATE_SYSTEM)])
            let nice = UInt64(info[base + Int(CPU_STATE_NICE)])
            let idle = UInt64(info[base + Int(CPU_STATE_IDLE)])
            busy[i] = user + system + nice
            total[i] = busy[i] + idle
        }

        var percent = 0.0
        var perCore = [Double](repeating: 0, count: count)
        if lastBusy.count == count, lastTotal.count == count {
            let totalDelta = total.reduce(0, +) - lastTotal.reduce(0, +)
            let busyDelta = busy.reduce(0, +) - lastBusy.reduce(0, +)
            if totalDelta > 0 {
                percent = min(1, max(0, Double(busyDelta) / Double(totalDelta)))
            }
            for i in 0..<count {
                let d = total[i] - lastTotal[i]
                if d > 0 {
                    perCore[i] = min(1, max(0, Double(busy[i] - lastBusy[i]) / Double(d)))
                }
            }
        }
        lastBusy = busy
        lastTotal = total
        return (percent, perCore)
    }

    // MARK: 内存

    static func memoryUsage() -> (Double, Double, Double) {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(
            MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size
        )
        let result = withUnsafeMutablePointer(to: &stats) { ptr in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { intPtr in
                host_statistics64(mach_host_self(), HOST_VM_INFO64, intPtr, &count)
            }
        }
        guard result == KERN_SUCCESS else { return (0, 0, 0) }

        var pageSize: vm_size_t = 0
        host_page_size(mach_host_self(), &pageSize)
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
        let uptime = Int(now - Double(boot.tv_sec))
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

    static func networkInfo() -> (downBps: UInt64, upBps: UInt64, name: String, ip: String) {
        let primary = primaryInterfaceName()

        var ifaddrPtr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddrPtr) == 0, let first = ifaddrPtr else {
            return (0, 0, "", "")
        }
        defer { freeifaddrs(ifaddrPtr) }

        var chosen = ""
        var fallback = ""
        var ip = ""

        // 第一遍：找主接口（或第一个可用的 en* 接口）的 IPv4 地址
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let ifa = cursor {
            let name = String(cString: ifa.pointee.ifa_name)
            let family = ifa.pointee.ifa_addr.pointee.sa_family
            if family == sa_family_t(AF_INET),
               name != "lo0",
               !name.hasPrefix("awdl"),
               !name.hasPrefix("llw"),
               !name.hasPrefix("utun") {
                if name == primary {
                    chosen = name
                    ip = ipString(from: ifa)
                } else if fallback.isEmpty && chosen.isEmpty {
                    fallback = name
                    ip = ipString(from: ifa)
                }
            }
            cursor = ifa.pointee.ifa_next
        }
        if chosen.isEmpty { chosen = fallback }

        // 第二遍：读取该接口的流量计数器
        var inBytes: UInt64 = 0
        var outBytes: UInt64 = 0
        var linkCursor: UnsafeMutablePointer<ifaddrs>? = first
        while let ifa = linkCursor {
            let name = String(cString: ifa.pointee.ifa_name)
            if name == chosen,
               ifa.pointee.ifa_addr.pointee.sa_family == sa_family_t(AF_LINK),
               let dataPtr = ifa.pointee.ifa_data {
                let data = dataPtr.assumingMemoryBound(to: if_data.self).pointee
                inBytes = UInt64(data.ifi_ibytes)
                outBytes = UInt64(data.ifi_obytes)
            }
            linkCursor = ifa.pointee.ifa_next
        }

        // 计算速率
        let now = ProcessInfo.processInfo.systemUptime
        var down: UInt64 = 0
        var up: UInt64 = 0
        if lastNetSample > 0 {
            let dt = now - lastNetSample
            if dt > 0.1 {
                down = UInt64(Double(deltaCounter(inBytes, lastNetIn)) / dt)
                up = UInt64(Double(deltaCounter(outBytes, lastNetOut)) / dt)
            }
        }
        lastNetIn = inBytes
        lastNetOut = outBytes
        lastNetSample = now

        // 网络名称
        let ssid = ssidName(interface: chosen)
        let name: String
        if !ssid.isEmpty {
            name = "Wi-Fi · \(ssid)"
        } else if chosen.hasPrefix("en") {
            name = "以太网"
        } else {
            name = chosen
        }

        return (down, up, name, ip)
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

    private static func ipString(from ifa: UnsafeMutablePointer<ifaddrs>) -> String {
        var addr = ifa.pointee.ifa_addr.pointee
        var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        let result = getnameinfo(&addr,
                                 socklen_t(ifa.pointee.ifa_addr.pointee.sa_len),
                                 &host,
                                 socklen_t(host.count),
                                 nil,
                                 0,
                                 NI_NUMERICHOST)
        guard result == 0 else { return "" }
        return String(cString: host)
    }

    private static func deltaCounter(_ current: UInt64, _ previous: UInt64) -> UInt64 {
        if current >= previous { return current - previous }
        // 处理 32 位计数器回绕
        return current + 4_294_967_296 - previous
    }

    private static func ssidName(interface: String) -> String {
        guard !interface.isEmpty else { return "" }
        return CWWiFiClient.shared().interface(withName: interface)?.ssid() ?? ""
    }
}
