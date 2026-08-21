import Foundation

struct RuntimeMenuPresentation: Equatable {
    let statusIconName: String
    let healthTitle: String
    let healthDetail: String
    let canRetry: Bool

    static func make(from status: AudioRuntimeState.Status) -> Self {
        let statusIcon: String
        let detail: String
        switch status {
        case .processing:
            statusIcon = "waveform.circle.fill"
            detail = "Airwave is active."
        case .starting:
            statusIcon = "waveform.badge.plus"
            detail = "Airwave is getting ready."
        case .needsPermission:
            statusIcon = "exclamationmark.waveform"
            detail = "System Audio Capture permission is required."
        case .inactive:
            statusIcon = "waveform.circle"
            detail = "No HRIR preset selected; native audio remains unchanged."
        case .nativePassthrough:
            statusIcon = "exclamationmark.waveform"
            detail = "Airwave is waiting until it can resume processing."
        case .recovering:
            statusIcon = "exclamationmark.waveform"
            detail = "Airwave is getting ready again."
        case .unavailable:
            statusIcon = "exclamationmark.waveform"
            detail = "Airwave isn’t available right now."
        }
        let retryable: Bool
        switch status {
        case .needsPermission, .recovering: retryable = true
        default: retryable = false
        }
        return Self(
            statusIconName: statusIcon,
            healthTitle: status.title,
            healthDetail: detail,
            canRetry: retryable
        )
    }
}

enum RuntimeHealthRecoveryAction: Equatable {
    case reviewCapture
    case retry
    case chooseHRIR
    case openEqualizer
}

struct RuntimeHealthIssuePresentation: Equatable {
    let title: String
    let detail: String
    let suggestions: [String]
    let actionTitle: String
    let action: RuntimeHealthRecoveryAction

    static func make(for issue: RuntimeHealthIssue) -> Self {
        switch issue {
        case .permissionRequired:
            Self(
                title: "System Audio Capture permission is required",
                detail: "Airwave cannot capture system audio until access is enabled.",
                suggestions: ["Enable Airwave in Privacy & Security → System Audio Capture, then run the test again."],
                actionTitle: "Review Permission",
                action: .reviewCapture
            )
        case .noUsableOutput:
            Self(
                title: "No usable audio output",
                detail: "Airwave is waiting for a physical stereo output.",
                suggestions: ["Connect or select your headphones or another physical stereo output in macOS."],
                actionTitle: "Retry",
                action: .retry
            )
        case .unsupportedOutput(let reason):
            Self(
                title: "Unsupported audio output",
                detail: reason,
                suggestions: ["Select a physical stereo output; virtual, aggregate, and non-stereo outputs are unsupported."],
                actionTitle: "Retry",
                action: .retry
            )
        case .captureTestFailed(let reason):
            Self(
                title: "System Audio Capture test failed",
                detail: reason,
                suggestions: ["Test again. If it repeats, confirm capture permission and select a supported output."],
                actionTitle: "Review Capture",
                action: .reviewCapture
            )
        case .audioPipelineFailed(let reason):
            Self(
                title: "Audio processing could not start",
                detail: reason,
                suggestions: ["Retry, reconnect or switch the output, and relaunch Airwave if the problem persists."],
                actionTitle: "Retry",
                action: .retry
            )
        case .resourceRecovery(let reason):
            Self(
                title: "Airwave is recovering audio resources",
                detail: reason,
                suggestions: ["Airwave retries automatically. Use Retry if recovery does not complete."],
                actionTitle: "Retry",
                action: .retry
            )
        case .spatialPresetFailed(let reason):
            Self(
                title: "Spatial profile could not be loaded",
                detail: reason,
                suggestions: ["Choose another HRIR preset or re-import the affected file."],
                actionTitle: "Choose HRIR Preset",
                action: .chooseHRIR
            )
        case .equalizerFailed(let reason):
            Self(
                title: "Equalizer preset could not be applied",
                detail: reason,
                suggestions: ["Choose another preset, re-import it, or select None to disable EQ."],
                actionTitle: "Open Equalizer",
                action: .openEqualizer
            )
        }
    }
}

struct OnboardingReadinessPresentation: Equatable {
    let title: String
    let detail: String
    let actionStep: OnboardingStepV2?
    let actionTitle: String?
    let canRetry: Bool
    let isAttention: Bool

    static func make(
        captureAccess: CaptureAccessPresentation,
        hasPreset: Bool,
        runtimeStatus: AudioRuntimeState.Status,
        isReady: Bool,
        hasCaptureFailureGuidance: Bool = false
    ) -> Self {
        if isReady {
            return Self(
                title: "You’re ready to go",
                detail: hasPreset
                    ? "Airwave is set up and ready to apply your spatial profile."
                    : "Airwave setup is complete. Choose an HRIR preset whenever you’re ready to enable spatial processing.",
                actionStep: nil,
                actionTitle: nil,
                canRetry: false,
                isAttention: false
            )
        }

        if hasCaptureFailureGuidance {
            return Self(
                title: "A little more setup is needed",
                detail: "System Audio Capture still needs your attention.",
                actionStep: .systemAudio,
                actionTitle: "Review Capture",
                canRetry: false,
                isAttention: true
            )
        }

        switch captureAccess {
        case .permissionRequired:
            return Self(
                title: "A little more setup is needed",
                detail: "System Audio Capture still needs your attention.",
                actionStep: .systemAudio,
                actionTitle: "Review Permission",
                canRetry: false,
                isAttention: true
            )
        case .failed:
            return Self(
                title: "A little more setup is needed",
                detail: "System Audio Capture failed. Review the capture step and try again.",
                actionStep: .systemAudio,
                actionTitle: "Review Capture",
                canRetry: false,
                isAttention: true
            )
        case .unverified:
            return Self(
                title: "Capture not confirmed",
                detail: "Run the System Audio Capture test to confirm Airwave can process system audio.",
                actionStep: .systemAudio,
                actionTitle: "Test System Audio Capture",
                canRetry: false,
                isAttention: false
            )
        case .checking:
            return Self(
                title: "Checking system audio capture",
                detail: "Airwave is running the capture test.",
                actionStep: nil,
                actionTitle: nil,
                canRetry: false,
                isAttention: false
            )
        case .verified:
            break
        }

        let menuPresentation = RuntimeMenuPresentation.make(from: runtimeStatus)
        return Self(
            title: "A little more setup is needed",
            detail: runtimeStatus == .starting
                ? "Airwave is getting everything ready. This should only take a moment."
                : "Airwave isn’t ready yet. Review the earlier steps or try again.",
            actionStep: nil,
            actionTitle: nil,
            canRetry: menuPresentation.canRetry,
            isAttention: menuPresentation.canRetry
        )
    }
}
