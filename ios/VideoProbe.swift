import Foundation

/// Reads values the way FFprobe prints them.
enum VideoProbe {

    /// The stream's average frame rate, or failing that the rate its timestamps are based on
    /// (both from the file), and 30 only if the file gives neither.
    static func frameRate(average: String?, base: String?) -> Double {
        let rate = parseRate(average)
        if rate > 0 { return rate }
        let baseRate = parseRate(base)
        return baseRate > 0 ? baseRate : 30.0
    }

    /// `"30000/1001"` or `"30"`; 0 for `"0/0"`, `"N/A"` and anything else unusable.
    static func parseRate(_ rate: String?) -> Double {
        guard let rate = rate else { return 0 }
        let parts = rate.split(separator: "/").map { Double($0.trimmingCharacters(in: .whitespaces)) ?? 0 }
        if parts.count == 1 { return max(0, parts[0]) }
        guard parts.count == 2, parts[0] > 0, parts[1] > 0 else { return 0 }
        return parts[0] / parts[1]
    }

    /// `key=value` lines, as printed by `-of default=noprint_wrappers=1`.
    static func keyValues(_ output: String) -> [String: String] {
        var values: [String: String] = [:]
        for line in output.split(separator: "\n") {
            guard let equals = line.firstIndex(of: "=") else { continue }
            let key = line[..<equals].trimmingCharacters(in: .whitespaces)
            values[key] = line[line.index(after: equals)...].trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return values
    }
}
