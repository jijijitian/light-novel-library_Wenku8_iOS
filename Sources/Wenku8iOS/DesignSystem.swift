import SwiftUI

/// Centralises the Liquid Glass treatment so every surface degrades the same way
/// on systems that predate iOS 26.
///
/// The `Glass` type and the `.glassEffect` family only exist in the iOS 26 SDK,
/// so they are fenced behind `#if compiler(>=6.2)` — that is the toolchain that
/// ships with Xcode 26. Building with an older Xcode (iOS 18 SDK) still compiles
/// and simply takes the material fallback below, which is the same appearance
/// an iOS 17/18 device sees at runtime.
enum GlassSurface {
    static var isAvailable: Bool {
        if #available(iOS 26.0, *) { return true }
        return false
    }
}

#if compiler(>=6.2)
@available(iOS 26.0, *)
private func makeGlass(tint: Color?, interactive: Bool) -> Glass {
    var glass: Glass = .regular
    if let tint {
        glass = glass.tint(tint)
    }
    if interactive {
        glass = glass.interactive()
    }
    return glass
}
#endif

extension View {
    /// Wraps content in a Liquid Glass shape on iOS 26+, and in a thin material
    /// with a hairline stroke everywhere else.
    @ViewBuilder
    func glassSurface<S: Shape & InsettableShape>(
        _ shape: S,
        tint: Color? = nil,
        interactive: Bool = false
    ) -> some View {
        #if compiler(>=6.2)
        if #available(iOS 26.0, *) {
            self.glassEffect(makeGlass(tint: tint, interactive: interactive), in: shape)
        } else {
            materialSurface(shape)
        }
        #else
        materialSurface(shape)
        #endif
    }

    private func materialSurface<S: Shape & InsettableShape>(_ shape: S) -> some View {
        self
            .background(.ultraThinMaterial, in: shape)
            .overlay(shape.strokeBorder(Color.white.opacity(0.18), lineWidth: 0.75))
    }

    func glassCapsule(tint: Color? = nil, interactive: Bool = false) -> some View {
        glassSurface(.capsule, tint: tint, interactive: interactive)
    }

    func glassCard(cornerRadius: CGFloat = 22, tint: Color? = nil) -> some View {
        glassSurface(.rect(cornerRadius: cornerRadius, style: .continuous), tint: tint)
    }

    /// Prominent action button: Liquid Glass on iOS 26+, bordered prominent before that.
    @ViewBuilder
    func prominentGlassButtonShape() -> some View {
        #if compiler(>=6.2)
        if #available(iOS 26.0, *) {
            self.buttonStyle(.glassProminent).buttonBorderShape(.capsule)
        } else {
            self.buttonStyle(.borderedProminent).buttonBorderShape(.capsule)
        }
        #else
        self.buttonStyle(.borderedProminent).buttonBorderShape(.capsule)
        #endif
    }

    /// Secondary action button: Liquid Glass on iOS 26+, bordered before that.
    @ViewBuilder
    func secondaryGlassButtonShape(capsule: Bool = true) -> some View {
        #if compiler(>=6.2)
        if #available(iOS 26.0, *) {
            if capsule {
                self.buttonStyle(.glass).buttonBorderShape(.capsule)
            } else {
                self.buttonStyle(.glass)
            }
        } else if capsule {
            self.buttonStyle(.bordered).buttonBorderShape(.capsule)
        } else {
            self.buttonStyle(.bordered)
        }
        #else
        if capsule {
            self.buttonStyle(.bordered).buttonBorderShape(.capsule)
        } else {
            self.buttonStyle(.bordered)
        }
        #endif
    }
}

/// Wraps children in `GlassEffectContainer` on iOS 26+, and leaves them alone otherwise.
struct GlassContainer<Content: View>: View {
    var spacing: CGFloat
    @ViewBuilder var content: () -> Content

    var body: some View {
        #if compiler(>=6.2)
        if #available(iOS 26.0, *) {
            GlassEffectContainer(spacing: spacing) { content() }
        } else {
            content()
        }
        #else
        content()
        #endif
    }
}

/// A raised bezel behind cover art, used on the home and detail screens.
struct CoverCard: View {
    var url: URL?
    var title: String
    var width: CGFloat = 96
    var height: CGFloat = 136

    var body: some View {
        CoverImage(url: url)
            .frame(width: width, height: height)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.16), lineWidth: 0.5)
            )
            .shadow(color: .black.opacity(0.28), radius: 8, y: 4)
            .accessibilityLabel(Text(title.isEmpty ? "小说封面" : title))
    }
}

struct CoverImage: View {
    var url: URL?

    var body: some View {
        Group {
            if url == nil {
                // No URL means there is nothing to fetch — not "still fetching". An
                // `AsyncImage` given nil stays in `.empty` for good, so it drew a spinner
                // that never stopped on covers the source does not have.
                placeholder
            } else {
                AsyncImage(url: url, transaction: Transaction(animation: .easeOut(duration: 0.18))) { phase in
                    switch phase {
                    case .success(let image):
                        image.resizable().scaledToFill()
                    case .failure:
                        placeholder
                    case .empty:
                        ZStack {
                            placeholder
                            ProgressView().controlSize(.small)
                        }
                    @unknown default:
                        placeholder
                    }
                }
            }
        }
        .background(Color.secondary.opacity(0.14))
    }

    private var placeholder: some View {
        ZStack {
            LinearGradient(
                colors: [Color.secondary.opacity(0.22), Color.secondary.opacity(0.10)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            Image(systemName: "book.closed.fill")
                .font(.system(size: 22))
                .foregroundStyle(.white.opacity(0.55))
        }
    }
}

struct TagChip: View {
    var text: String
    var systemImage: String?

    var body: some View {
        HStack(spacing: 4) {
            if let systemImage {
                Image(systemName: systemImage).font(.caption2)
            }
            Text(text).font(.caption.weight(.medium))
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 4)
        .glassCapsule()
    }
}

struct SectionHeader: View {
    var title: String
    var subtitle: String?
    var symbol: String?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            if let symbol {
                Image(systemName: symbol)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.tint)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                if let subtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
        }
    }
}

struct EmptyStateView: View {
    var symbol: String
    var title: String
    var message: String
    var actionTitle: String?
    var action: (() -> Void)?

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 38, weight: .light))
                .foregroundStyle(.tint)
            Text(title).font(.headline)
            Text(message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .buttonStyle(.borderedProminent)
                    .padding(.top, 4)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 36)
    }
}

struct ErrorStateView: View {
    var error: Error
    var retry: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "wifi.exclamationmark")
                .font(.system(size: 36, weight: .light))
                .foregroundStyle(.orange)
            Text(errorMessage)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
            Button("重试", action: retry)
                .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 36)
    }

    private var errorMessage: String {
        (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }
}

struct LoadingRow: View {
    var text: String = "正在加载…"

    var body: some View {
        HStack(spacing: 10) {
            ProgressView()
            Text(text).font(.subheadline).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
    }
}
