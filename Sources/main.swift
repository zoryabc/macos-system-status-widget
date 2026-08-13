import Foundation

// 命令行验证工具：打印一次系统状态后退出
let stats = SystemStatsSampler.sample()
print(stats.summary)
