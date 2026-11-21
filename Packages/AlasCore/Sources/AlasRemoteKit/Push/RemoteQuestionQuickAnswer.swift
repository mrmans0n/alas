import Foundation

/// Which questions a notification can answer with one button per option.
public enum RemoteQuestionQuickAnswer {
    /// iOS shows at most four actions on an expanded notification.
    public static let maxOptions = 4
    public static let actionPrefix = "option:"

    /// The options to offer, or nil when the request needs the full card: more than one
    /// question, a multiple choice, or more options than fit.
    public static func options(in payload: RemoteQuestionPayload) -> [RemoteQuestionOption]? {
        guard payload.questions.count == 1, let question = payload.questions.first, !question.allowMultiple,
              (1 ... maxOptions).contains(question.options.count) else { return nil }
        return question.options
    }
}
