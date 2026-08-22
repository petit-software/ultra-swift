import Testing
import Foundation
import SwiftUI
@testable import UltraDesign

/// `Appearance` writes to the standard defaults, so each test clears its own keys rather
/// than leaving the developer's real settings changed by running the suite.
private func withCleanDefaults(_ body: () -> Void) {
    Appearance.reset()
    defer { Appearance.reset() }
    body()
}

@Suite("Appearance settings", .serialized)
struct AppearanceTests {

    @Test("an untouched install reads today's shipped constants")
    func defaultsAreTheShippedConstants() {
        withCleanDefaults {
            #expect(Appearance.value(.windowRadius) == 24)
            #expect(Appearance.value(.paneRadius) == 18)
            #expect(Appearance.value(.gutter) == 12)
            #expect(Appearance.value(.headerBlurRadius) == 14)
            #expect(abs(Appearance.value(.headerTintOpacity) - 0.28) < 0.0001)
            #expect(!Appearance.isModified)
        }
    }

    @Test("every key has a default, so nothing can silently read zero")
    func everyKeyHasADefault() {
        for key in Appearance.Key.allCases {
            #expect(Appearance.fallbacks[key] != nil, "\(key.rawValue) has no default")
        }
    }

    @Test("every default sits inside its own slider range")
    func defaultsAreInRange() {
        for key in Appearance.Key.allCases {
            let knob = Appearance.knob(key)
            let fallback = Appearance.fallbacks[key]!
            #expect(knob.range.contains(fallback),
                    "\(key.rawValue) default \(fallback) is outside \(knob.range)")
        }
    }

    @Test("a value survives the round trip and marks the settings as customised")
    func setAndRead() {
        withCleanDefaults {
            Appearance.set(.paneRadius, 6)
            #expect(Appearance.value(.paneRadius) == 6)
            #expect(Appearance.isModified)
            Appearance.reset()
            #expect(Appearance.value(.paneRadius) == 18)
            #expect(!Appearance.isModified)
        }
    }

    /// The one that actually matters: a window corner below the system's 15.5pt mask is what
    /// draws two concentric arcs. The slider cannot reach it and neither can a stored value.
    @Test("window radius can never go below the system mask")
    func windowRadiusFloor() {
        withCleanDefaults {
            #expect(Appearance.knob(.windowRadius).range.lowerBound
                    == Token.Space.systemWindowRadius)

            Appearance.set(.windowRadius, 4)
            #expect(Appearance.value(.windowRadius) == Token.Space.systemWindowRadius)

            // A value written straight into defaults — an older build, a synced domain, or
            // `defaults write` — has never passed through the slider, so the read clamps too.
            UserDefaults.standard.set(2.0, forKey: "appearance.windowRadius")
            #expect(Appearance.value(.windowRadius) == Token.Space.systemWindowRadius)
        }
    }

    @Test("out-of-range values are clamped on the way in and on the way out",
          arguments: Appearance.Key.allCases)
    func clampingBothWays(key: Appearance.Key) {
        withCleanDefaults {
            let range = Appearance.knob(key).range
            Appearance.set(key, range.upperBound + 1000)
            #expect(Appearance.value(key) == range.upperBound)

            UserDefaults.standard.set(-9999.0, forKey: "appearance." + key.rawValue)
            #expect(Appearance.value(key) == range.lowerBound)
        }
    }

    @Test("the tokens read through the store")
    func tokensFollowSettings() {
        withCleanDefaults {
            Appearance.set(.paneRadius, 4)
            #expect(Token.Space.paneRadius == 4)
            Appearance.set(.gutter, 20)
            #expect(Token.Space.gutter == 20)
            Appearance.set(.paneShadowOpacity, 0.5)
            #expect(abs(Token.Space.paneShadowOpacity - 0.5) < 0.0001)
        }
    }

    @Test("a change posts exactly one notification, and a no-op posts none")
    func notifies() {
        withCleanDefaults {
            var count = 0
            let token = NotificationCenter.default.addObserver(
                forName: Appearance.didChange, object: nil, queue: nil) { _ in count += 1 }
            defer { NotificationCenter.default.removeObserver(token) }

            Appearance.set(.gutter, 20)
            #expect(count == 1)
            // Setting the same value again must not churn the whole window.
            Appearance.set(.gutter, 20)
            #expect(count == 1)
        }
    }

    @Test("percentages and point values format the way each one reads")
    func formatting() {
        #expect(Appearance.knob(.headerTintOpacity).format(0.28) == "28%")
        #expect(Appearance.knob(.paneRadius).format(18) == "18 pt")
        #expect(Appearance.knob(.windowRadius).format(15.5) == "15.5 pt")
    }
}
