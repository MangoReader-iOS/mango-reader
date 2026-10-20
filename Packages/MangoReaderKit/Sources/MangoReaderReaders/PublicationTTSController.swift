import AVFoundation
import Foundation

public enum PublicationTTSState: String, Codable, CaseIterable, Sendable {
    case idle
    case speaking
    case paused
}

public struct PublicationTTSUtterance: Codable, Hashable, Sendable, Identifiable {
    public let id: UUID
    public let text: String
    public let languageCode: String?

    public init(id: UUID = UUID(), text: String, languageCode: String? = nil) {
        self.id = id
        self.text = text
        self.languageCode = languageCode
    }
}

@MainActor
public protocol PublicationTTSControlling: AnyObject {
    var state: PublicationTTSState { get }
    func speak(_ utterances: [PublicationTTSUtterance], preferences: PublicationTTSPreferences)
    func pause()
    func resume()
    func stop()
}

@MainActor
public final class AVSpeechPublicationTTSController: PublicationTTSControlling {
    private let synthesizer: AVSpeechSynthesizer

    public init() {
        synthesizer = AVSpeechSynthesizer()
    }

    public var state: PublicationTTSState {
        if synthesizer.isPaused {
            .paused
        } else if synthesizer.isSpeaking {
            .speaking
        } else {
            .idle
        }
    }

    public func speak(
        _ utterances: [PublicationTTSUtterance],
        preferences: PublicationTTSPreferences = PublicationTTSPreferences()
    ) {
        stop()
        for item in utterances where !item.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let utterance = AVSpeechUtterance(string: item.text)
            let languageCode = item.languageCode ?? preferences.languageCode
            if let voiceIdentifier = preferences.voiceIdentifier {
                utterance.voice = AVSpeechSynthesisVoice(identifier: voiceIdentifier)
            } else if let languageCode {
                utterance.voice = AVSpeechSynthesisVoice(language: languageCode)
            }
            utterance.rate = AVSpeechUtteranceMinimumSpeechRate
                + Float(preferences.rate) * (AVSpeechUtteranceMaximumSpeechRate - AVSpeechUtteranceMinimumSpeechRate)
            utterance.pitchMultiplier = Float(preferences.pitch)
            utterance.volume = Float(preferences.volume)
            synthesizer.speak(utterance)
        }
    }

    public func pause() {
        guard synthesizer.isSpeaking else {
            return
        }
        synthesizer.pauseSpeaking(at: .word)
    }

    public func resume() {
        guard synthesizer.isPaused else {
            return
        }
        synthesizer.continueSpeaking()
    }

    public func stop() {
        if synthesizer.isSpeaking || synthesizer.isPaused {
            synthesizer.stopSpeaking(at: .immediate)
        }
    }
}
