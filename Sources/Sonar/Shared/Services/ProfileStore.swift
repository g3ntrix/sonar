import Foundation

/// Profiles and app settings in ~/Library/Application Support/Sonar (no secrets; those live in SecretStore's secrets.json).
struct StoredState: Codable {
    var profiles: [ServerProfile] = []
    var selectedID: UUID?
    var tunnel = TunnelSettings.default
    var lanSharing = false
    var systemProxy = false
    var autoConnect = false
    var wizard = WizardProgress()
    var onboardingDone = false
}

/// Where the user is in the setup wizard, so quitting mid-way returns to the same step.
struct WizardProgress: Codable, Equatable {
    var step = 0
    var profileID: UUID?
    var draftAddress = ""
    var draftUser = "ubuntu"
    var draftName = ""
    var installConfirmed = false
}

enum ProfileStore {
    static var url: URL { Paths.appSupport.appendingPathComponent("state.json") }

    static func load() -> StoredState {
        guard let d = try? Data(contentsOf: url), let s = try? JSONDecoder().decode(StoredState.self, from: d) else {
            return StoredState()
        }
        return s
    }

    static func save(_ s: StoredState) {
        guard let d = try? JSONEncoder().encode(s) else { return }
        try? d.write(to: url, options: .atomic)
    }
}

/// Export and import of a profile. An exported file contains the secrets and is marked so.
enum ProfileTransfer {
    struct Envelope: Codable {
        var warning = "THIS FILE CONTAINS SECRETS (passwords and the private key of your Sonar server). Do not share it."
        var format = "sonar-profile-1"
        var profile: ServerProfile
        var secrets: ProfileSecrets
    }

    static let fileExtension = "sonarprofile"

    static func export(_ p: ServerProfile, _ s: ProfileSecrets) throws -> Data {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return try e.encode(Envelope(profile: p, secrets: s))
    }

    static func `import`(_ d: Data) throws -> (ServerProfile, ProfileSecrets) {
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        let e = try dec.decode(Envelope.self, from: d)
        guard e.format == "sonar-profile-1" else { throw CocoaError(.fileReadCorruptFile) }
        return (e.profile, e.secrets)
    }
}
