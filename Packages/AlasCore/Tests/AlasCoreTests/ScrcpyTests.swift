import Foundation
import Testing
import AlasCore

struct ScrcpyTests {
    private static func bytes(_ values: [UInt8]) -> Data { Data(values) }

    /// A codec id, a session, a config packet, a key frame and a P frame, as the server sends them.
    private static let stream: Data = {
        var data = Data("h264".utf8)
        data += bytes([0x80, 0, 0, 0, 0, 0, 0x02, 0xD0, 0, 0, 0x06, 0x40]) // session 720×1600
        data += bytes([0x40, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 3]) + bytes([1, 2, 3]) // config
        data += bytes([0x20, 0, 0, 0, 0, 0, 0, 1, 0, 0, 0, 2]) + bytes([4, 5]) // key frame
        data += bytes([0x00, 0, 0, 0, 0, 0, 0, 2, 0, 0, 0, 1]) + bytes([6]) // P frame
        return data
    }()

    private static let events: [ScrcpyVideoEvent] = [
        .session(width: 720, height: 1600), .config(bytes([1, 2, 3])),
        .frame(bytes([4, 5]), keyFrame: true), .frame(bytes([6]), keyFrame: false),
    ]

    @Test(arguments: [1, 5, 1000])
    func theVideoStreamParsesWhateverTheReadSizes(chunk: Int) throws {
        var parser = ScrcpyVideoParser()
        var events: [ScrcpyVideoEvent] = []
        var offset = 0
        while offset < Self.stream.count {
            let end = min(offset + chunk, Self.stream.count)
            events += try parser.feed(Self.stream.subdata(in: offset..<end))
            offset = end
        }
        #expect(events == Self.events)
    }

    @Test func anotherCodecIsRefused() {
        var parser = ScrcpyVideoParser()
        #expect(throws: ScrcpyError.unsupportedCodec(0x6832_3635)) { try parser.feed(Data("h265".utf8)) }
    }

    // The expected bytes are scrcpy v5.0.1's app/tests/test_control_msg_serialize.c.
    @Test func controlMessagesMatchScrcpysOwnEncoding() {
        #expect(ScrcpyControl.keycode(.up, keycode: 66, repeat: 5, metastate: 0x41) == Self.bytes([
            0x00, 0x01, 0x00, 0x00, 0x00, 0x42, 0x00, 0x00, 0x00, 0x05, 0x00, 0x00, 0x00, 0x41,
        ]))
        #expect(ScrcpyControl.touch(
            .down, x: 100, y: 200, width: 1080, height: 1920, pointerID: 0x1234_5678_8765_4321,
            pressure: 1, actionButton: 1, buttons: 1
        ) == Self.bytes([
            0x02, 0x00, 0x12, 0x34, 0x56, 0x78, 0x87, 0x65, 0x43, 0x21,
            0x00, 0x00, 0x00, 0x64, 0x00, 0x00, 0x00, 0xC8, 0x04, 0x38, 0x07, 0x80,
            0xFF, 0xFF, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
        ]))
        #expect(ScrcpyControl.scroll(x: 260, y: 1026, width: 1080, height: 1920, horizontal: 16, vertical: -16, buttons: 1)
            == Self.bytes([
                0x03, 0x00, 0x00, 0x01, 0x04, 0x00, 0x00, 0x04, 0x02, 0x04, 0x38, 0x07, 0x80,
                0x7F, 0xFF, 0x80, 0x00, 0x00, 0x00, 0x00, 0x01,
            ]))
        #expect(ScrcpyControl.backOrScreenOn(.up) == Self.bytes([0x04, 0x01]))
        #expect(ScrcpyControl.getClipboard(copy: true) == Self.bytes([0x08, 0x01]))
        #expect(ScrcpyControl.setClipboard(sequence: 0x0102_0304_0506_0708, text: "hello, world!", paste: true)
            == Self.bytes([0x09, 1, 2, 3, 4, 5, 6, 7, 8, 1, 0, 0, 0, 0x0D]) + Data("hello, world!".utf8))
    }

    /// scrcpy refuses clipboard text over 262,130 UTF-8 bytes; longer text is
    /// cut at a character boundary.
    @Test func clipboardTextIsCutToWhatScrcpyAccepts() throws {
        let text = String(repeating: "a", count: 262_129) + "é" + "tail"
        let message = ScrcpyControl.setClipboard(sequence: 1, text: text, paste: true)
        let length = Int(message[10]) << 24 | Int(message[11]) << 16 | Int(message[12]) << 8 | Int(message[13])
        #expect(length == 262_129)
        #expect(message.count == 14 + length)
    }

    // scrcpy v5.0.1's app/tests/test_device_msg_deserialize.c, fed in two pieces.
    @Test func deviceMessagesParseAcrossReads() throws {
        var parser = ScrcpyDeviceMessageParser()
        let data = Self.bytes([0x00, 0, 0, 0, 3, 0x41, 0x42, 0x43, 0x01, 1, 2, 3, 4, 5, 6, 7, 8])
        var messages = try parser.feed(data.prefix(6))
        messages += try parser.feed(data.dropFirst(6))
        #expect(messages == [.clipboard("ABC"), .ackClipboard(0x0102_0304_0506_0708)])
    }

    @Test func annexBSplitsOnThreeAndFourByteStartCodes() {
        let data = Self.bytes([0, 0, 0, 1, 0x67, 0xAA, 0, 0, 1, 0x68, 0xBB, 0, 0, 0, 1, 0x65, 0xCC, 0xDD])
        #expect(H264AnnexB.nalUnits(data) == [Self.bytes([0x67, 0xAA]), Self.bytes([0x68, 0xBB]), Self.bytes([0x65, 0xCC, 0xDD])])
        #expect(H264AnnexB.parameterSets(data)?.sps == Self.bytes([0x67, 0xAA]))
        #expect(H264AnnexB.parameterSets(data)?.pps == Self.bytes([0x68, 0xBB]))
        #expect(H264AnnexB.avcc(Self.bytes([0, 0, 0, 1, 0x65, 0xCC, 0xDD])) == Self.bytes([0, 0, 0, 3, 0x65, 0xCC, 0xDD]))
    }

    @Test(arguments: [
        (UInt32(0x04), Int32(29)), (0x1D, 54), (0x1E, 8), (0x27, 7), (0x28, 66), (0x2A, 67), (0x2C, 62),
        (0x4F, 22), (0x52, 19), (0xE1, 59), (0x3A, 131), (0x58, 160),
    ] as [(UInt32, Int32)])
    func hidUsagesMapToAndroidKeycodes(usage: UInt32, keycode: Int32) {
        #expect(AndroidKeys.keycode(forHIDUsage: usage) == keycode)
    }

    @Test func heldModifiersSetTheMetaState() {
        var meta = AndroidMetaState()
        meta.update(hidUsage: 0xE1, down: true) // left shift
        #expect(meta.value == 0x41)
        meta.update(hidUsage: 0xE0, down: true) // left control
        #expect(meta.value == 0x3041)
        meta.update(hidUsage: 0xE1, down: false)
        #expect(meta.value == 0x3000)
    }
}
