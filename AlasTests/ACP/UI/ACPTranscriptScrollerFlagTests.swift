import Testing
import Foundation
@testable import Alas

@Suite("ACPTranscriptScrollerFlag")
struct ACPTranscriptScrollerFlagTests {
    @Test("explicit override wins in both build types")
    func overrideWins() {
        #expect(ACPTranscriptScrollerFlag.resolve(override: true, isDebugBuild: false) == true)
        #expect(ACPTranscriptScrollerFlag.resolve(override: false, isDebugBuild: true) == false)
    }

    @Test("no override: on for debug builds, off for release")
    func defaults() {
        #expect(ACPTranscriptScrollerFlag.resolve(override: nil, isDebugBuild: true) == true)
        #expect(ACPTranscriptScrollerFlag.resolve(override: nil, isDebugBuild: false) == false)
    }
}

@Suite("ACPTranscriptScrollerFlag UserDefaults Integration")
struct ACPTranscriptScrollerFlagUserDefaultsTests {
    @Test("UserDefaults round-trip: boolean written as true is read back as true")
    func userDefaultsRoundTripTrue() throws {
        let suiteName = "ACPTranscriptScrollerFlagTest-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }

        defaults.set(true, forKey: ACPTranscriptScrollerFlag.defaultsKey)
        let override = ACPTranscriptScrollerFlag.readOverride(from: defaults)
        #expect(override == true)
    }

    @Test("UserDefaults round-trip: boolean written as false is read back as false")
    func userDefaultsRoundTripFalse() throws {
        let suiteName = "ACPTranscriptScrollerFlagTest-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }

        defaults.set(false, forKey: ACPTranscriptScrollerFlag.defaultsKey)
        let override = ACPTranscriptScrollerFlag.readOverride(from: defaults)
        #expect(override == false)
    }

    @Test("UserDefaults round-trip: absent key returns nil")
    func userDefaultsRoundTripNil() throws {
        let suiteName = "ACPTranscriptScrollerFlagTest-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }

        let override = ACPTranscriptScrollerFlag.readOverride(from: defaults)
        #expect(override == nil)
    }

    @Test("isEnabled delegates to resolve with readOverride result and debug build flag")
    func isEnabledDelegatesCorrectly() throws {
        let suiteName = "ACPTranscriptScrollerFlagTest-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }

        // Test with override = true (should win regardless of build type)
        defaults.set(true, forKey: ACPTranscriptScrollerFlag.defaultsKey)
        let result1 = ACPTranscriptScrollerFlag.isEnabledWithDefaults(defaults)
        #expect(result1 == true)

        // Test with override = false (should win regardless of build type)
        defaults.set(false, forKey: ACPTranscriptScrollerFlag.defaultsKey)
        let result2 = ACPTranscriptScrollerFlag.isEnabledWithDefaults(defaults)
        #expect(result2 == false)

        // Test with no override (should default to debug mode, which is true in tests)
        defaults.removeObject(forKey: ACPTranscriptScrollerFlag.defaultsKey)
        let result3 = ACPTranscriptScrollerFlag.isEnabledWithDefaults(defaults)
        // In test environment (DEBUG mode), should be true
        #expect(result3 == true)
    }
}
