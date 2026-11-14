import Foundation
import FoundationModels

/// Name suggestions from Apple's on-device model, given a PlaceContext and
/// whatever else the caller knows. They go alongside PlaceSuggestions'
/// list, never instead of it: the model is missing on older devices and
/// when Apple Intelligence is off.
enum PlaceNameModel {
    static var isAvailable: Bool {
        SystemLanguageModel.default.availability == .available
    }

    @Generable
    struct Suggestions {
        @Guide(description: "Short names for a saved map view, best first. Each 2 to 6 words, American English, title case. Only use place names that appear in the facts.", .maximumCount(5))
        var names: [String]
    }

    /// Suggestions for a place with `context`. `existingNames` are the
    /// user's other places, to match their style and avoid repeats; `notes`
    /// is any other context, such as the time of day.
    ///
    /// Suggestions naming a place that isn't in the context are dropped
    /// (`PlaceSuggestions.usesOnlyKnownNames`), since the model can invent
    /// places.
    ///
    /// This is the only file that imports FoundationModels, and the Core
    /// Tests target leaves it out; see project.yml.
    static func suggestions(for context: PlaceContext, existingNames: [String] = [], notes: String? = nil) async throws -> [String] {
        let session = LanguageModelSession(instructions: """
            You suggest names for places a user saves in a 3D map app. A saved place is a view: \
            where the camera is, how high, and what it looks at. Use only the facts given. \
            Prefer short, natural names a person would write, like "Boston from the harbor" or \
            "Over Worcester". Don't repeat the user's existing names.
            """)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let facts = String(decoding: try encoder.encode(context), as: UTF8.self)
        var prompt = "Facts about the view, as JSON (heights in meters, distances in meters, bearings in degrees from north):\n\(facts)"
        prompt += "\nA plain description: \(PlaceSuggestions.description(of: context))."
        if !existingNames.isEmpty {
            prompt += "\nThe user's existing place names: \(existingNames.joined(separator: "; "))."
        }
        if let notes { prompt += "\nOther context: \(notes)" }

        let response = try await session.respond(to: prompt, generating: Suggestions.self)
        let known = context.allNames
        let existing = Set(existingNames.map { $0.lowercased() })
        return response.content.names
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter {
                !$0.isEmpty && !existing.contains($0.lowercased())
                    && PlaceSuggestions.usesOnlyKnownNames($0, known: known)
            }
    }
}
