import Foundation

enum NumstatParser {
    static func parse(_ raw: String) -> [String: (add: Int, del: Int)] {
        var result: [String: (add: Int, del: Int)] = [:]
        for line in raw.split(separator: "\n") {
            let parts = line.split(separator: "\t", maxSplits: 2)
            guard parts.count == 3 else { continue }
            let add = Int(parts[0]) ?? 0
            let del = Int(parts[1]) ?? 0
            let path = String(parts[2])
            result[path] = (add: add, del: del)
        }
        return result
    }
}
