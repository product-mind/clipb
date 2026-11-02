import Testing
@testable import clipb

@Suite struct MicrophoneTests {
    private let airPods = Microphone(id: 7, name: "Vojtech’s AirPods Pro", builtIn: false, hasInput: true)
    private let speakers = Microphone(id: 3, name: "MacBook Pro Speakers", builtIn: true, hasInput: false)
    private let laptop = Microphone(id: 5, name: "MacBook Pro Microphone", builtIn: true, hasInput: true)
    private let usb = Microphone(id: 9, name: "Shure MV7", builtIn: false, hasInput: true)
    private var all: [Microphone] { [airPods, speakers, usb, laptop] }

    @Test func defaultsPreferTheBuiltInMicOverTheSystemDefault() {
        #expect(Microphone.choose(preferences: VoiceConfig.defaultMicrophones, devices: all, defaultID: airPods.id) == laptop)
    }

    @Test func lidClosedFallsBackToTheSystemDefault() {
        #expect(Microphone.choose(preferences: VoiceConfig.defaultMicrophones, devices: [airPods, usb], defaultID: usb.id) == usb)
    }

    @Test func firstConnectedPreferenceWins() {
        let prefs = ["Rode NT-USB", "shure mv7", "built-in"]
        #expect(Microphone.choose(preferences: prefs, devices: all, defaultID: nil) == usb)
        #expect(Microphone.choose(preferences: prefs, devices: [laptop, airPods], defaultID: nil) == laptop)
    }

    @Test func builtInSpeakersAreNotAMic() {
        #expect(Microphone.choose(preferences: ["built-in", "MacBook Pro Speakers"], devices: [speakers], defaultID: speakers.id) == nil)
    }

    @Test func nothingListedConnectedMeansNoMic() {
        #expect(Microphone.choose(preferences: ["built-in"], devices: [airPods, usb], defaultID: airPods.id) == nil)
        #expect(Microphone.choose(preferences: ["default"], devices: [airPods], defaultID: nil) == nil)
        #expect(Microphone.choose(preferences: VoiceConfig.defaultMicrophones, devices: [], defaultID: nil) == nil)
    }
}
