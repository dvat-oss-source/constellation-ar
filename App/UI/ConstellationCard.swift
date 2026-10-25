import Observation
import SwiftUI

/// What the card shows for the locked constellation.
@MainActor
@Observable
final class ConstellationCardModel: Identifiable {
    enum DeepDive: Equatable {
        case idle
        case streaming(String)
        case done(String)
        case cached(text: String, reason: String)
        case failed(String)
    }

    let id: String
    let name: String
    let narration: NarrationFile.Card?
    let stars: [CardStar]
    var deepDive: DeepDive = .idle

    init(id: String, name: String, narration: NarrationFile.Card?, catalogStars: [CardStar]) {
        self.id = id
        self.name = name
        self.narration = narration
        if let entries = narration?.brightestStars, !entries.isEmpty {
            stars = entries.map { CardStar(name: $0.name, vmag: $0.vmag ?? .nan, distanceLy: $0.distanceLy) }
        } else {
            stars = catalogStars
        }
    }

    /// Text read aloud: the summary and how to find it.
    var spokenText: String? {
        narration.map { "\($0.name). \($0.summary) \($0.howToFind)" }
    }
}

struct ConstellationCard: View {
    let card: ConstellationCardModel
    @Bindable var narrator: Narrator
    let hasDeepDiveKey: Bool
    let onTellMore: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(card.name).font(.title3.bold())
                Spacer()
                Button {
                    narrator.isMuted.toggle()
                } label: {
                    Image(systemName: narrator.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                        .frame(width: 36, height: 36)
                }
                .accessibilityLabel(narrator.isMuted ? "Unmute narration" : "Mute narration")
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    if let narration = card.narration {
                        Text(narration.summary).font(.subheadline)
                        Text("How to find it").font(.footnote.bold())
                        Text(narration.howToFind).font(.footnote)
                    } else {
                        Text("Narration not generated yet. Showing catalog facts only.").font(.footnote.italic()).foregroundStyle(.secondary)
                    }
                    if !card.stars.isEmpty {
                        Text("Brightest stars").font(.footnote.bold())
                        ForEach(card.stars) { star in
                            HStack {
                                Text(star.name)
                                Spacer()
                                Text(Self.detail(star)).foregroundStyle(.secondary)
                            }
                            .font(.footnote.monospacedDigit())
                        }
                    }
                    deepDive
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 250)
        }
        .foregroundStyle(.white)
        .padding(14)
        .background(.black.opacity(0.72), in: RoundedRectangle(cornerRadius: 16))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("constellationCard")
    }

    @ViewBuilder private var deepDive: some View {
        switch card.deepDive {
        case .idle:
            Button("Tell me more", action: onTellMore).buttonStyle(.bordered).padding(.top, 4)
            if !hasDeepDiveKey {
                Text("No Vertex API key is set, so Tell me more can only show a saved answer.").font(.caption2).foregroundStyle(.secondary)
            }
        case .streaming(let text):
            Text(text.isEmpty ? "Asking Gemma…" : text).font(.footnote)
        case .done(let text):
            Text(text).font(.footnote)
        case .cached(let text, let reason):
            Text(text).font(.footnote)
            Text("\(reason). Showing the saved answer.").font(.caption2).foregroundStyle(.orange)
        case .failed(let message):
            Text(message).font(.footnote).foregroundStyle(.orange)
            Button("Try again", action: onTellMore).buttonStyle(.bordered)
        }
    }

    private static func detail(_ star: CardStar) -> String {
        var parts: [String] = []
        if star.vmag.isFinite { parts.append(String(format: "mag %.2f", star.vmag)) }
        if let ly = star.distanceLy { parts.append(String(format: "%.0f ly", ly)) }
        return parts.joined(separator: " · ")
    }
}

struct ObjectInfoCard: View {
    let info: ObjectInfo
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(info.title).font(.headline)
                Spacer()
                Button("Close", action: onClose).font(.footnote)
            }
            ForEach(info.lines, id: \.self) { Text($0).font(.footnote) }
            if let note = info.alignmentNote { Text(note).font(.footnote).foregroundStyle(.mint) }
        }
        .foregroundStyle(.white)
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.black.opacity(0.72), in: RoundedRectangle(cornerRadius: 14))
        .accessibilityIdentifier("objectInfoCard")
    }
}

struct SatellitePanel: View {
    let tracker: SatelliteTracker
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("International Space Station").font(.headline)
                Spacer()
                Button("Close", action: onClose).font(.footnote)
            }
            if let pass = tracker.nextISSPass {
                Text("Next visible pass").font(.footnote.bold())
                Text("\(pass.start.formatted(date: .abbreviated, time: .shortened)) to \(pass.end.formatted(date: .omitted, time: .shortened))")
                    .font(.footnote)
                Text("Rises \(pass.startDirection) at \(Int(pass.startAltitudeDegrees.rounded()))°, highest \(Int(pass.maxAltitudeDegrees.rounded()))° in the \(pass.maxDirection), sets \(pass.endDirection). Lasts \(Int((pass.durationSeconds / 60).rounded())) min.")
                    .font(.footnote)
            } else if tracker.dataStatus != nil {
                Text("No visible pass in the next five days, or still being calculated.").font(.footnote)
            }
            if let issSample = tracker.issSample {
                Text(issSample.visible ? "Visible right now." : (issSample.altitudeDegrees > 0 ? "Above the horizon, but not visible (daylight or Earth's shadow)." : "Below the horizon right now."))
                    .font(.footnote)
            }
            if let status = tracker.dataStatus {
                Text("Orbit data: \(status.summary)").font(.caption2).foregroundStyle(status.isStale ? .orange : .secondary)
            }
            if let error = tracker.errorMessage { Text(error).font(.caption2).foregroundStyle(.orange) }
        }
        .foregroundStyle(.white)
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.black.opacity(0.72), in: RoundedRectangle(cornerRadius: 14))
        .accessibilityIdentifier("satellitePanel")
    }
}
