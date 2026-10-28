import AppKit
import Testing
@testable import clipb

/// A minimal PNG header: signature, IHDR length/type, then width and height.
func testPNG(width: UInt32, height: UInt32) -> Data {
    var bytes: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
    bytes += [0, 0, 0, 13]
    bytes += Array("IHDR".utf8)
    for value in [width, height] {
        bytes += [
            UInt8(value >> 24 & 0xFF),
            UInt8(value >> 16 & 0xFF),
            UInt8(value >> 8 & 0xFF),
            UInt8(value & 0xFF),
        ]
    }
    return Data(bytes)
}

@Suite struct ClipboardCaptureClassifyTests {
    @Test func textWinsOverImageAndFiles() {
        let result = ClipboardCapture.classify(
            text: "hello",
            png: testPNG(width: 2, height: 2),
            tiff: nil,
            fileURLStrings: ["file:///tmp/Report.pdf"]
        )
        #expect(result == .text("hello"))
    }

    @Test func blankTextFallsThroughToImage() {
        let png = testPNG(width: 3, height: 4)
        let result = ClipboardCapture.classify(text: "  \n", png: png, tiff: nil, fileURLStrings: [])
        #expect(result == .image(png))
    }

    @Test func imageWinsOverFileURLs() {
        let png = testPNG(width: 1, height: 1)
        let result = ClipboardCapture.classify(
            text: nil, png: png, tiff: nil, fileURLStrings: ["file:///tmp/a.txt"]
        )
        #expect(result == .image(png))
    }

    @Test func fileURLsAreCollected() {
        let result = ClipboardCapture.classify(
            text: nil, png: nil, tiff: nil,
            fileURLStrings: ["file:///tmp/one.txt", "file:///tmp/two.txt"]
        )
        #expect(result == .files([
            URL(fileURLWithPath: "/tmp/one.txt"),
            URL(fileURLWithPath: "/tmp/two.txt"),
        ]))
    }

    @Test func nothingPresentIsNil() {
        #expect(ClipboardCapture.classify(text: nil, png: nil, tiff: nil, fileURLStrings: []) == nil)
        #expect(ClipboardCapture.classify(text: nil, png: nil, tiff: nil, fileURLStrings: ["not a url"]) == nil)
    }

    @Test func oversizePNGIsSkipped() {
        let big = Data(count: ClipboardCapture.imageByteLimit + 1)
        #expect(ClipboardCapture.classify(text: nil, png: big, tiff: nil, fileURLStrings: []) == nil)
    }

    @Test func tiffIsConvertedToPNG() throws {
        let full = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 3,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        )
        let rep = try #require(full)
        let tiff = try #require(rep.representation(using: .tiff, properties: [:]))
        let result = ClipboardCapture.classify(text: nil, png: nil, tiff: tiff, fileURLStrings: [])
        guard case .image(let data)? = result else {
            Issue.record("expected an image, got \(String(describing: result))")
            return
        }
        #expect(Titles.pngDimensions(data)?.width == 2)
        #expect(Titles.pngDimensions(data)?.height == 3)
    }
}

@Suite struct ClipboardCaptureEntryTests {
    @Test func imageEntryUsesPlaceholderAndKeepsBytes() {
        let data = Data([1, 2, 3])
        let entry = ClipboardCapture.entry(for: .image(data), source: "Safari")
        #expect(entry.value == "[image]")
        #expect(entry.image == data)
        #expect(entry.source == "Safari")
    }

    @Test func fileEntryCarriesTheFirstNameAndAllURLs() {
        let urls = [URL(fileURLWithPath: "/tmp/Report.pdf"), URL(fileURLWithPath: "/tmp/Other.txt")]
        let entry = ClipboardCapture.entry(for: .files(urls), source: "Finder")
        #expect(entry.value == "[file] Report.pdf")
        #expect(entry.fileURLs == urls)
    }

    @Test func textEntryIsTrimmed() {
        let entry = ClipboardCapture.entry(for: .text("  hi \n"), source: nil)
        #expect(entry.value == "hi")
        #expect(entry.image == nil)
    }
}
