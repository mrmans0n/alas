import Foundation
import Testing
@testable import AlasCore
import AlasPlatform

struct RemoteCheckoutSetupTests {
    @Test(arguments: [
        ("other\tgit@github.com:me/other.git\nnotes\t\n", nil),
        ("alas-old\tgit@github.com:me/alas.git\n", "alas-old"),
        ("b\thttps://github.com/me/alas\na\tssh://git@github.com/me/alas.git\n", "a"),
        ("x\tgit@github.com:me/alas.git\nalas\thttps://github.com/me/alas.git\n", "alas"),
        ("alas\tgit@gitlab.com:me/alas.git\n", nil),
    ] as [(String, String?)])
    func aCloneMatchesByOriginPreferringTheRepositorysName(listing: String, expected: String?) {
        #expect(RemoteCheckoutSetup.matchingClone(listing: listing, identity: "github.com/me/alas", repoName: "alas") == expected)
    }

    @Test(arguments: [
        ([], "alas"),
        (["alas"], "alas-2"),
        (["alas", "alas-2", "alas-4"], "alas-3"),
    ] as [([String], String)])
    func aCloneTakesTheFirstFreeName(taken: [String], expected: String) {
        #expect(RemoteCheckoutSetup.freeCloneName(repoName: "alas", taken: Set(taken)) == expected)
    }

    @Test func aMachineWithoutAMatchingCloneClonesIntoAFreeName() async throws {
        let commands = CommandLog()
        let checkout = try await RemoteCheckoutSetup.ensure(
            host: "mini", projectsFolder: "~/code", originURL: "git@github.com:me/alas.git"
        ) { _, args, _ in
            await commands.append(args.joined(separator: " "))
            return await commands.count == 1
                ? ProcessResult(exitCode: 0, stdout: "/home/me/code\nalas\thttps://github.com/you/alas\n", stderr: "")
                : ProcessResult(exitCode: 0, stdout: "", stderr: "Cloning into 'alas-2'...")
        }
        #expect(checkout == .init(path: "/home/me/code/alas-2", cloned: true))
        let clone = try #require(await commands.last)
        #expect(clone.contains("git clone --progress") && clone.contains("alas-2"))
    }

    @Test(arguments: [
        ("Cloning into 'alas'...\ngit@github.com: Permission denied (publickey).\nfatal: Could not read from remote repository.\n",
         "fatal: Could not read from remote repository.\nThe machine needs access to github.com."),
        ("Receiving objects:  40%\rfatal: early EOF\n", "fatal: early EOF"),
    ])
    func aFailedCloneShowsGitsErrorAndWhatTheMachineLacks(stderr: String, expected: String) {
        #expect(RemoteCheckoutSetup.cloneFailureMessage(stderr: stderr, originHost: "github.com") == expected)
    }

    @Test func aChosenFolderMustBeACloneOfTheSameRepository() async {
        await #expect(throws: RemoteCheckoutSetup.Failure.failed("This clone's origin is github.com/you/alas, not github.com/me/alas.")) {
            try await RemoteCheckoutSetup.adopt(host: "mini", path: "~/src/alas", originURL: "git@github.com:me/alas.git") { _, _, _ in
                ProcessResult(exitCode: 0, stdout: "/home/me/src/alas\nhttps://github.com/you/alas.git\n", stderr: "")
            }
        }
    }
}

private actor CommandLog {
    private(set) var commands: [String] = []
    var count: Int { commands.count }
    var last: String? { commands.last }
    func append(_ command: String) { commands.append(command) }
}
