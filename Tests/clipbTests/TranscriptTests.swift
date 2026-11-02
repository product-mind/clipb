import Testing
@testable import clipb

@Suite struct TranscriptTests {
    @Test func trimsAndCollapsesWhitespace() {
        #expect(Transcript.clean("  Hello   world.\n") == "Hello world.")
    }

    @Test func keepsCzech() {
        #expect(Transcript.clean(" Ahoj, tohle je test.") == "Ahoj, tohle je test.")
    }

    @Test func dropsKnownHallucinations() {
        #expect(Transcript.clean(" Thank you.") == nil)
        #expect(Transcript.clean("you") == nil)
        #expect(Transcript.clean("Thanks for watching!") == nil)
        #expect(Transcript.clean(" Děkuji.") == nil)
    }

    @Test func keepsHallucinationWordsInsideRealSpeech() {
        #expect(Transcript.clean("Thank you for the review.") == "Thank you for the review.")
    }

    @Test func dropsNonSpeechTags() {
        #expect(Transcript.clean("[BLANK_AUDIO]") == nil)
        #expect(Transcript.clean(" (silence) ") == nil)
        #expect(Transcript.clean("[Music] Ship it. *coughs*") == "Ship it.")
    }

    @Test func dropsPunctuationOnlyCollapse() {
        #expect(Transcript.clean(" - ") == nil)
        #expect(Transcript.clean("...") == nil)
        #expect(Transcript.clean("") == nil)
    }

    @Test func padsShortAudioToAboveOneSecond() {
        #expect(Transcript.padded([Float](repeating: 1, count: 8000)).count == 17600)
        #expect(Transcript.padded([Float](repeating: 1, count: 32000)).count == 32000)
    }
}
