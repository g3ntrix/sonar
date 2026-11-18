import SwiftUI

/// Sonar-specific branding and copy. Everything else lives in Shared/.
enum Brand {
    static let name = "Sonar"
    static let tagline = "A fast, private connection to your own server, for networks where other tools fail."
    static let bundleID = "com.g3ntrix.sonar"
    static let releasesRepo = "g3ntrix/sonar-releases"
    static var releasesURL: URL { URL(string: "https://github.com/\(releasesRepo)/releases")! }
    /// Veil (the faster sibling app for networks where UDP works). nil until its public releases page is known.
    static let veilReleasesURL: URL? = nil

    static let accent = Color(red: 0.10, green: 0.76, blue: 0.69)
    static let accentDeep = Color(red: 0.04, green: 0.36, blue: 0.42)
}
