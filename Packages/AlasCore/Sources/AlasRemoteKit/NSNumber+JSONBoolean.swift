import Foundation

extension NSNumber {
    /// Whether `JSONSerialization` decoded this from `true`/`false` rather
    /// than a number. Bridging to `Bool` can't tell: `1` bridges too.
    public var isJSONBoolean: Bool {
        #if canImport(Darwin)
        CFGetTypeID(self) == CFBooleanGetTypeID()
        #else
        // No CFBoolean here; Foundation's booleans report type "c" or "B".
        ["c", "B"].contains(String(cString: objCType))
        #endif
    }
}
