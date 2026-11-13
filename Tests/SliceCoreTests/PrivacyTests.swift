//
//  PrivacyTests.swift
//  SliceCoreTests
//
//  Created by rit3zh CX on 10/17/26.
//

import AppKit
import AVFoundation
import CoreImage
@testable import SliceCore
import XCTest

final class PrivacyTests: XCTestCase {
    func kinds(_ line: String) -> [SensitiveText.Kind] { SensitiveText.matches(in: line).map(\.kind) }

    func testFindsEmailsCardsAndKeys() {
        XCTAssertEqual(kinds("Contact me at jane.doe+work@example.co.uk today"), [.email])
        XCTAssertEqual(kinds("Card 4242 4242 4242 4242 exp 12/30"), [.card])
        XCTAssertEqual(kinds("OPENAI_API_KEY=sk-proj-AbCdEf1234567890GhIjKl"), [.key])
        XCTAssertEqual(kinds("token ghp_aBcDeFgHiJkLmNoPqRsTuVwXyZ0123456789"), [.key])
        XCTAssertEqual(kinds("AKIAIOSFODNN7EXAMPLE"), [.key])
        XCTAssertEqual(kinds("eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.dozjgNryP4J3jVmNHl0w5N_XgL0n3I9PlFUP0THsR8U"), [.key])
    }

    func testIgnoresOrdinaryText() {
        XCTAssertTrue(kinds("The quick brown fox jumps over the lazy dog").isEmpty)
        XCTAssertTrue(kinds("Order 1234 5678 9012 3456 shipped").isEmpty, "fails the Luhn check")
        XCTAssertTrue(kinds("Call 555-0100 or visit example.com").isEmpty)
        XCTAssertTrue(kinds("/Users/someone/Library/Application Support/Slice").isEmpty)
    }

    func testBlurHidesOnlyItsBox() throws {
        let screen = RenderTests.fakeScreen(size: CGSize(width: 1600, height: 1000))
        let size = screen.extent.size
        let renderer = FrameRenderer()
        let box = CGRect(x: 0.2, y: 0.1, width: 0.6, height: 0.3)
        for style in RedactStyle.allCases {
            let hidden = renderer.redacted(screen, blocks: [RedactBlock(start: 0, end: 5, rect: box, style: style)])
            XCTAssertEqual(hidden.extent, screen.extent)
            let inside = CGRect(x: size.width * 0.3, y: size.height * (1 - 0.35), width: size.width * 0.4, height: size.height * 0.15)
            let outside = CGRect(x: size.width * 0.3, y: size.height * 0.1, width: size.width * 0.4, height: size.height * 0.2)
            XCTAssertGreaterThan(difference(renderer, screen, hidden, in: inside), 0.01, "\(style) left the text readable")
            XCTAssertLessThan(difference(renderer, screen, hidden, in: outside), 0.001, "\(style) spilled outside its box")
        }
    }

    func testScannerFindsTextOnScreen() throws {
        let size = CGSize(width: 1440, height: 900)
        let img = NSImage(size: size, flipped: true) { rect in
            NSColor.white.setFill()
            rect.fill()
            let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 22), .foregroundColor: NSColor.black]
            ("Signed in as jane.doe@example.com" as NSString).draw(at: NSPoint(x: 700, y: 120), withAttributes: attrs)
            ("Nothing to see in this line" as NSString).draw(at: NSPoint(x: 100, y: 600), withAttributes: attrs)
            return true
        }
        let cg = try XCTUnwrap(img.cgImage(forProposedRect: nil, context: nil, hints: nil))
        let found = SensitiveTextScanner.read(cg).found
        XCTAssertEqual(found.map(\.kind), [.email])
        let rect = try XCTUnwrap(found.first?.rect)
        XCTAssertGreaterThan(rect.minX, 0.53, "covers the address, not the whole line")
        XCTAssertLessThan(rect.maxY, 0.25)
    }

    func testTypedTextIsTheStartOfWhatItBecomes() {
        func typed(_ line: String) -> String? {
            SensitiveTextScanner.typedPrefix(of: "thisismyn07@gmail.com", in: line).map { String(line[$0]) }
        }
        XCTAssertEqual(typed("thisismyn07@gmai"), "thisismyn07@gmai")
        XCTAssertEqual(typed("Email thisismyn07@g"), "thisismyn07@g")
        XCTAssertEqual(typed("thisismyn07@Imai"), "thisismyn07@", "the caret over a letter cuts it short, not off")
        XCTAssertNil(typed("th"), "too little to tell")
        XCTAssertNil(typed("Nothing to see here"))
        XCTAssertNil(typed("athisismyn07"), "only from the start of a word")
    }

    /// An address typed a few letters a second is blurred from its first letters, not once it's whole.
    func testBlurCoversTextWhileItsTyped() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("typing-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let (bundle, empty) = try ProjectBundle.create(name: "Typing", in: dir)
        let (folder, rel) = try bundle.makeClipFolder(id: UUID())
        let address = "jane.doe@example.com", size = CGSize(width: 1440, height: 900)
        let typingStarts = 1.0, perSecond = 6.0, duration = 7.0
        func frame(_ text: String) throws -> CIImage {
            let img = NSImage(size: size, flipped: true) { rect in
                NSColor.white.setFill()
                rect.fill()
                let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 28), .foregroundColor: NSColor.black]
                ("Email" as NSString).draw(at: NSPoint(x: 400, y: 330), withAttributes: attrs)
                (text as NSString).draw(at: NSPoint(x: 400, y: 380), withAttributes: attrs)
                return true
            }
            let drawn = CIImage(cgImage: try XCTUnwrap(img.cgImage(forProposedRect: nil, context: nil, hints: nil)))
            // Drawn at the screen's backing scale.
            let k = size.width / drawn.extent.width
            return drawn.transformed(by: CGAffineTransform(scaleX: k, y: k))
        }
        var frames: [Int: CIImage] = [:]
        try await TestMovie.write(to: folder.appendingPathComponent("screen.mov"), size: size, frames: Int(duration * 10),
                                  fps: 10) { i in
            let count = min(max(Int((Double(i) / 10 - typingStarts) * perSecond), 0), address.count)
            let image = try frames[count] ?? frame(String(address.prefix(count)))
            frames[count] = image
            return image
        }

        var p = empty
        p.clips = [Clip(screenFile: "\(rel)/screen.mov", duration: duration, screenPixelSize: size, captureRect: .zero)]
        let blocks = try await SensitiveTextScanner.scan(project: p, bundle: bundle) { _ in }
        let block = try XCTUnwrap(blocks.first { $0.label == "Email" })
        let whole = typingStarts + Double(address.count) / perSecond
        XCTAssertLessThanOrEqual(block.start, typingStarts + 0.6, "blurred from the first letters, not at \(whole)s")
        XCTAssertEqual(block.end, duration, accuracy: 0.01)
        XCTAssertLessThan(block.rect.minX, 400 / size.width, "covers where typing started")
    }

    func testRedactionsOnlyShowWhileActive() {
        var p = Project(name: "R")
        p.redactions = [RedactBlock(start: 1, end: 2)]
        XCTAssertTrue(p.redactions(at: 0.5).isEmpty)
        XCTAssertEqual(p.redactions(at: 1.5).count, 1)
        XCTAssertTrue(p.redactions(at: 2).isEmpty)
    }

    private func difference(_ r: FrameRenderer, _ a: CIImage, _ b: CIImage, in rect: CGRect) -> Double {
        let diff = a.applyingFilter("CIDifferenceBlendMode", parameters: [kCIInputBackgroundImageKey: b])
        return luminance(r, diff.applyingFilter("CIAreaAverage", parameters: [kCIInputExtentKey: CIVector(cgRect: rect)]))
    }

    private func luminance(_ r: FrameRenderer, _ pixel: CIImage) -> Double {
        var px = [Float](repeating: 0, count: 4)
        r.context.render(pixel, toBitmap: &px, rowBytes: 16, bounds: CGRect(x: pixel.extent.minX, y: pixel.extent.minY, width: 1, height: 1),
                         format: .RGBAf, colorSpace: nil)
        return Double(px[0] + px[1] + px[2]) / 3
    }
}
