import Foundation

/// UserDefaults keys shared by the settings UI (@AppStorage) and the conversion engine.
enum Prefs {
    static let gestureEnabled = "gestureEnabled"
    static let outputLocation = "outputLocation"   // "beside" | "downloads" | "custom"
    static let customFolder = "customFolder"
    static let imageQuality = "imageQuality"
    static let compressQuality = "compressQuality"
    static let revealAfter = "revealAfter"
    static let playSound = "playSound"

    static func registerDefaults() {
        UserDefaults.standard.register(defaults: [
            gestureEnabled: true,
            outputLocation: "beside",
            customFolder: "",
            imageQuality: 0.9,
            compressQuality: 0.6,
            revealAfter: false,
            playSound: true,
        ])
    }

    static var defaults: UserDefaults { .standard }
}
