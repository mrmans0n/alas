import Foundation

/// H.264 byte streams as Android's encoder writes them: NAL units after
/// 3- or 4-byte start codes.
public enum H264AnnexB {
    public static func nalUnits(_ data: Data) -> [Data] {
        let bytes = [UInt8](data)
        var units: [Data] = []
        var start: Int?
        var index = 0
        while index + 3 <= bytes.count {
            let three = bytes[index] == 0 && bytes[index + 1] == 0 && bytes[index + 2] == 1
            let four = index + 4 <= bytes.count && bytes[index] == 0 && bytes[index + 1] == 0
                && bytes[index + 2] == 0 && bytes[index + 3] == 1
            if three || four {
                if let start { units.append(Data(bytes[start..<index])) }
                index += four ? 4 : 3
                start = index
            } else {
                index += 1
            }
        }
        if let start, start < bytes.count { units.append(Data(bytes[start...])) }
        return units
    }

    /// The first SPS (type 7) and PPS (type 8) in a config packet.
    public static func parameterSets(_ config: Data) -> (sps: Data, pps: Data)? {
        let units = nalUnits(config)
        guard let sps = units.first(where: { $0.first.map { $0 & 0x1F == 7 } ?? false }),
              let pps = units.first(where: { $0.first.map { $0 & 0x1F == 8 } ?? false }) else { return nil }
        return (sps, pps)
    }

    /// The same NAL units, each after its 4-byte big-endian length, as VideoToolbox takes them.
    public static func avcc(_ data: Data) -> Data {
        var out = Data()
        for unit in nalUnits(data) {
            out.append(be: UInt32(unit.count))
            out += unit
        }
        return out
    }
}
