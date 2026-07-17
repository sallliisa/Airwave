import AppKit
import Combine
import SwiftUI
import UniformTypeIdentifiers

enum AirwavePalette {
    static let canvas = Color(red: 17 / 255, green: 17 / 255, blue: 17 / 255)
    static let raised = Color(red: 29 / 255, green: 29 / 255, blue: 29 / 255)
    static let hover = Color.white.opacity(0.08)
}

enum AirwaveResourceLinks {
    static let hrir = URL(string: "https://airtable.com/embed/appac4r1cu9UpBNAN/shrpUAbtyZxhDDMjg/tblopH2GznvFipWjq/viwnouWPGDuYEd8Go")!
    static let equalizer = URL(string: "https://autoeq.app/")!
}

enum AirwaveLayout {
    static let sectionSpacing: CGFloat = 16
    static let sectionContentSpacing: CGFloat = 12
    static let cardSpacing: CGFloat = 8
    static let cardPadding: CGFloat = 12
    static let cardCornerRadius: CGFloat = 8
    static let pageHeaderContentMinimumSpacing: CGFloat = 24
    static let compactPageHorizontalPadding: CGFloat = 30
    static let compactPageTopPadding: CGFloat = 94
    static let compactPageBottomPadding: CGFloat = 104
    static let compactPageMaxWidth: CGFloat = 680
    static let rowHorizontalPadding: CGFloat = 12
    static let rowVerticalPadding: CGFloat = 8
    static let menuGroupPadding: CGFloat = 4
    static let menuRowHorizontalPadding: CGFloat = 12
    static let menuRowVerticalPadding: CGFloat = 6
    static let menuOuterPadding: CGFloat = 6
    static let menuDividerInset: CGFloat = 10
}

enum AirwaveMotion {
    static let pageTransitionDuration: TimeInterval = 0.3
    static let pageTransition: Animation = .smooth(duration: pageTransitionDuration)
}

enum AirwavePageLayoutMode: Equatable {
    case fullScreen
    case compact

    var contentPadding: EdgeInsets {
        switch self {
        case .fullScreen:
            EdgeInsets(top: 80, leading: 24, bottom: 24, trailing: 24)
        case .compact:
            EdgeInsets(
                top: AirwaveLayout.compactPageTopPadding,
                leading: AirwaveLayout.compactPageHorizontalPadding,
                bottom: AirwaveLayout.compactPageBottomPadding,
                trailing: AirwaveLayout.compactPageHorizontalPadding
            )
        }
    }

    var maxContentWidth: CGFloat {
        switch self {
        case .fullScreen: 1000
        case .compact: AirwaveLayout.compactPageMaxWidth
        }
    }
}

struct AirwavePageLayout<Content: View>: View {
    let mode: AirwavePageLayoutMode
    @ViewBuilder let content: () -> Content

    var body: some View {
        content()
            .padding(mode.contentPadding)
            .frame(maxWidth: mode.maxContentWidth, maxHeight: .infinity, alignment: .topLeading)
            .frame(maxWidth: .infinity, alignment: .top)
    }
}

private struct AirwaveBlurScaleTransitionModifier: ViewModifier {
    let isIdentity: Bool

    func body(content: Content) -> some View {
        content
            .scaleEffect(isIdentity ? 1 : 0.97)
            .blur(radius: isIdentity ? 0 : 8)
            .opacity(isIdentity ? 1 : 0)
    }
}

extension AnyTransition {
    static var airwaveBlurScaleReveal: AnyTransition {
        .modifier(
            active: AirwaveBlurScaleTransitionModifier(isIdentity: false),
            identity: AirwaveBlurScaleTransitionModifier(isIdentity: true)
        )
    }
}

struct AirwaveEqualHeightColumnsLayout: Layout {
    let spacing: CGFloat

    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) -> CGSize {
        let columnWidth = proposal.width.map { max(0, ($0 - spacing * CGFloat(max(0, subviews.count - 1))) / CGFloat(max(1, subviews.count))) }
        let sizes = subviews.map { subview in
            subview.sizeThatFits(ProposedViewSize(width: columnWidth, height: nil))
        }
        let intrinsicWidth = sizes.reduce(0) { $0 + $1.width } + spacing * CGFloat(max(0, sizes.count - 1))
        let intrinsicHeight = sizes.map(\.height).max() ?? 0

        return CGSize(
            width: proposal.width ?? intrinsicWidth,
            height: proposal.height ?? intrinsicHeight
        )
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) {
        guard !subviews.isEmpty else { return }

        let columnWidth = max(0, (bounds.width - spacing * CGFloat(subviews.count - 1)) / CGFloat(subviews.count))
        var x = bounds.minX
        for subview in subviews {
            subview.place(
                at: CGPoint(x: x, y: bounds.minY),
                anchor: .topLeading,
                proposal: ProposedViewSize(width: columnWidth, height: bounds.height)
            )
            x += columnWidth + spacing
        }
    }
}

struct AirwaveTopBar<Center: View, Trailing: View>: View {
    @ViewBuilder let center: () -> Center
    @ViewBuilder let trailing: () -> Trailing

    var body: some View {
        ZStack {
            HStack(spacing: 12) {
                Image("AirwaveMark")
                    .renderingMode(.template)
                    .resizable()
                    .scaledToFit()
                    .foregroundStyle(.primary)
                    .frame(width: 24, height: 24)
                    .accessibilityLabel("Airwave")
                Text("Airwave").font(.headline)
                Spacer(minLength: 12)
                trailing()
            }

            center()
        }
        .frame(height: 32)
        .padding(.horizontal, 24)
        .padding(.top, 14)
        .padding(.bottom, 24)
    }
}

nonisolated struct HRIRSettingsLibraryRow: Equatable, Identifiable {
    let id: String
    let name: String
    let preset: HRIRPreset?
    let isSelected: Bool
}

nonisolated enum HRIRSettingsLibraryModel {
    static func rows(presets: [HRIRPreset], selectedID: UUID?) -> [HRIRSettingsLibraryRow] {
        guard !presets.isEmpty else { return [] }
        return [HRIRSettingsLibraryRow(
            id: "none",
            name: "None",
            preset: nil,
            isSelected: selectedID == nil
        )] + presets.sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }.map { preset in
            HRIRSettingsLibraryRow(
                id: preset.id.uuidString,
                name: preset.name,
                preset: preset,
                isSelected: selectedID == preset.id
            )
        }
    }
}

nonisolated enum HRIRConflictResolution {
    case replace
    case keepExisting
    case cancel
}

nonisolated enum HRIRDeletionDecision {
    case confirm
    case cancel
}

nonisolated struct HRIRSettingsMessage: Equatable {
    let text: String
}

@MainActor
final class HRIRSettingsCoordinator: ObservableObject {
    @Published private(set) var conflicts: [URL] = []
    @Published private(set) var message: HRIRSettingsMessage?

    let manager: HRIRManager
    private var pendingURLs: [URL] = []
    private var pendingFailures: [HRIRImportFailure] = []

    init(manager: HRIRManager) {
        self.manager = manager
    }

    func receive(_ urls: [URL]) {
        message = nil
        conflicts = []
        pendingURLs = []
        pendingFailures = []
        guard !urls.isEmpty else { return }

        let preflight = manager.preflightImport(urls)
        let validURLs = urls.filter { url in
            preflight.acceptable.contains(url) || preflight.conflicts.contains(url)
        }
        pendingFailures = preflight.rejected

        if preflight.conflicts.isEmpty {
            importURLs(validURLs, collisionPolicy: .reject, preflightFailures: pendingFailures)
        } else {
            pendingURLs = validURLs
            conflicts = preflight.conflicts
        }
    }

    func resolveConflicts(_ resolution: HRIRConflictResolution) {
        guard !conflicts.isEmpty else { return }
        let urls = pendingURLs
        let failures = pendingFailures
        pendingURLs = []
        pendingFailures = []
        conflicts = []

        switch resolution {
        case .replace:
            importURLs(urls, collisionPolicy: .replace, preflightFailures: failures)
        case .keepExisting:
            importURLs(urls, collisionPolicy: .reject, preflightFailures: failures)
        case .cancel:
            message = makeMessage(failures: failures)
        }
    }

    func dismissMessage() {
        message = nil
    }

    func presentImportPanel() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsOtherFileTypes = false
        panel.allowedContentTypes = [UTType(filenameExtension: "wav") ?? .audio]
        panel.title = "Import HRIR Presets"
        panel.message = "Choose one or more compatible HRIR WAV files."
        guard panel.runModal() == .OK else { return }
        receive(panel.urls)
    }

    func showInFinder() {
        manager.openPresetsDirectory()
    }

    @discardableResult
    func delete(_ preset: HRIRPreset, decision: HRIRDeletionDecision) -> Bool {
        guard decision == .confirm else { return false }
        guard manager.deletePreset(preset) else {
            message = HRIRSettingsMessage(
                text: manager.errorMessage.map { "Could not delete \(preset.name): \($0)" }
                    ?? "Could not delete the managed HRIR preset."
            )
            return false
        }
        message = nil
        return true
    }

    private func importURLs(
        _ urls: [URL],
        collisionPolicy: HRIRImportCollisionPolicy,
        preflightFailures: [HRIRImportFailure] = []
    ) {
        let result = manager.importPresets(urls, collisionPolicy: collisionPolicy)
        message = makeMessage(failures: preflightFailures + result.failures)
    }

    private func makeMessage(failures: [HRIRImportFailure]) -> HRIRSettingsMessage? {
        guard !failures.isEmpty else { return nil }
        return HRIRSettingsMessage(
            text: failures.map { "\($0.filename): \($0.reason)" }.joined(separator: " • ")
        )
    }
}

struct AirwaveEmptyLibraryState: View {
    let systemImage: String
    let title: String
    let description: String

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: systemImage)
                .font(.system(size: 24))
                .foregroundStyle(.secondary)
            Text(title)
                .font(.system(size: 13, weight: .semibold))
            Text(description)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        .padding(AirwaveLayout.cardPadding)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title). \(description)")
    }
}

struct AirwavePresetList: View {
    let presets: [HRIRPreset]
    let selectedID: UUID?
    let onSelect: (HRIRPreset?) -> Void

    var body: some View {
        ZStack {
            if presets.isEmpty {
                AirwaveEmptyLibraryState(
                    systemImage: "waveform",
                    title: "No HRIR presets",
                    description: "Airwave normally ships Neutral, Room, and Stage. Import a compatible WAV file to add another spatial profile."
                )
            } else {
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(HRIRSettingsLibraryModel.rows(presets: presets, selectedID: selectedID)) { row in
                            selectionRow(row.name, selected: row.isSelected) { onSelect(row.preset) }
                        }
                    }
                    .padding(6)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func selectionRow(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                Text(title).font(.callout).lineLimit(1)
                Spacer()
                if selected { Image(systemName: "checkmark").font(.caption.weight(.semibold)) }
            }
            .padding(.horizontal, AirwaveLayout.rowHorizontalPadding)
            .padding(.vertical, AirwaveLayout.rowVerticalPadding)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(selected ? AirwavePalette.hover : .clear, in: RoundedRectangle(cornerRadius: 6))
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

//struct AirwavePresetDropHint: View {
//    var body: some View {
//        HStack(spacing: 10) {
//            Image(systemName: "square.and.arrow.down")
//                .font(.system(size: 12))
//                .foregroundStyle(.secondary)
//                .frame(width: 20)
//            Text("Drag and drop your HRIR files here")
//                .font(.system(size: 11))
//                .foregroundStyle(.secondary)
//            Spacer(minLength: 0)
//        }
//        .padding(.horizontal, AirwaveLayout.rowHorizontalPadding)
//        .padding(.vertical, AirwaveLayout.rowVerticalPadding)
//        .accessibilityElement(children: .combine)
//        .accessibilityLabel("You can drag and drop HRIR WAV files anywhere in this selector")
//    }
//}

struct AirwaveScrollEdgeFades: View {
    var bottomHeight: CGFloat = 110

    var body: some View {
        VStack(spacing: 0) {
            LinearGradient(
                stops: [
                    .init(color: AirwavePalette.canvas, location: 0),
                    .init(color: AirwavePalette.canvas, location: 0.3),
                    .init(color: AirwavePalette.canvas.opacity(0.55), location: 0.58),
                    .init(color: .clear, location: 1)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(height: 112)

            Spacer(minLength: 0)

            LinearGradient(
                colors: [.clear, AirwavePalette.canvas.opacity(0.94), AirwavePalette.canvas],
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(height: bottomHeight)
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }
}


struct AirwavePressedButtonStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.96 : 1)
            .opacity(configuration.isPressed ? 0.82 : 1)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.1), value: configuration.isPressed)
    }
}

struct AirwaveIconButton: View {
    let systemImage: String
    let accessibilityLabel: String
    let help: String
    let isProminent: Bool
    let isEnabled: Bool
    let action: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(isProminent ? AirwavePalette.canvas : (isHovering ? Color.primary : Color.secondary))
                .frame(width: 34, height: 34)
                .background { Circle().fill(buttonBackground) }
                .contentShape(Circle())
        }
        .buttonStyle(AirwavePressedButtonStyle())
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.35)
        .help(help)
        .accessibilityLabel(accessibilityLabel)
        .onHover { hovering in
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.14)) {
                isHovering = hovering
            }
        }
    }

    private var buttonBackground: Color {
        if isProminent {
            return Color.primary.opacity(isHovering ? 0.78 : 0.92)
        }
        return isHovering ? AirwavePalette.hover : .clear
    }
}

struct AirwaveSectionHeader: View {
    let title: String
    let subtitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.title3.weight(.semibold))
            Text(subtitle).font(.callout).foregroundStyle(.secondary)
        }
    }
}

struct AirwaveNavigationCard: View {
    let systemImage: String
    let title: String
    let subtitle: String
    var showsWarning = false
    let action: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: systemImage)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 20)

                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.system(size: 12, weight: .semibold))
                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }

                Spacer(minLength: 8)

                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            .padding(AirwaveLayout.cardPadding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(
            showsWarning
                ? Color.orange.opacity(isHovering ? 0.18 : 0.10)
                : (isHovering ? AirwavePalette.hover : AirwavePalette.raised),
            in: RoundedRectangle(cornerRadius: AirwaveLayout.cardCornerRadius)
        )
        .onHover { hovering in
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.14)) {
                isHovering = hovering
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title): \(subtitle)")
        .accessibilityHint("Open \(title) settings")
    }
}

struct AirwaveHRIRPicker: View {
    @ObservedObject private var manager: HRIRManager
    let selectedID: UUID?
    let onSelect: (HRIRPreset?) -> Void
    let onDelete: (HRIRPreset) -> Void

    @StateObject private var coordinator: HRIRSettingsCoordinator
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isTargeted = false
    @State private var pendingDelete: HRIRPreset?

    @MainActor
    init(
        manager: HRIRManager,
        selectedID: UUID?,
        onSelect: @escaping (HRIRPreset?) -> Void,
        onDelete: @escaping (HRIRPreset) -> Void = { _ in }
    ) {
        _manager = ObservedObject(wrappedValue: manager)
        self.selectedID = selectedID
        self.onSelect = onSelect
        self.onDelete = onDelete
        _coordinator = StateObject(wrappedValue: HRIRSettingsCoordinator(manager: manager))
    }

    var body: some View {
        VStack(spacing: 0) {
            AirwavePresetList(
                presets: manager.presets,
                selectedID: selectedID,
                onSelect: onSelect
            )

            Divider()

            HStack(spacing: 8) {
                Button("Import…") { coordinator.presentImportPanel() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                Button("Manage…") { coordinator.showInFinder() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .help("Reveal the managed HRIR Presets folder")
                Link("Get more HRIRs…", destination: AirwaveResourceLinks.hrir)
                    .buttonStyle(.plain)
                    .foregroundStyle(.tint)
                    .font(.system(size: 11, weight: .medium))
                    .help("Open the HeSuVi HRTF Database")
                Spacer(minLength: 0)
                Button("Delete", role: .destructive) {
                    pendingDelete = selectedPreset
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(selectedPreset == nil)
                .help("Delete the selected managed HRIR preset")
            }
            .padding(AirwaveLayout.cardPadding)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay {
            RoundedRectangle(cornerRadius: AirwaveLayout.cardCornerRadius)
                .strokeBorder(
                    Color.primary.opacity(isTargeted ? 0.8 : 0),
                    style: StrokeStyle(lineWidth: 2, dash: [6, 4])
                )
        }
        .overlay(alignment: .bottom) {
            if isTargeted {
                Label("Drop HRIR WAV files", systemImage: "square.and.arrow.down")
                    .font(.callout.weight(.medium))
                    .padding(8)
                    .background(.regularMaterial, in: Capsule())
                    .padding(10)
                    .transition(.opacity)
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            coordinator.receive(urls)
            return true
        } isTargeted: { targeted in
            if reduceMotion {
                isTargeted = targeted
            } else {
                withAnimation(.easeOut(duration: 0.12)) { isTargeted = targeted }
            }
        }
        .confirmationDialog(
            coordinator.conflicts.count == 1
                ? "Replace existing preset?"
                : "Replace \(coordinator.conflicts.count) existing presets?",
            isPresented: Binding(
                get: { !coordinator.conflicts.isEmpty },
                set: { isPresented in
                    if !isPresented && !coordinator.conflicts.isEmpty {
                        coordinator.resolveConflicts(.cancel)
                    }
                }
            )
        ) {
            Button("Replace") { coordinator.resolveConflicts(.replace) }
            Button("Keep Existing", role: .cancel) {
                coordinator.resolveConflicts(.keepExisting)
            }
        } message: {
            Text("Files with the same name can replace the managed copy. Other valid files will still import.")
        }
        .confirmationDialog(
            "Delete \(pendingDelete?.name ?? "preset")?",
            isPresented: Binding(
                get: { pendingDelete != nil },
                set: { if !$0 { pendingDelete = nil } }
            ),
            presenting: pendingDelete
        ) { preset in
            Button("Delete", role: .destructive) {
                if coordinator.delete(preset, decision: .confirm) {
                    onDelete(preset)
                }
                pendingDelete = nil
            }
            Button("Cancel", role: .cancel) { pendingDelete = nil }
        } message: { preset in
            Text("This deletes the managed copy of \(preset.name) from Airwave’s HRIR Presets folder.")
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if let message = coordinator.message {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                    Text(message.text).font(.caption).foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                    Button("Dismiss") { coordinator.dismissMessage() }
                        .buttonStyle(.plain)
                        .font(.caption)
                }
                .padding(8)
                .background(AirwavePalette.raised)
                .accessibilityElement(children: .combine)
                .accessibilityLabel(message.text)
                .accessibilityAddTraits(.updatesFrequently)
            }
        }
    }

    private var selectedPreset: HRIRPreset? {
        manager.presets.first { $0.id == selectedID }
    }
}
