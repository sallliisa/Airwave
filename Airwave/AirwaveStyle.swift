import SwiftUI

enum AirwavePalette {
    static let canvas = Color(red: 17 / 255, green: 17 / 255, blue: 17 / 255)
    static let raised = Color(red: 29 / 255, green: 29 / 255, blue: 29 / 255)
    static let hover = Color.white.opacity(0.08)
}

enum AirwaveLayout {
    static let sectionSpacing: CGFloat = 24
    static let sectionContentSpacing: CGFloat = 12
    static let cardSpacing: CGFloat = 12
    static let cardPadding: CGFloat = 12
    static let cardCornerRadius: CGFloat = 8
    static let rowHorizontalPadding: CGFloat = 12
    static let rowVerticalPadding: CGFloat = 8
    static let menuGroupPadding: CGFloat = 4
    static let menuRowHorizontalPadding: CGFloat = 12
    static let menuRowVerticalPadding: CGFloat = 6
    static let menuOuterPadding: CGFloat = 6
    static let menuDividerInset: CGFloat = 10
}

struct AirwavePresetList: View {
    let presets: [HRIRPreset]
    let selectedID: UUID?
    let onSelect: (HRIRPreset?) -> Void

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 2) {
                selectionRow("None", selected: selectedID == nil) { onSelect(nil) }
                ForEach(MenuBarViewModel.sortedPresets(presets)) { preset in
                    selectionRow(preset.name, selected: selectedID == preset.id) { onSelect(preset) }
                }
                if presets.isEmpty {
                    Text("No compatible presets found")
                        .font(.callout).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(AirwaveLayout.cardPadding)
                }
            }
            .padding(6)
        }
        .frame(maxHeight: .infinity)
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

struct AirwavePresetFilesRow: View {
    let action: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "folder.fill")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .frame(width: 20)
            Text("Manage HRIR WAV files")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer()
            Button("Manage Files", action: action)
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .fixedSize()
        }
        .padding(.horizontal, AirwaveLayout.rowHorizontalPadding)
        .padding(.vertical, AirwaveLayout.rowVerticalPadding)
    }
}

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

private struct AirwaveHRIRDropModifier: ViewModifier {
    let manager: HRIRManager
    let onSelect: (HRIRPreset?) -> Void
    @State private var isTargeted = false
    @State private var conflicts: [URL] = []
    @State private var pendingValidURLs: [URL] = []
    @State private var message: String?

    func body(content: Content) -> some View {
        content
            .overlay {
                RoundedRectangle(cornerRadius: AirwaveLayout.cardCornerRadius)
                    .strokeBorder(Color.primary.opacity(isTargeted ? 0.8 : 0), style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
            }
            .overlay(alignment: .bottom) {
                if isTargeted {
                    Label("Drop HRIR WAV files", systemImage: "square.and.arrow.down")
                        .font(.callout.weight(.medium)).padding(8)
                        .background(.regularMaterial, in: Capsule()).padding(10)
                }
            }
            .dropDestination(for: URL.self) { urls, _ in
                Task { @MainActor in
                    await Task.yield()
                    handle(urls)
                }
                return true
            } isTargeted: { isTargeted = $0 }
            .confirmationDialog(
                conflicts.count == 1 ? "Replace existing preset?" : "Replace \(conflicts.count) existing presets?",
                isPresented: Binding(get: { !conflicts.isEmpty }, set: { if !$0 { conflicts = [] } })
            ) {
                Button("Replace") { importURLs(pendingValidURLs, policy: .replace); clearPending() }
                Button("Keep Existing", role: .cancel) { importURLs(pendingValidURLs, policy: .reject); clearPending() }
            } message: {
                Text("Airwave will replace files with the same name. The original dropped files are not changed.")
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if let message {
                    HStack {
                        Text(message).font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button("Dismiss") { self.message = nil }.buttonStyle(.plain).font(.caption)
                    }
                    .padding(8).background(AirwavePalette.raised)
                }
            }
    }

    private func handle(_ urls: [URL]) {
        message = nil
        let preflight = manager.preflightImport(urls)
        let validSet = Set(preflight.acceptable + preflight.conflicts)
        let validInInputOrder = urls.filter { validSet.contains($0) }
        if preflight.conflicts.isEmpty {
            importURLs(validInInputOrder, policy: .reject)
        } else {
            pendingValidURLs = validInInputOrder
            conflicts = preflight.conflicts
        }
        if !preflight.rejected.isEmpty {
            message = "\(preflight.rejected.count) file\(preflight.rejected.count == 1 ? "" : "s") could not be imported."
        }
    }

    private func importURLs(_ urls: [URL], policy: HRIRImportCollisionPolicy) {
        let result = manager.importPresets(urls, collisionPolicy: policy)
        if let first = result.imported.first { onSelect(first) }
        if !result.failures.isEmpty {
            message = "\(result.imported.count) imported; \(result.failures.count) could not be imported."
        } else if !result.imported.isEmpty {
            message = "Imported \(result.imported.count) preset\(result.imported.count == 1 ? "" : "s")."
        }
    }

    private func clearPending() {
        conflicts = []
        pendingValidURLs = []
    }
}

extension View {
    func airwaveHRIRDropTarget(manager: HRIRManager, onSelect: @escaping (HRIRPreset?) -> Void) -> some View {
        modifier(AirwaveHRIRDropModifier(manager: manager, onSelect: onSelect))
    }
}
