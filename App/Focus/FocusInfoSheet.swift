import SwiftUI
import SkyCore

struct FocusInfoSheet: View {
    @Environment(\.stylePalette) private var palette
    let constellationID: String
    let name: String
    let narration: NarrationFile.Card?
    let facts: ConstellationFacts?
    @Bindable var chat: FocusChatModel
    @Bindable var card: ConstellationCardModel
    let hasDeepDiveKey: Bool
    let onTellMore: () -> Void
    let onSendChat: () -> Void
    let onClose: () -> Void
    let scrollChatIntoView: Bool
    let onChatScrolled: () -> Void

    @FocusState private var chatFieldFocused: Bool

    private enum ScrollID {
        static let chat = "focusChatSection"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(name).font(.title2.weight(.semibold))
                Spacer()
                Button("Close", action: onClose).font(.footnote.weight(.medium))
            }
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        narrationSection
                        factsSection
                        starsSection
                        dsoSection
                        bodiesSection
                        tellMeMoreSection
                        chatSection
                            .id(ScrollID.chat)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 340)
                .onAppear { revealChatIfNeeded(proxy: proxy) }
                .onChange(of: scrollChatIntoView) { _, _ in revealChatIfNeeded(proxy: proxy) }
            }
        }
        .padding(16)
        .skyPanel()
        .accessibilityIdentifier("focusInfoSheet")
    }

    @ViewBuilder private var narrationSection: some View {
        if let narration {
            Text(narration.summary).font(.subheadline)
            Text("How to find it").font(.footnote.bold())
            Text(narration.howToFind).font(.footnote)
            if let myth = narration.mythology, !myth.isEmpty {
                Text("Mythology").font(.footnote.bold())
                Text(myth).font(.footnote)
            }
            if let quotes = narration.quotes, !quotes.isEmpty {
                Text("Quotes").font(.footnote.bold())
                ForEach(Array(quotes.enumerated()), id: \.offset) { _, q in
                    Text("“\(q.text)”").font(.footnote.italic())
                    if let source = q.source {
                        Text("— \(source)").font(.caption2).foregroundStyle(palette.secondaryColor)
                    }
                }
            }
        } else {
            Text("Narration not loaded.").font(.footnote.italic()).foregroundStyle(palette.secondaryColor)
        }
    }

    @ViewBuilder private var factsSection: some View {
        if let facts {
            Text("Tonight").font(.footnote.bold())
            Text(String(format: "Alt %.0f°, az %.0f° (%@)", facts.altitudeDegrees, facts.azimuthDegrees,
                        CompassDirection.name(azimuthDegrees: facts.azimuthDegrees))).font(.footnote.monospacedDigit())
            Text(facts.isVisibleNow ? "Visible now." : "Not visible now (below horizon or daylight).").font(.footnote)
            switch facts.visibility {
            case .circumpolar:
                Text("Circumpolar at your latitude.").font(.footnote)
            case .neverRises:
                Text("Never rises at your latitude.").font(.footnote)
            case .risesAndSets:
                if let rise = facts.rise, let set = facts.set {
                    Text("Rise \(rise.formatted(date: .omitted, time: .shortened)), transit \(facts.transit.formatted(date: .omitted, time: .shortened)) (\(Int(facts.transitAltitudeDegrees.rounded()))°), set \(set.formatted(date: .omitted, time: .shortened))")
                        .font(.footnote)
                }
            }
            Text(String(format: "Transit altitude %.0f°", facts.transitAltitudeDegrees)).font(.footnote.monospacedDigit())
        }
    }

    @ViewBuilder private var starsSection: some View {
        if let facts, !facts.brightestStars.isEmpty {
            Text("Brightest stars").font(.footnote.bold())
            ForEach(facts.brightestStars, id: \.hip) { star in
                HStack {
                    Text(star.displayName)
                    Spacer()
                    Text(starDetail(star)).foregroundStyle(palette.secondaryColor)
                }
                .font(.footnote.monospacedDigit())
            }
        }
    }

    @ViewBuilder private var dsoSection: some View {
        if let facts, !facts.deepSkyObjects.isEmpty {
            Text("Deep-sky (\(facts.deepSkyTotal))").font(.footnote.bold())
            ForEach(facts.deepSkyObjects.prefix(6), id: \.id) { o in
                Text(o.displayName + (o.mag.map { String(format: ", mag %.1f", $0) } ?? "")).font(.footnote)
            }
        }
    }

    @ViewBuilder private var bodiesSection: some View {
        if let facts, !facts.bodies.isEmpty {
            Text("Planets & Moon").font(.footnote.bold())
            ForEach(facts.bodies, id: \.body) { b in
                Text("\(b.body.name), mag \(String(format: "%.1f", b.magnitude))").font(.footnote)
            }
        }
    }

    @ViewBuilder private var tellMeMoreSection: some View {
        Text("Tell me more").font(.footnote.bold())
        switch card.deepDive {
        case .idle:
            Button("Tell me more", action: onTellMore).buttonStyle(.bordered)
            if !hasDeepDiveKey {
                Text("No Vertex API key — saved answers only.").font(.caption2).foregroundStyle(palette.secondaryColor)
            }
        case .streaming(let text):
            Text(text.isEmpty ? "Asking Gemma…" : text).font(.footnote)
        case .done(let text), .cached(let text, _):
            Text(text).font(.footnote)
        case .failed(let message):
            Text(message).font(.footnote).foregroundStyle(palette.lightColor)
            Button("Try again", action: onTellMore).buttonStyle(.bordered)
        }
    }

    private var chatSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Ask about \(name)").font(.footnote.bold())
            if chat.isStreaming, let status = chat.statusText {
                Text(status).font(.caption2.italic()).foregroundStyle(palette.secondaryColor)
            }
            ForEach(chat.messages) { msg in
                VStack(alignment: .leading, spacing: 2) {
                    Text(msg.role == .user ? "You" : "Guide").font(.caption2.bold()).foregroundStyle(palette.secondaryColor)
                    Text(msg.text.isEmpty ? "…" : msg.text).font(.footnote)
                    if let label = msg.verificationLabel {
                        Text(label).font(.caption2).foregroundStyle(label.hasPrefix("verified") ? palette.lightColor : palette.secondaryColor)
                    }
                }
            }
            HStack(spacing: 8) {
                TextField("Ask a question…", text: $chat.draft, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(1...3)
                    .focused($chatFieldFocused)
                    .disabled(chat.isStreaming)
                    .onSubmit(onSendChat)
                Button("Send", action: onSendChat)
                    .disabled(chat.isStreaming || chat.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .accessibilityIdentifier("focusChatSection")
    }

    private func revealChatIfNeeded(proxy: ScrollViewProxy) {
        guard scrollChatIntoView else { return }
        withAnimation(StyleTokens.panelAnimation) {
            proxy.scrollTo(ScrollID.chat, anchor: .bottom)
        }
        chatFieldFocused = true
        onChatScrolled()
    }

    private func starDetail(_ star: ConstellationFacts.BrightStar) -> String {
        var parts = [String(format: "mag %.2f", star.vmag)]
        if let ly = star.distanceLightYears { parts.append(String(format: "%.0f ly", ly)) }
        return parts.joined(separator: " · ")
    }
}
