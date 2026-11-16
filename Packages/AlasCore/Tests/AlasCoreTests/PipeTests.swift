#if os(Linux)
import Foundation
import Testing
@testable import AlasFoundation

struct PipeTests {
    @Test func anInheritedPlaceholderCannotKeepTheTransportReaderAlive() throws {
        let placeholder = Pipe()
        // Force an unrelated child to inherit the descriptors before the
        // factory can mark them, as a concurrent Foundation spawn can do.
        try withChildHolding(placeholder.fileHandleForReading.fileDescriptor) {
            let pipe = Pipe.closingOnExec(replacing: placeholder)
            defer { try? pipe.fileHandleForWriting.close() }
            #expect(fcntl(pipe.fileHandleForReading.fileDescriptor, F_GETFD) == FD_CLOEXEC)
            #expect(fcntl(pipe.fileHandleForWriting.fileDescriptor, F_GETFD) == FD_CLOEXEC)
            NoSigPipe.pipe(pipe.fileHandleForWriting.fileDescriptor)
            try pipe.fileHandleForReading.close()
            #expect(throws: (any Error).self) {
                try pipe.fileHandleForWriting.write(contentsOf: Data("ordinary\n".utf8))
            }
        }
    }
}
#endif
