import Foundation

enum CPUArch: String, Codable {
    case arm64
    case x86_64
}

/// Describes the Mac the app is running on; used to recommend release assets.
struct SystemInfo {
    let arch: CPUArch
    let runningUnderRosetta: Bool
    let osVersion: OperatingSystemVersion

    var osMajor: Int { osVersion.majorVersion }

    var osVersionString: String {
        var s = "\(osVersion.majorVersion).\(osVersion.minorVersion)"
        if osVersion.patchVersion > 0 { s += ".\(osVersion.patchVersion)" }
        return s
    }

    var archTitle: String { arch == .arm64 ? "Apple Silicon" : "Intel" }

    var summary: String { "\(archTitle) · macOS \(osVersionString)" }

    static func detect() -> SystemInfo {
        var arm64: Int32 = 0
        var size = MemoryLayout<Int32>.size
        let hasARM = sysctlbyname("hw.optional.arm64", &arm64, &size, nil, 0) == 0 && arm64 == 1

        var translated: Int32 = 0
        var tsize = MemoryLayout<Int32>.size
        let rosetta = sysctlbyname("sysctl.proc_translated", &translated, &tsize, nil, 0) == 0 && translated == 1

        return SystemInfo(
            arch: (hasARM || rosetta) ? .arm64 : .x86_64,
            runningUnderRosetta: rosetta,
            osVersion: ProcessInfo.processInfo.operatingSystemVersion
        )
    }
}
