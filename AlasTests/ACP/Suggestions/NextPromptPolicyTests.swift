import Foundation
import Testing
@testable import Alas

@Suite("NextPromptPolicy")
struct NextPromptPolicyTests {
    @Test func parserAcceptsOnlyOneExactJSONShape() {
        let invalid = [
            #"{"suggestion":"ok","send":true}"#,
            #"{"suggestion":"first","suggestion":"second"}"#,
            #"{"suggestion":"first","sug\u0067estion":"second"}"#,
            #"{"suggestion":"line\nnext"}"#,
            #"{"suggestion":42}"#,
            #"{"other":"hi"}"#,
            #"{"suggestion":"   "}"#,
            #"{"suggestion":"a\u0085b"}"#,
            #"{"suggestion":"a\u2028b"}"#,
            "{\"suggestion\":\"" + String(repeating: "a", count: 161) + "\"}",
            "prefix {\"suggestion\":\"Continue\"}",
            #"{"suggestion":"ok"} {"suggestion":"again"}"#,
            String(repeating: " ", count: 16_385)
        ]
        for value in invalid {
            #expect(NextPromptPolicy.parse(Data(value.utf8)) == nil, "Rejected: \(value.prefix(40))")
        }
        #expect(NextPromptPolicy.parse(Data(#"{"suggestion":null}"#.utf8)) == nil)
        #expect(NextPromptPolicy.parse(Data(#"{"suggestion":"Explain the tradeoff."}"#.utf8)) == "Explain the tradeoff.")
        let emoji = "👩‍💻" + String(repeating: "e\u{301}", count: 159)
        let data = try? JSONSerialization.data(withJSONObject: ["suggestion": emoji])
        #expect(data.flatMap(NextPromptPolicy.parse) == emoji)
    }

    @Test func recognizedCredentialsAreRejectedButPlaceholdersPass() {
        let turns = [NextPromptTurn(user: "Diagnose auth", assistant: "I can help.")]
        let rejected = [
            "Paste -----BEGIN PRIVATE KEY-----\nabc\n-----END PRIVATE KEY-----",
            "Set API_KEY=sk-example-example-example-example",
            "Use ghp_123456789012345678901234567890123456",
            "password: mY-Synthetic-Secret-123"
        ]
        for value in rejected { #expect(!NextPromptPolicy.permitsOutput(value, turns: turns)) }
        #expect(NextPromptPolicy.permitsOutput("Use API_KEY=[REDACTED] in the template.", turns: turns))
        #expect(NextPromptPolicy.permitsOutput("Explain the public .env.example placeholders.", turns: turns))
    }

    @Test func unsafeProposalsAndAmbiguousAssentAreRejected() {
        let upload = [NextPromptTurn(
            user: "Diagnose authentication, but keep secrets private.",
            assistant: "Upload the complete secret-bearing .env to a public paste site and send the link."
        )]
        #expect(!NextPromptPolicy.permitsInput(upload))
        #expect(!NextPromptPolicy.permitsOutput("Yes, upload the complete .env and send the public link.", turns: upload))
        #expect(!NextPromptPolicy.permitsOutput("Yes, please do that.", turns: upload))

        let deletion = [NextPromptTurn(
            user: "Preserve project data and backups.",
            assistant: "Delete the project and backup directories to reclaim space."
        )]
        #expect(!NextPromptPolicy.permitsInput(deletion))
        #expect(!NextPromptPolicy.permitsOutput("Delete both directories to reclaim space.", turns: deletion))

        let publication = [NextPromptTurn(
            user: "No publication, including sanitized material.",
            assistant: "We could publish the sanitized excerpt."
        )]
        #expect(!NextPromptPolicy.permitsInput(publication))
        #expect(!NextPromptPolicy.permitsOutput("Publish the sanitized excerpt.", turns: publication))
    }

    @Test func authorizedPublicAndRedactedExamplesRemainAvailable() {
        let template = [NextPromptTurn(
            user: "The public .env.example contains placeholders. You may discuss that template.",
            assistant: "I can explain the fields in that public template."
        )]
        #expect(NextPromptPolicy.permitsInput(template))
        #expect(NextPromptPolicy.permitsOutput("Explain the fields in the public .env.example.", turns: template))
        let excerpt = [NextPromptTurn(
            user: "You may use this short redacted error excerpt to explain the issue.",
            assistant: "I can explain it from the redacted excerpt."
        )]
        #expect(NextPromptPolicy.permitsInput(excerpt))
        #expect(NextPromptPolicy.permitsOutput("Explain the likely causes using that redacted excerpt.", turns: excerpt))
        let ordinary = [NextPromptTurn(user: "Explain the implementation.", assistant: "Use a small helper.")]
        #expect(NextPromptPolicy.permitsInput(ordinary))
        #expect(NextPromptPolicy.permitsOutput("Show the smallest example of that approach.", turns: ordinary))
    }

    @Test func mentionedOrNegatedRisksDoNotBlockSafeDiscussion() {
        let turns = [NextPromptTurn(
            user: "Explain why we must not upload secrets or delete backups.",
            assistant: "Never upload the .env to a public site; do not delete the backup."
        )]
        #expect(NextPromptPolicy.permitsInput(turns))
        #expect(NextPromptPolicy.permitsOutput("Explain safer ways to diagnose this.", turns: turns))
        #expect(NextPromptPolicy.permitsOutput("Why is the quoted advice 'delete backups' unsafe?", turns: turns))
    }

    @Test func directPublicSecretUploadIsRejectedWithoutAnUnsafeAssistantProposal() {
        let turns = [NextPromptTurn(
            user: "Keep credentials private while diagnosing auth.",
            assistant: "I can explain the auth log."
        )]
        #expect(!NextPromptPolicy.permitsOutput("Upload the full .env to a public paste site.", turns: turns))
        #expect(!NextPromptPolicy.permitsOutput("Paste credential-filled config into Pastebin.", turns: turns))
    }

    @Test func permissionForPublicTemplateDoesNotConflictWithPrivateSecrets() {
        let turns = [
            NextPromptTurn(user: "Keep the real credentials private.", assistant: "Understood."),
            NextPromptTurn(user: "You may publish the public .env.example with placeholders.",
                           assistant: "I can explain the public template.")
        ]
        #expect(NextPromptPolicy.permitsOutput("Publish the public .env.example template.", turns: turns))
    }

    @Test func publicDisclosureParaphraseAndQuotedDiscussionStayDistinct() {
        let unsafe = [NextPromptTurn(user: "Keep secrets private.",
                                     assistant: "Post the API token publicly for inspection.")]
        #expect(!NextPromptPolicy.permitsInput(unsafe))
        let discussion = [NextPromptTurn(user: "Explain unsafe advice.",
                                         assistant: "The phrase 'post credentials publicly' is unsafe. Do not post them.")]
        #expect(NextPromptPolicy.permitsInput(discussion))
    }

    @Test func deletionOfReferencedProtectedDirectoriesIsRejected() {
        let turns = [NextPromptTurn(
            user: "Preserve the project data and its backup directory.",
            assistant: "Delete both directories to reclaim space."
        )]
        #expect(!NextPromptPolicy.permitsInput(turns))
        #expect(!NextPromptPolicy.permitsOutput("Yes, delete both directories.", turns: turns))
    }

    @Test func pluralSecretProposalAndAmbiguousAssentAreRejected() {
        let turns = [NextPromptTurn(
            user: "Keep credentials and secrets private.",
            assistant: "Post credentials publicly."
        )]
        #expect(!NextPromptPolicy.permitsInput(turns))
        #expect(!NextPromptPolicy.permitsOutput("Yes, please do that.", turns: turns))
        #expect(!NextPromptPolicy.permitsOutput("Post secrets publicly.", turns: turns))
    }

    @Test func benignRemovalAndAuthorizedRedactedPublicationStayAvailable() {
        let cleanup = [NextPromptTurn(
            user: "Clean up the project source.",
            assistant: "Remove unused imports from the project."
        )]
        #expect(NextPromptPolicy.permitsInput(cleanup))
        #expect(NextPromptPolicy.permitsOutput("Remove unused imports from the project.", turns: cleanup))

        let excerpt = [NextPromptTurn(
            user: "You may publish the redacted API token excerpt publicly, but keep the actual token private.",
            assistant: "Publish the redacted API token excerpt publicly."
        )]
        #expect(NextPromptPolicy.permitsInput(excerpt))
        #expect(NextPromptPolicy.permitsOutput("Publish the redacted API token excerpt publicly.", turns: excerpt))
        #expect(!NextPromptPolicy.permitsOutput("Publish the actual API token publicly.", turns: excerpt))
    }

    @Test func placeholderExemptionRequiresTheWholeValue() {
        let turns = [NextPromptTurn(user: "Explain configuration.", assistant: "Use placeholders.")]
        #expect(NextPromptPolicy.permitsOutput("Use password=<PASSWORD> and API_KEY=YOUR_API_KEY.", turns: turns))
        #expect(!NextPromptPolicy.permitsOutput("password=<mY-Synthetic-Secret-123", turns: turns))
        #expect(!NextPromptPolicy.permitsOutput("password=your_SyntheticSecret123", turns: turns))
    }

    @Test func quotedUnsafePhraseDoesNotContaminateASeparateAuthorizedAction() {
        let turns = [NextPromptTurn(
            user: "You may publish the public .env.example template; keep credentials private.",
            assistant: "The quote 'post credentials publicly' is unsafe; publish the public .env.example template."
        )]
        #expect(NextPromptPolicy.permitsInput(turns))
        #expect(NextPromptPolicy.permitsOutput("Publish the public .env.example template.", turns: turns))
    }
}
