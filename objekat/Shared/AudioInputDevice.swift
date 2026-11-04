import Foundation

// MARK: - The input card chosen by the user (when it is not the output card)
//
// The WISH, like `AudioOutputDevice` for the output: the CoreAudio UID of the card the inputs are taken
// from, persisted in the preferences (`pref.inputDevice`) and handed to the engine at launch. nil = the
// output card's own inputs, which is the default and what every project did before. A UID, never a
// name: two identical interfaces, or the two halves of a pair of AirPods, share one.
//
// What is REALLY in use is the engine's (`AudioDeviceStatus.snapshot.inputDeviceUID`): the choice below
// is reset when the card is gone (@see EditViewModel+AudioInput), so the two meet again.

@MainActor
@Observable
final class AudioInputDevice {
    static let shared = AudioInputDevice()

    static let defaultsKey = "pref.inputDevice"

    /// nil = the same card as the output.
    var uid: String? {
        didSet {
            if let uid, !uid.isEmpty { UserDefaults.standard.set(uid, forKey: Self.defaultsKey) }
            else { UserDefaults.standard.removeObject(forKey: Self.defaultsKey) }
        }
    }

    private init() {
        let saved = UserDefaults.standard.string(forKey: Self.defaultsKey)
        uid = (saved?.isEmpty == false) ? saved : nil
    }
}
