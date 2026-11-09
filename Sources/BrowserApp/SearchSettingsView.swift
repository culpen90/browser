import AppKit
import SwiftUI

@MainActor
final class SearchSettingsView: NSView {
    enum Status {
        case starting
        case ready
        case stopped
        case unavailable(String)
    }

    struct Source: Identifiable {
        let id: String
        let name: String
        let detail: String
        let symbol: String
    }

    struct Snapshot {
        let status: Status
        let sources: [Source]
        let defaults: Set<String>
        var selected: Set<String>
        var safeSearch: Int
    }

    struct Preferences {
        let selected: Set<String>
        let safeSearch: Int
    }

    @MainActor
    final class Model: ObservableObject {
        @Published var snapshot: Snapshot
        var onChange: ((Preferences) -> Void)?
        var onRestart: (() -> Void)?
        var onStop: (() -> Void)?
        var onBack: (() -> Void)?

        init(snapshot: Snapshot) {
            self.snapshot = snapshot
        }

        fileprivate func apply(selected: Set<String>, safeSearch: Int) {
            guard !selected.isEmpty, (0...2).contains(safeSearch),
                  selected != snapshot.selected || safeSearch != snapshot.safeSearch else { return }
            var updated = snapshot
            updated.selected = selected
            updated.safeSearch = safeSearch
            snapshot = updated
            onChange?(Preferences(selected: selected, safeSearch: safeSearch))
        }
    }

    init(model: Model) {
        super.init(frame: .zero)
        let hosting = NSHostingView(rootView: SearchSettingsContent(model: model))
        hosting.translatesAutoresizingMaskIntoConstraints = false
        addSubview(hosting)
        NSLayoutConstraint.activate([
            hosting.leadingAnchor.constraint(equalTo: leadingAnchor),
            hosting.trailingAnchor.constraint(equalTo: trailingAnchor),
            hosting.topAnchor.constraint(equalTo: topAnchor),
            hosting.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

@MainActor
private struct SearchSettingsContent: View {
    @ObservedObject var model: SearchSettingsView.Model
    private let blue = Color(nsColor: .systemBlue)

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                service
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .top, spacing: 16) {
                        sources.frame(minWidth: 360)
                        VStack(spacing: 16) {
                            safeSearch
                            privacy
                        }
                        .frame(width: 264)
                    }
                    VStack(spacing: 16) {
                        sources
                        safeSearch
                        privacy
                    }
                }
                if let back = model.onBack {
                    Button(action: back) { Label("Back to browsing", systemImage: "chevron.left") }
                }
            }
            .frame(maxWidth: 760, alignment: .leading)
            .padding(24)
            .frame(maxWidth: .infinity)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .tint(blue)
    }

    private var header: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 20) {
                heading
                Spacer(minLength: 0)
                emblem
            }
            heading
        }
        .padding(22)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 20).fill(
                LinearGradient(colors: [blue.opacity(0.16), blue.opacity(0.04)],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
            )
        }
    }

    private var heading: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("BROWSER SEARCH")
                .font(.caption.weight(.bold))
                .tracking(1.4)
                .foregroundStyle(blue)
            Text("Search settings")
                .font(.system(size: 32, weight: .bold, design: .rounded))
                .accessibilityAddTraits(.isHeader)
            Text("Choose what powers the results you see in Browser.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var emblem: some View {
        ZStack(alignment: .topTrailing) {
            RoundedRectangle(cornerRadius: 19)
                .fill(blue.opacity(0.13))
                .frame(width: 66, height: 66)
            Image(systemName: "magnifyingglass")
                .font(.system(size: 30, weight: .semibold))
                .foregroundStyle(blue)
                .frame(width: 66, height: 66)
            Image(systemName: "sparkle")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(blue)
                .offset(x: 6, y: -6)
        }
        .accessibilityHidden(true)
    }

    private var service: some View {
        card {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .center, spacing: 18) {
                    serviceDescription
                    Spacer(minLength: 0)
                    serviceActions
                }
                VStack(alignment: .leading, spacing: 12) {
                    serviceDescription
                    serviceActions
                }
            }
        }
    }

    private var serviceDescription: some View {
        HStack(alignment: .top, spacing: 12) {
            let presentation = servicePresentation
            Image(systemName: presentation.symbol)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(presentation.color)
                .frame(width: 34, height: 34)
                .background(presentation.color.opacity(0.11), in: RoundedRectangle(cornerRadius: 10))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text("Local SearXNG")
                    .font(.headline)
                    .accessibilityAddTraits(.isHeader)
                Text(presentation.title)
                    .font(.subheadline.weight(.semibold))
                Text(presentation.detail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var servicePresentation: (title: String, detail: String, symbol: String, color: Color) {
        switch model.snapshot.status {
        case .starting:
            return ("Starting", "Browser is starting your search engine on this Mac.", "hourglass", blue)
        case .ready:
            return ("Running on this Mac", "Ready to search your enabled sources.", "checkmark.circle.fill", .green)
        case .stopped:
            return ("Stopped", "Start SearXNG to search from the address bar.", "pause.circle.fill", .secondary)
        case .unavailable(let detail):
            return ("Needs attention", detail, "exclamationmark.triangle.fill", .orange)
        }
    }

    @ViewBuilder
    private var serviceActions: some View {
        switch model.snapshot.status {
        case .ready:
            HStack(spacing: 8) {
                Button("Restart", action: { model.onRestart?() })
                    .disabled(model.onRestart == nil)
                    .accessibilityLabel("Restart local search")
                stopButton
            }
        case .starting:
            HStack(spacing: 10) {
                ProgressView().controlSize(.small).accessibilityLabel("Starting local search")
                stopButton
            }
        case .stopped:
            Button("Start search", action: { model.onRestart?() })
                .buttonStyle(.borderedProminent)
                .disabled(model.onRestart == nil)
        case .unavailable:
            Button("Try again", action: { model.onRestart?() })
                .buttonStyle(.borderedProminent)
                .disabled(model.onRestart == nil)
        }
    }

    private var stopButton: some View {
        Button("Stop", action: { model.onStop?() })
            .disabled(model.onStop == nil)
            .accessibilityLabel("Stop local search")
    }

    private var sources: some View {
        card {
            VStack(alignment: .leading, spacing: 12) {
                Text("Search sources")
                    .font(.headline)
                    .accessibilityAddTraits(.isHeader)
                Text("Mix sources to shape the results you get.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                presets
                Divider()
                ForEach(model.snapshot.sources) { source in
                    sourceRow(source)
                }
                Text(sourceSummary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var presets: some View {
        let recommended = model.snapshot.defaults
        let all = Set(model.snapshot.sources.map(\.id))
        return HStack(spacing: 8) {
            preset("Recommended", selected: recommended)
            if all != recommended {
                preset("All sources", selected: all)
            }
        }
        .controlSize(.small)
    }

    private func preset(_ name: String, selected: Set<String>) -> some View {
        let active = selected == model.snapshot.selected
        return Button {
            model.apply(selected: selected, safeSearch: model.snapshot.safeSearch)
        } label: {
            Label(name, systemImage: active ? "checkmark.circle.fill" : "circle")
        }
        .disabled(selected.isEmpty)
        .accessibilityValue(active ? "Selected" : "")
    }

    private func sourceRow(_ source: SearchSettingsView.Source) -> some View {
        let selected = model.snapshot.selected.contains(source.id)
        let last = selected && model.snapshot.selected.count == 1
        return Toggle(isOn: Binding(
            get: { model.snapshot.selected.contains(source.id) },
            set: { enabled in
                var ids = model.snapshot.selected
                if enabled { ids.insert(source.id) } else { ids.remove(source.id) }
                model.apply(selected: ids, safeSearch: model.snapshot.safeSearch)
            }
        )) {
            HStack(spacing: 10) {
                Image(systemName: source.symbol)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(blue)
                    .frame(width: 22)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(source.name).font(.subheadline.weight(.semibold))
                    Text(source.detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 4)
            }
        }
        .toggleStyle(.switch)
        .controlSize(.small)
        .disabled(last)
        .accessibilityLabel(source.name)
        .accessibilityHint(last ? "Keep at least one search source on." : source.detail)
    }

    private var sourceSummary: String {
        let count = model.snapshot.selected.count
        return count == 1 ? "1 source on. Keep at least one enabled." : "\(count) sources on"
    }

    private var safeSearch: some View {
        card {
            VStack(alignment: .leading, spacing: 10) {
                Label("SafeSearch", systemImage: "shield")
                    .font(.headline)
                    .accessibilityAddTraits(.isHeader)
                Text("Filter explicit results on sources that support it.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Picker("SafeSearch", selection: Binding(
                    get: { model.snapshot.safeSearch },
                    set: { model.apply(selected: model.snapshot.selected, safeSearch: $0) }
                )) {
                    Text("Off").tag(0)
                    Text("Moderate").tag(1)
                    Text("Strict").tag(2)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .accessibilityLabel("SafeSearch")
            }
        }
    }

    private var privacy: some View {
        card {
            VStack(alignment: .leading, spacing: 7) {
                Label("Where queries go", systemImage: "network")
                    .font(.headline)
                    .accessibilityAddTraits(.isHeader)
                Text("Browser talks to SearXNG on this Mac. The sources you enable receive your query from your internet connection, and their availability can vary.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func card<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        content()
            .padding(17)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 15))
            .overlay {
                RoundedRectangle(cornerRadius: 15).strokeBorder(.primary.opacity(0.09))
                    .allowsHitTesting(false)
            }
    }
}
