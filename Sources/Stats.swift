import Foundation
import IOKit.ps
import Darwin

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

    /// 纯文本摘要，供命令行验证使用
    var summary: String {
        let mem = String(format: "%.1f / %.1f GB", memoryUsedGB, memoryTotalGB)
        let disk = String(format: "%.1f / %.1f GB", diskUsedGB, diskTotalGB)
        let batt: String
        if let p = batteryPercent {
            let suffix: String
            if batteryCharging {
                suffix = "charging"
            } else if let m = batteryMinutesRemaining {
                suffix = "\(m)min left"
            } else {
                suffix = batteryPlugged ? "AC" : "battery"
            }
            batt = String(format: "%.0f%% (%@)", p * 100, suffix)
        } else {
            batt = "none"
        }
        return """
        CPU:      \(String(format: "%.0f", cpuPercent * 100))%  (\(coreCount) cores, \(cpuBrand))
        Memory:   \(String(format: "%.0f", memoryPercent * 100))% used  (\(mem))
        Disk:     \(String(format: "%.0f", diskPercent * 100))% used  (\(disk))
        Battery:  \(batt)
        """
    }
}

// MARK: - 采样器

enum SystemStatsSampler {
    // CPU 负载需要前后两次采样做差值，这里保存上一次的计数器
    private static var lastBusy = [UInt64]()
    private static var lastTotal = [UInt64]()

    static func sample() -> SystemStats {
        var s = SystemStats()
        s.cpuBrand = Self.cpuBrand()
        s.coreCount = ProcessInfo.processInfo.activeProcessorCount
        (s.cpuPercent, s.cpuPerCore) = Self.cpuUsage()
        (s.memoryUsedGB, s.memoryTotalGB, s.memoryPercent) = Self.memoryUsage()
        (s.diskUsedGB, s.diskTotalGB, s.diskPercent) = Self.diskUsage()
        (s.batteryPercent, s.batteryCharging, s.batteryPlugged, s.hasBattery,
         s.batteryMinutesRemaining) = Self.batteryInfo()
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

    static func batteryInfo() -> (Double?, Bool, Bool, Bool, Int?) {
        guard let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(snapshot)?.takeRetainedValue() as? [CFTypeRef]
        else {
            return (nil, false, false, false, nil)
        }

        let currentKey = kIOPSCurrentCapacityKey as String
        let maxKey = kIOPSMaxCapacityKey as String
        let chargingKey = kIOPSIsChargingKey as String
        let externalKey = "ExternalConnected"
        let stateKey = kIOPSPowerSourceStateKey as String
        let acValue = kIOPSACPowerValue as String
        let timeKey = "TimeRemaining"

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
            return (level, charging, plugged, true, minutes)
        }
        return (nil, false, false, false, nil)
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
}
