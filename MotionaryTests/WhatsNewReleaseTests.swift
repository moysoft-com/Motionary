// Release selection tests for the What's New catalog.

import Foundation
import Testing

@testable import Motionary

struct WhatsNewReleaseTests {
    private let catalog = Data(
        """
        {
          "1.0": {
            "title": "Motionary 1.0",
            "features": ["Speed ramps"],
            "buttonTitle": "Start Editing"
          },
          "1.1": {
            "title": "Motionary 1.1",
            "subtitle": "Editing update",
            "features": [],
            "sections": [{"title": "Export", "body": "New **Export** options."}],
            "buttonTitle": "Continue"
          }
        }
        """.utf8
    )

    @Test func selectsOnlyTheInstalledRelease() throws {
        let initial = try #require(WhatsNewRelease.release(for: "1.0", in: catalog))
        let update = try #require(WhatsNewRelease.release(for: "1.1", in: catalog))

        #expect(initial.id == "1.0")
        #expect(initial.features == ["Speed ramps"])
        #expect(initial.sections.isEmpty)
        #expect(update.title == "Motionary 1.1")
        #expect(update.sections.first?.body == "New **Export** options.")
        #expect(WhatsNewRelease.release(for: "1.0.1", in: catalog) == nil)
    }

    @Test func skipsMalformedOrEmptyContent() {
        let malformed = Data("{".utf8)
        let empty = Data(#"{"1.0": {"title": "Motionary 1.0", "features": [], "buttonTitle": "Start Editing"}}"#.utf8)

        #expect(WhatsNewRelease.release(for: "1.0", in: malformed) == nil)
        #expect(WhatsNewRelease.release(for: "1.0", in: empty) == nil)
    }
}
