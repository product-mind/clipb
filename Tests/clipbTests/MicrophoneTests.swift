import Testing
@testable import clipb

@Suite struct MicrophoneTests {
    private let airPods = Microphone(id: 7, name: "AirPods Pro", builtIn: false, hasInput: true)
    private let speakers = Microphone(id: 3, name: "MacBook Pro Speakers", builtIn: true, hasInput: false)
    private let laptop = Microphone(id: 5, name: "MacBook Pro Microphone", builtIn: true, hasInput: true)
    private let usb = Microphone(id: 9, name: "Shure MV7", builtIn: false, hasInput: true)

    @Test func picksTheBuiltInMicOverEverythingElse() {
        #expect(Microphone.pick([airPods, speakers, usb, laptop]) == laptop)
    }

    @Test func builtInSpeakersAreNotAMic() {
        #expect(Microphone.pick([speakers]) == nil)
    }

    @Test func noBuiltInMicMeansNoMicNotTheDefault() {
        #expect(Microphone.pick([airPods, usb]) == nil)
        #expect(Microphone.pick([]) == nil)
    }
}
