import Foundation
import AlasFoundation
import AlasModel
import AlasPlatform
import AlasFeatures
import AlasCode

package func metadataObject(_ value: AnyCodable?) -> [String: AnyCodable]? {
    if let dict = value?.value as? [String: AnyCodable] { return dict }
    if let dict = value?.value as? [String: Any] {
        return dict.mapValues { raw in
            (raw as? AnyCodable) ?? AnyCodable(raw)
        }
    }
    if let dict = value?.value as? NSDictionary {
        var result: [String: AnyCodable] = [:]
        for (rawKey, rawValue) in dict {
            guard let key = rawKey as? String else { continue }
            result[key] = (rawValue as? AnyCodable) ?? AnyCodable(rawValue)
        }
        return result
    }
    return nil
}

package func boolValue(_ value: AnyCodable?) -> Bool? {
    guard let raw = value?.value, !(raw is NSNull) else { return nil }
    if let bool = raw as? Bool { return bool }
    if let string = raw as? String {
        switch string.lowercased() {
        case "true": return true
        case "false": return false
        default: return nil
        }
    }
    return nil
}

package func imagePath(_ value: String) -> Bool {
    let lower = value.lowercased()
    return [".png", ".jpg", ".jpeg", ".gif", ".webp", ".heic", ".heif", ".tiff", ".bmp"].contains {
        lower.hasSuffix($0) || lower.contains("\($0)?")
    }
}
