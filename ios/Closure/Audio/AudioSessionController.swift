import AVFoundation

/// Owns AVAudioSession: category, sample rate, interruptions and route changes.
/// Callbacks run on the main actor.
@MainActor
final class AudioSessionController {
    var onInterruptionBegan: () -> Void = {}
    var onInterruptionEnded: (_ shouldResume: Bool) -> Void = { _ in }
    /// Headphones unplugged or a Bluetooth device disconnected.
    var onOutputLost: () -> Void = {}
    /// Any route change. The hardware sample rate may have changed with it.
    var onRouteChanged: () -> Void = {}
    var onMediaServicesReset: () -> Void = {}

    private let session = AVAudioSession.sharedInstance()
    private var observers: [NSObjectProtocol] = []

    init() {
        // Long-form audio lets the system route playback the way music apps expect.
        try? session.setCategory(.playback, mode: .default, policy: .longFormAudio)

        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: AVAudioSession.interruptionNotification,
                                            object: session, queue: .main) { [weak self] note in
            let info = note.userInfo ?? [:]
            let typeValue = info[AVAudioSessionInterruptionTypeKey] as? UInt
            let optionsValue = info[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
            MainActor.assumeIsolated {
                guard let self, let typeValue,
                      let type = AVAudioSession.InterruptionType(rawValue: typeValue) else { return }
                switch type {
                case .began:
                    self.onInterruptionBegan()
                case .ended:
                    let options = AVAudioSession.InterruptionOptions(rawValue: optionsValue)
                    self.onInterruptionEnded(options.contains(.shouldResume))
                @unknown default:
                    break
                }
            }
        })

        observers.append(center.addObserver(forName: AVAudioSession.routeChangeNotification,
                                            object: session, queue: .main) { [weak self] note in
            let reasonValue = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt
            MainActor.assumeIsolated {
                guard let self else { return }
                if let reasonValue,
                   AVAudioSession.RouteChangeReason(rawValue: reasonValue) == .oldDeviceUnavailable {
                    self.onOutputLost()
                }
                self.onRouteChanged()
            }
        })

        observers.append(center.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification,
                                            object: session, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                try? self.session.setCategory(.playback, mode: .default, policy: .longFormAudio)
                self.onMediaServicesReset()
            }
        })
    }

    /// Asks the hardware to run at the source rate, so neither this app nor the
    /// system has to convert it. Returns the rate the hardware actually uses.
    func activate(preferredSampleRate: Double) throws -> Double {
        if preferredSampleRate > 0 {
            try? session.setPreferredSampleRate(preferredSampleRate)
        }
        try session.setActive(true)
        return session.sampleRate
    }

    func activate() throws {
        try session.setActive(true)
    }

    var sampleRate: Double { session.sampleRate }

    var routeDescription: String {
        let outputs = session.currentRoute.outputs
        guard !outputs.isEmpty else { return "None" }
        return outputs.map { output in
            let kind = output.portType.displayName
            return output.portName == kind ? kind : "\(output.portName) (\(kind))"
        }.joined(separator: ", ")
    }
}

private extension AVAudioSession.Port {
    var displayName: String {
        switch self {
        case .builtInSpeaker: return "Speaker"
        case .builtInReceiver: return "Receiver"
        case .headphones: return "Wired"
        case .usbAudio: return "USB"
        case .bluetoothA2DP: return "Bluetooth A2DP"
        case .bluetoothLE: return "Bluetooth LE"
        case .bluetoothHFP: return "Bluetooth HFP"
        case .airPlay: return "AirPlay"
        case .HDMI: return "HDMI"
        case .carAudio: return "CarPlay"
        default: return rawValue
        }
    }
}
