// SPDX-FileCopyrightText: 2026 yukunlabs
// SPDX-License-Identifier: 0BSD
// Refs: US-07, AC-07.02, AC-07.04; US-08, AC-08.01, AC-08.03.
// Refs: US-09, AC-09.02; US-10, AC-10.04; US-07, AC-07.05.
import Foundation
import LunletCore

public struct CardAnswerField: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case text, singleChoice(Set<String>), multipleChoice(Set<String>)
    }
    public let name: String
    public let questionID: String
    public let kind: Kind

    public init(name: String, questionID: String, kind: Kind) {
        self.name = name
        self.questionID = questionID
        self.kind = kind
    }
}

public enum CardForm: Equatable, Sendable {
    case followup(field: String)
    case answers([CardAnswerField])

    func matches(_ phase: SessionPhase) -> Bool {
        switch (self, phase) {
        case (.followup(let name), .idle): return Self.validName(name)
        case (.answers(let fields), .question(_, _, _, let questions, .ordinary)):
            return !fields.isEmpty && fields.count <= 8 && Set(fields.map(\.name)).count == fields.count
                && Set(fields.map(\.questionID)).count == fields.count && Set(fields.map(\.questionID)) == Set(questions)
                && fields.allSatisfy { field in
                    guard Self.validName(field.name), Self.validText(field.questionID),
                          field.questionID.utf8.count <= 256 else { return false }
                    switch field.kind {
                    case .text: return true
                    case .singleChoice(let options), .multipleChoice(let options):
                        return !options.isEmpty && options.count <= 20 && options.allSatisfy(Self.validText)
                    }
                }
        default: return false
        }
    }

    func input(from values: [String: CardFormValue]) -> ContinuationInput? {
        switch self {
        case .followup(let field):
            // Checked before the control is consumed, so the owner can correct and resend.
            guard values.count == 1, case .text(let text) = values[field], Self.validText(text),
                  ContinuationText.isForwardable(text) else { return nil }
            return .followup(text)
        case .answers(let fields):
            guard Set(values.keys) == Set(fields.map(\.name)) else { return nil }
            var answers: [String: [String]] = [:]
            for field in fields {
                switch (field.kind, values[field.name]) {
                case (.text, .text(let text)) where Self.validText(text): answers[field.questionID] = [text]
                case (.singleChoice(let allowed), .text(let text)) where allowed.contains(text):
                    answers[field.questionID] = [text]
                case (.multipleChoice(let allowed), .selections(let selected))
                    where !selected.isEmpty && Set(selected).count == selected.count && Set(selected).isSubset(of: allowed):
                    answers[field.questionID] = selected
                default: return nil
                }
            }
            return .answer(answers)
        }
    }

    private static func validName(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 64 && value.utf8.allSatisfy {
            (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 95
        }
    }

    private static func validText(_ value: String) -> Bool {
        !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && value.utf8.count <= 8_192 && !value.contains("\0")
    }
}
