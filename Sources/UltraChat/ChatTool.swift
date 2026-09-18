import Foundation

/// Something a model may call in the middle of an answer: a name, what it is for, and the
/// arguments it takes.
///
/// The arguments are flat — strings and integers — because that is all the project's tools
/// need, and a flat list turns into every service's schema dialect without a JSON Schema
/// type of our own.
public struct ChatTool: Sendable, Equatable {
    public struct Parameter: Sendable, Equatable {
        public enum Kind: String, Sendable { case string, integer }

        public var name: String
        public var kind: Kind
        public var description: String
        public var isRequired: Bool

        public init(_ name: String, _ kind: Kind = .string, _ description: String,
                    isRequired: Bool = false) {
            self.name = name
            self.kind = kind
            self.description = description
            self.isRequired = isRequired
        }
    }

    public var name: String
    public var description: String
    public var parameters: [Parameter]

    public init(name: String, description: String, parameters: [Parameter]) {
        self.name = name
        self.description = description
        self.parameters = parameters
    }

    /// The arguments as JSON Schema, which Anthropic and OpenAI take as it is. Gemini's
    /// dialect names its types in capitals; `uppercaseTypes` is that.
    func schema(uppercaseTypes: Bool = false) -> [String: Any] {
        let spell: (String) -> String = { uppercaseTypes ? $0.uppercased() : $0 }
        var properties: [String: Any] = [:]
        for parameter in parameters {
            properties[parameter.name] = ["type": spell(parameter.kind.rawValue),
                                          "description": parameter.description]
        }
        return ["type": spell("object"),
                "properties": properties,
                "required": parameters.filter(\.isRequired).map(\.name)]
    }
}

/// One call a model made, and what came back. Stored on the assistant's message, so the
/// pane can show what was looked at and the next request can replay it.
public struct ChatToolCall: Identifiable, Codable, Equatable, Sendable {
    /// The service's id for the call; its result is matched to it by this.
    public var id: String
    public var name: String
    /// The arguments as the model wrote them: the text of a JSON object.
    public var arguments: String
    /// Nil until the tool has answered — or for good, if the answer was stopped first.
    public var result: String?

    public init(id: String, name: String, arguments: String, result: String? = nil) {
        self.id = id
        self.name = name
        self.arguments = arguments
        self.result = result
    }

    /// The arguments, parsed. Empty for text that is not a JSON object, which a tool then
    /// reports as a missing argument rather than a crash.
    public var argumentValues: [String: Any] {
        guard let data = arguments.data(using: .utf8) else { return [:] }
        return HTTPProviderSupport.object(data) ?? [:]
    }

    public func string(_ name: String) -> String? {
        (argumentValues[name] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Models write integers as numbers, as doubles and as strings; all three are taken.
    public func integer(_ name: String) -> Int? {
        switch argumentValues[name] {
        case let value as Int: value
        case let value as Double: Int(value)
        case let value as String: Int(value)
        default: nil
        }
    }

    /// What a request says came back when nothing did: the answer was stopped mid-call,
    /// and every service insists that a call in the history has a result.
    static let missingResult = "The call was cancelled before it returned."
}

/// The tools a request offers, and the thing that runs them.
///
/// A provider runs the loop — ask, run what was called, ask again — because only it knows
/// its service's shape for a call and a result. What the tools DO lives behind this.
public protocol ChatToolbox: Sendable {
    var tools: [ChatTool] { get }

    /// Run one call. Never throws: a failure is text the model reads and works around.
    func run(_ call: ChatToolCall) async -> String
}

/// How many times a provider will go back to the model with tool results before it gives
/// up. A question about a codebase takes a handful of reads; a model that is still reading
/// after this many is lost, and the user is paying for every round.
let maxToolRounds = 24
