import SwiftUI

// MARK: - FormatPicker

struct FormatPicker: View {
    @EnvironmentObject private var mainVM: MainViewModel

    var body: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 12) {
                PickerRow(label: "Format") {
                    PillRow(options: OutputFormat.allCases.map(\.rawValue).uppercasedAll,
                            selection: mainVM.selectedFormat.rawValue.uppercased()) { value in
                        if let format = OutputFormat(rawValue: value.lowercased()) {
                            withAnimation(.easeInOut(duration: 0.2)) { mainVM.selectedFormat = format }
                            if format.isAudioOnly { mainVM.clipEnabled = false }
                        }
                    }
                }

                if !mainVM.selectedFormat.isAudioOnly {
                    PickerRow(label: "Resolution") {
                        PillRow(options: TargetResolution.allCases.map(\.rawValue),
                                selection: mainVM.selectedResolution.rawValue) { value in
                            if let res = TargetResolution(rawValue: value) {
                                withAnimation(.easeInOut(duration: 0.2)) { mainVM.selectedResolution = res }
                            }
                        }
                    }
                }

                PickerRow(label: "Target Size") {
                    HStack(spacing: 8) {
                        PillRow(options: ["Original"],
                                selection: mainVM.targetSizeMB == nil ? "Original" : "") { _ in
                            withAnimation(.easeInOut(duration: 0.2)) { mainVM.targetSizeMB = nil }
                        }
                        TextField("MB", text: $mainVM.customSizeText)
                            .frame(width: 64)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 12))
                    }
                }

                Toggle(isOn: $mainVM.clipEnabled.animation(.spring(response: 0.3, dampingFraction: 0.7))) {
                    Label("Clip", systemImage: "scissors")
                        .labelStyle(.titleAndIcon)
                        .font(.system(size: 13, weight: .medium))
                        .symbolEffect(.bounce, value: mainVM.clipEnabled)
                }
                .toggleStyle(.switch)
                .disabled(mainVM.selectedFormat.isAudioOnly || (mainVM.metadata?.duration ?? 0) < 2)
            }
            .padding(14)
        }
    }
}

// MARK: - Reusable pill row

struct PillRow: View {
    let options: [String]
    let selection: String
    let onSelect: (String) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(options, id: \.self) { option in
                    Button {
                        onSelect(option)
                    } label: {
                        Text(option)
                            .font(.system(size: 12, weight: .medium))
                            .padding(.horizontal, 11)
                            .padding(.vertical, 5)
                    }
                    .buttonStyle(PillOptionStyle(isSelected: option == selection))
                }
            }
        }
    }
}

struct PillOptionStyle: ButtonStyle {
    let isSelected: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(isSelected ? Color.white : Color.primary.opacity(0.7))
            .background(
                Capsule().fill(isSelected ? Color.accentColor : Color.primary.opacity(0.06))
            )
            .opacity(configuration.isPressed ? 0.75 : 1)
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .animation(.easeInOut(duration: 0.2), value: isSelected)
    }
}

struct PickerRow<Content: View>: View {
    let label: String
    @ViewBuilder var content: Content

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Text(label)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(ClipTheme.secondary)
                .frame(width: 74, alignment: .leading)
            content
        }
    }
}

private extension [String] {
    var uppercasedAll: [String] { map { $0.uppercased() } }
}

// MARK: - ClipRange (draggable timecode bar)

struct ClipRange: View {
    @EnvironmentObject private var mainVM: MainViewModel

    @State private var barWidth: CGFloat = 0
    @State private var draggingStart = false
    @State private var draggingEnd = false

    private var duration: Double {
        max(1, mainVM.metadata?.duration ?? 60)
    }

    var body: some View {
        GlassCard(cornerRadius: ClipConstants.smallCornerRadius) {
            VStack(spacing: 10) {
                HStack {
                    Text(timecode(mainVM.clipRange.startSeconds ?? 0))
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(ClipTheme.accent)
                    Spacer()
                    Image(systemName: "scissors")
                        .font(.system(size: 11))
                        .foregroundStyle(ClipTheme.secondary)
                    Spacer()
                    Text(timecode(mainVM.clipRange.endSeconds ?? duration))
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(ClipTheme.accent)
                }

                GeometryReader { geo in
                    let startFrac = (mainVM.clipRange.startSeconds ?? 0) / duration
                    let endFrac = (mainVM.clipRange.endSeconds ?? duration) / duration

                    ZStack(alignment: .leading) {
                        // Track
                        Capsule()
                            .fill(Color.primary.opacity(0.08))
                            .frame(height: 6)

                        // Selected span
                        Capsule()
                            .fill(ClipTheme.accent.opacity(0.35))
                            .frame(width: geo.size.width * CGFloat(endFrac - startFrac))
                            .offset(x: geo.size.width * CGFloat(startFrac))

                        handle(x: geo.size.width * CGFloat(startFrac),
                               isDragging: draggingStart) { delta in
                            move(edge: \.start, by: delta, in: geo.size.width)
                        } onDragChanged: { draggingStart = $0 }

                        handle(x: geo.size.width * CGFloat(endFrac),
                               isDragging: draggingEnd) { delta in
                            move(edge: \.end, by: delta, in: geo.size.width)
                        } onDragChanged: { draggingEnd = $0 }
                    }
                    .onAppear { barWidth = geo.size.width }
                    .onChange(of: geo.size.width) { barWidth = $0 }
                }
                .frame(height: ClipConstants.clipRangeHeight / 2)
            }
            .padding(12)
        }
        .transition(.opacity.combined(with: .move(edge: .top)))
    }

    private func handle(x: CGFloat, isDragging: Bool,
                        onDelta: @escaping (CGFloat) -> Void,
                        onDragChanged: @escaping (Bool) -> Void) -> some View {
        RoundedRectangle(cornerRadius: 3, style: .continuous)
            .fill(Color.white)
            .frame(width: 10, height: 26)
            .shadow(color: .black.opacity(0.18), radius: 2, x: 0, y: 1)
            .overlay(
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .strokeBorder(Color.accentColor, lineWidth: isDragging ? 2 : 1.5)
            )
            .scaleEffect(isDragging ? 1.12 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.6), value: isDragging)
            .offset(x: x - 5)
            .gesture(
                DragGesture(minimumDistance: 1)
                    .onChanged { value in
                        onDragChanged(true)
                        onDelta(value.translation.width)
                    }
                    .onEnded { _ in onDragChanged(false) }
            )
    }

    private func move(edge keyPath: WritableKeyPath<ClipRange, Double?>,
                      by translation: CGFloat, in width: CGFloat) {
        guard width > 0 else { return }
        let secondsPerPoint = duration / Double(width)
        var range = mainVM.clipRange
        let current = range[keyPath: keyPath] ?? (keyPath == \.start ? 0 : duration)
        var next = current + Double(translation) * secondsPerPoint
        next = min(max(next, 0), duration)

        if keyPath == \.start {
            let end = range.endSeconds ?? duration
            range.startSeconds = min(next, end - 0.5)
        } else {
            let start = range.startSeconds ?? 0
            range.endSeconds = max(next, start + 0.5)
        }
        mainVM.clipRange = range
    }

    private func timecode(_ t: Double) -> String {
        String(format: "%d:%02d.%d", Int(t) / 60, Int(t) % 60, Int((t.truncatingRemainder(dividingBy: 1)) * 10))
    }
}
