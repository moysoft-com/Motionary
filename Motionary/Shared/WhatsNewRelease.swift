// Selects bundled release notes for the installed marketing version.

import Foundation

struct WhatsNewRelease: Identifiable {
    struct Section: Decodable {
        let title: String
        let body: String

        fileprivate var hasContent: Bool {
            !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    let version: String
    let title: String
    let subtitle: String?
    let features: [String]
    let sections: [Section]
    let buttonTitle: String

    var id: String { version }

    static func current(in bundle: Bundle = .main) -> Self? {
        guard
            let version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
            let url = bundle.url(forResource: "WhatsNew", withExtension: "json"),
            let data = try? Data(contentsOf: url)
        else { return nil }
        return release(for: version, in: data)
    }

    static func release(for version: String, in catalog: Data) -> Self? {
        guard
            !version.isEmpty,
            let releases = try? JSONDecoder().decode([String: Entry].self, from: catalog),
            let entry = releases[version],
            entry.hasContent
        else { return nil }
        return Self(
            version: version,
            title: entry.title,
            subtitle: entry.subtitle,
            features: entry.features,
            sections: entry.sections ?? [],
            buttonTitle: entry.buttonTitle
        )
    }

    private struct Entry: Decodable {
        let title: String
        let subtitle: String?
        let features: [String]
        let sections: [Section]?
        let buttonTitle: String

        var hasContent: Bool {
            let labels = [title, buttonTitle] + features + (subtitle.map { [$0] } ?? [])
            return labels.allSatisfy { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
                && (sections ?? []).allSatisfy(\.hasContent)
                && (!features.isEmpty || !(sections ?? []).isEmpty)
        }
    }
}
