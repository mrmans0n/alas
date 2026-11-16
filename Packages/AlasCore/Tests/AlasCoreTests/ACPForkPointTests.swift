import Testing
import AlasCore

struct ACPForkPointTests {
    @Test(arguments: [
        ("café", "sha256:850f7dc43910ff890f8879c0ed26fe697c93a067ad93a7d50f466a7028a9bf4e"),
        ("cafe\u{301}", "sha256:81ef060bcd98adc7824eb5c1ada83c32491b16018e11e79f00ab9d09e04b015a"),
    ])
    func fingerprintsExactUTF8Bytes(text: String, fingerprint: String) {
        #expect(ACPForkPointTarget.fingerprint(text) == fingerprint)
    }
}
