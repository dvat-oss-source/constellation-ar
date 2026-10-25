import Foundation
import Testing
import simd
@testable import SkyCore

@Suite struct FocusQATests {
    static let enabled = FocusData.allFiles && RepoFiles.exists("Data/passages.json")
    static let evalEnabled = enabled && RepoFiles.exists("Data/test/qa_eval.json")

    // MARK: Passages and BM25

    @Test(.enabled(if: enabled))
    func passageLibraryHasStableUniqueIDsForAll88() throws {
        let lib = FocusData.library
        #expect(Set(lib.passages.map(\.id)).count == lib.passages.count)
        #expect(Set(lib.passages.map(\.constellation)).count == 88)
        let pattern = try Regex(#"^[A-Za-z]{2,3}-(wiki|allen|aratus)-\d+$"#)
        #expect(lib.passages.allSatisfy { $0.id.wholeMatch(of: pattern) != nil && $0.id.hasPrefix($0.constellation + "-" + $0.source.rawValue + "-") })
        for (cid, list) in lib.sources { #expect(list.contains { $0.key == .wiki && $0.revision != nil }, "\(cid) wiki revision pinned") }
        #expect(lib.passage(id: "Ori-wiki-8")?.text.contains("string of pearls") == true)
        #expect(lib.passages(for: "Ant").count > 10)
        report("passages: \(lib.passages.count) passages, \(lib.passages.map { $0.text.split(separator: " ").count }.reduce(0, +)) words")
    }

    @Test func bm25RanksByTermFrequencyAndRarity() {
        func p(_ id: String, _ text: String) -> Passage { Passage(id: id, constellation: "Ori", source: .wiki, heading: "", text: text) }
        let index = BM25Index(passages: [
            p("A", "Betelgeuse is a red supergiant in Orion"),
            p("B", "Rigel is a blue supergiant in Orion and a fine star"),
            p("C", "The sword of Orion holds a nebula nebula nebula"),
            p("D", "Unrelated text about Lyra and Vega"),
        ])
        #expect(index.search("red supergiant Betelgeuse").first?.passage.id == "A")
        #expect(index.search("nebula").first?.passage.id == "C")
        #expect(index.search("zzz nothing").isEmpty)
        let hits = index.search("supergiant Orion", limit: 3)
        #expect(hits.map(\.passage.id).prefix(2).sorted() == ["A", "B"] && !hits.contains { $0.passage.id == "D" })
        #expect(zip(hits, hits.dropFirst()).allSatisfy { $0.score >= $1.score })
        #expect(index.search("orion", constellation: "Cas").isEmpty)
        #expect(PassageTokenizer.tokens("The Stars' brightness — Orion's Belts") == ["star", "brightness", "orion", "belt"])
    }

    @Test(.enabled(if: evalEnabled))
    func bm25FindsSupportingPassagesForTheEvaluationQuestions() throws {
        let eval = try QAEvalSet(url: RepoFiles.url("Data/test/qa_eval.json"))
        var answerable = 0, top1 = 0, top5 = 0
        var misses: [String] = []
        for q in eval.questions where q.answerable {
            answerable += 1
            let hits = FocusData.bm25.search(q.question, limit: 5, constellation: q.constellation).map(\.passage.id)
            if let first = hits.first, q.supportingPassages.contains(first) { top1 += 1 }
            if hits.contains(where: q.supportingPassages.contains) { top5 += 1 } else { misses.append("\(q.id): \(q.question) -> \(hits)") }
        }
        report("BM25 on the evaluation set (per-constellation): \(answerable) answerable questions, supporting passage at rank 1 for \(top1), in top 5 for \(top5); misses \(misses)")
        #expect(top5 >= 23)
        // Without the constellation filter the question text alone still has to find the right constellation's passage most of the time.
        var unfiltered = 0
        for q in eval.questions where q.answerable {
            if FocusData.bm25.search(q.question, limit: 5).contains(where: { q.supportingPassages.contains($0.passage.id) }) { unfiltered += 1 }
        }
        report("BM25 on the evaluation set (all 88 constellations): top 5 for \(unfiltered) of \(answerable)")
        #expect(unfiltered >= 20)
    }

    // MARK: Evaluation set

    @Test(.enabled(if: evalEnabled))
    func evaluationSetIsWellFormedAndGrounded() throws {
        let eval = try QAEvalSet(url: RepoFiles.url("Data/test/qa_eval.json"))
        #expect(eval.questions.count == 30 && eval.constellations.count == 5)
        #expect(eval.questions.filter(\.answerable).count == 25 && eval.questions.filter { !$0.answerable }.count == 5)
        #expect(Set(eval.questions.map(\.id)).count == 30)
        for c in eval.constellations { #expect(eval.questions.filter { $0.constellation == c }.count == 6) }
        for q in eval.questions {
            let all = FocusData.library.passages(for: q.constellation).map { $0.text.lowercased() }.joined(separator: " ")
            if q.answerable {
                #expect(!q.supportingPassages.isEmpty && !q.keywords.isEmpty && q.expected == nil)
                let support = try q.supportingPassages.map { try #require(FocusData.library.passage(id: $0), "\(q.id): \($0)") }
                #expect(support.allSatisfy { $0.constellation == q.constellation })
                let text = support.map { $0.text.lowercased() }.joined(separator: " ")
                for k in q.keywords { #expect(text.contains(k.lowercased()), "\(q.id): '\(k)' in supporting passages") }
            } else {
                #expect(q.expected == "not in sources" && q.supportingPassages.isEmpty && !q.absentTerms.isEmpty)
                for t in q.absentTerms { #expect(!all.contains(t.lowercased()), "\(q.id): '\(t)' must be absent") }
                #expect(FocusData.verifier.verify(AnswerVerifier.notInSourcesAnswer).verified)
            }
        }
    }

    @Test(.enabled(if: evalEnabled))
    func anExtractiveAnswerFromTheSupportingPassageVerifiesForEveryAnswerableQuestion() throws {
        let eval = try QAEvalSet(url: RepoFiles.url("Data/test/qa_eval.json"))
        var verified = 0, quotable = 0
        for q in eval.questions where q.answerable {
            let passage = try #require(FocusData.library.passage(id: q.supportingPassages[0]))
            let sentences = passage.text.components(separatedBy: CharacterSet(charactersIn: ".\n"))
            guard let sentence = sentences.first(where: { s in
                q.keywords.contains { s.lowercased().contains($0.lowercased()) }
                    && !s.contains("\"") && !s.contains("\u{201c}") && s.split(separator: " ").count >= 4
            }) else { continue }
            quotable += 1
            let answer = "The sources say \"\(sentence.trimmingCharacters(in: .whitespaces))\" [P:\(passage.id)]"
            let result = FocusData.verifier.verify(answer)
            // Magnitude and distance wording inside a real quote may legitimately disagree with the catalogue; everything else must pass.
            let other = result.issues.filter { ![.magnitudeMismatch, .distanceMismatch, .distanceUnverifiable].contains($0.kind) }
            #expect(other.isEmpty, "\(q.id): \(result.issues)")
            if result.verified { verified += 1 }
        }
        report("verifier on extractive answers: \(quotable) quotable, \(verified) verified outright (the rest differ only in a catalogue number inside the quotation)")
        #expect(quotable >= 12 && verified >= quotable - 3)
    }

    // MARK: Verifier

    func verify(_ answer: String) -> VerificationResult { FocusData.verifier.verify(answer) }

    @Test(.enabled(if: enabled))
    func citationsMustExistAndFollowTheSyntax() {
        #expect(Citation.ids(in: "x [P:Ori-wiki-8] y [P:Ori-allen-3][P:Ori-wiki-8]") == ["Ori-wiki-8", "Ori-allen-3"])
        #expect(Citation.stripped(from: "Alnilam [P:Ori-wiki-8] is bright.") == "Alnilam  is bright.")
        #expect(verify("Alnilam is the middle star of the Belt [P:Ori-wiki-8].").verified)
        let none = verify("Alnilam is the middle star of the Belt.")
        #expect(!none.verified && none.issues.map(\.kind) == [.noCitation])
        let unknown = verify("Alnilam is in the Belt [P:Ori-wiki-9999].")
        #expect(!unknown.verified && unknown.issues.map(\.kind) == [.unknownCitation])
        let malformed = verify("Alnilam is in the Belt [P:Ori].")
        #expect(!malformed.verified && malformed.issues.map(\.kind) == [.malformedCitation])
        let mixed = verify("Alnilam is in the Belt [P:Ori-wiki-8][P:Zzz-wiki-1].")
        #expect(!mixed.verified && mixed.issues.map(\.kind) == [.unknownCitation] && mixed.citedIDs.count == 2)
    }

    @Test(.enabled(if: enabled))
    func quotationsMustAppearWordForWordInACitedPassage() throws {
        let p = try #require(FocusData.library.passage(id: "Ori-wiki-8"))
        #expect(p.text.contains("string of pearls"))
        #expect(verify("It means \"string of pearls\" [P:Ori-wiki-8].").verified)
        // Normalisation forgives whitespace, quote style and dashes only.
        #expect(verify("It means \u{201c}string   of\npearls\u{201d} [P:Ori-wiki-8].").verified)
        let apostrophe = try #require(FocusData.library.passages.first { $0.text.contains("Orion's") })
        let twisted = "Orion\u{2019}s"
        #expect(AnswerVerifier.normalize(twisted) == AnswerVerifier.normalize("Orion's"))
        #expect(AnswerVerifier.normalize("a\u{2014}b") == AnswerVerifier.normalize("a - b") || AnswerVerifier.normalize("a\u{2014}b") == "a-b")
        #expect(verify("The text says \"\(twisted)\" [P:\(apostrophe.id)].").verified)
        // Anything else is rejected.
        let reworded = verify("It means \"string of gems\" [P:Ori-wiki-8].")
        #expect(!reworded.verified && reworded.issues.map(\.kind) == [.quoteNotFound])
        let caseChanged = verify("It means \"String of pearls\" [P:Ori-wiki-8].")
        #expect(!caseChanged.verified)
        let elsewhere = verify("It means \"string of pearls\" [P:Ori-wiki-7].")
        #expect(!elsewhere.verified && elsewhere.issues.map(\.kind) == [.quoteNotInCitedPassage] && elsewhere.issues[0].detail.contains("Ori-wiki-8"))
        let spliced = verify("It is \"the middle and brightest star of the Belt, a string of pearls\" [P:Ori-wiki-8].")
        #expect(!spliced.verified)
        #expect(verify("Plain \u{2018}string of pearls\u{2019} quotes [P:Ori-wiki-8].").verified)
        #expect(verify("It means \"string of pearls\" [P:Ori-wiki-8]. It is \"zebra crossing\" [P:Ori-wiki-8].").issues.map(\.kind) == [.quoteNotFound])
        #expect(verify("It means \"string of pearls\" [P:Ori-wiki-8].").quotesChecked == 1)
    }

    @Test(.enabled(if: enabled))
    func magnitudeAndDistanceClaimsAttributedToStarsMatchTheCatalogue() throws {
        let cat = FocusData.catalog
        let betelgeuse = try #require(cat.star(hip: 27989)), rigel = try #require(cat.star(hip: 24436))
        let bDistance = 3261.563777 / Double(betelgeuse.parallaxMas)
        report(String(format: "catalogue: Betelgeuse V %.2f %.0f ly, Rigel V %.2f %.0f ly", betelgeuse.vmag, bDistance, rigel.vmag, 3261.563777 / Double(rigel.parallaxMas)))

        func v(_ s: String) -> VerificationResult { verify(s + " [P:Ori-wiki-6]") }
        // Positive: names, designations, units.
        #expect(v("Betelgeuse has an apparent magnitude of 0.45.").verified)
        #expect(v("Betelgeuse has an apparent magnitude of 0.45.").numbersChecked == 1)
        #expect(v("α Orionis shines at magnitude +0.5.").verified)
        #expect(v("Alpha Orionis has magnitude 0.5 and lies \(Int(bDistance.rounded())) light-years away.").numbersChecked == 2)
        #expect(v("Alpha Ori is \(Int(bDistance.rounded())) light years from us.").verified)
        #expect(v("Betelgeuse is about \(String(format: "%.0f", bDistance / 3.26156)) parsecs away.").verified)
        #expect(v("Rigel (magnitude 0.13) and Betelgeuse (magnitude 0.5) are the two brightest.").numbersChecked == 2)
        #expect(v("Betelgeuse is \(String(format: "%.0f", bDistance * 1.08)) ± 30 light-years away.").verified)
        // Negative.
        let wrongMag = v("Betelgeuse has an apparent magnitude of 2.5.")
        #expect(!wrongMag.verified && wrongMag.issues.map(\.kind) == [.magnitudeMismatch])
        let edge = v("Betelgeuse shines at magnitude \(String(format: "%.2f", Double(betelgeuse.vmag) + 0.14)).")
        #expect(edge.verified, "within the 0.15 tolerance")
        let beyond = v("Betelgeuse shines at magnitude \(String(format: "%.2f", Double(betelgeuse.vmag) + 0.2)).")
        #expect(!beyond.verified)
        let wrongDistance = v("Betelgeuse is 900 light-years away.")
        #expect(!wrongDistance.verified && wrongDistance.issues.map(\.kind) == [.distanceMismatch])
        let wikipediaStyle = v("Betelgeuse is 548 light-years away.")
        report("548 ly claim vs catalogue \(Int(bDistance)) ly: verified \(wikipediaStyle.verified) (\(wikipediaStyle.issues.map(\.detail)))")
        let secondOfTwo = v("Rigel (magnitude 0.13) and Betelgeuse (magnitude 3.0) are bright.")
        #expect(!secondOfTwo.verified && secondOfTwo.issues.count == 1 && secondOfTwo.issues[0].detail.contains("HIP 27989"))
        let wrongStar = v("Rigel is 250 light-years away.")
        #expect(!wrongStar.verified && wrongStar.issues[0].detail.contains("HIP 24436"))
        let parsecs = v("Betelgeuse is 40 parsecs away.")
        #expect(!parsecs.verified)
        // Not checked: no star in the sentence, absolute magnitude, unrelated numbers.
        let unattributed = v("The constellation is rich in stars brighter than magnitude 2.")
        #expect(unattributed.verified && unattributed.numbersChecked == 0)
        #expect(v("Betelgeuse has an absolute magnitude of -5.8.").verified)
        #expect(v("Betelgeuse is the 10th brightest star and has 700 times the Sun's diameter.").numbersChecked == 0)
        // A star without a catalogue parallax cannot confirm a distance.
        let noParallax = FocusData.catalog.stars.first { !($0.parallaxMas > 0) && FocusData.starFacts.vmag(hip: $0.hip) != nil && FocusData.atlas.brightStar($0).iauName != nil }
        if let star = noParallax, let name = FocusData.atlas.brightStar(star).iauName {
            let r = v("\(name) is 300 light-years away.")
            #expect(!r.verified && r.issues.map(\.kind) == [.distanceUnverifiable])
        }
    }

    @Test(.enabled(if: enabled))
    func notInSourcesIsAcceptedOnlyAsTheWholeAnswer() {
        let r = verify("Not in sources.")
        #expect(r.verified && r.isNotInSources && r.citedIDs.isEmpty)
        #expect(verify("not in sources").isNotInSources)
        #expect(!verify("Not in sources, but Betelgeuse has magnitude 9.").isNotInSources)
        #expect(!verify("Betelgeuse is red.").verified)
    }
}

extension ConstellationAtlas {
    func brightStar(_ s: CatalogStar) -> ConstellationFacts.BrightStar { brightStar(s, constellation: "") }
}
