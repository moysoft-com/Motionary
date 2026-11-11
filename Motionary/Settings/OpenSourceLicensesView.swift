import SwiftUI

struct OpenSourceLicensesView: View {
    private var apacheLicense: String {
        guard let url = Bundle.main.url(forResource: "DepthAnything-Apache-2.0", withExtension: "txt"),
              let text = try? String(contentsOf: url, encoding: .utf8) else {
            return "License text unavailable. See https://www.apache.org/licenses/LICENSE-2.0"
        }
        return text
    }

    private var shimmerLicense: String {
        guard let url = Bundle.main.url(forResource: "SwiftUI-Shimmer-MIT", withExtension: "txt"),
              let text = try? String(contentsOf: url, encoding: .utf8) else {
            return "License text unavailable. See https://github.com/markiv/SwiftUI-Shimmer/blob/1.5.1/LICENSE"
        }
        return text
    }

    var body: some View {
        List {
            Section("SwiftUI-Shimmer") {
                Text("SwiftUI-Shimmer by Vikram Kriplaney. Licensed under the MIT License.")
                Link("Source", destination: URL(string: "https://github.com/markiv/SwiftUI-Shimmer")!)
                NavigationLink("MIT License") {
                    ScrollView {
                        Text(shimmerLicense).font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding()
                    }
                    .navigationTitle("MIT License")
                }
            }
            Section("Depth Anything V2 Small") {
                Text("Depth Anything V2 by Lihe Yang and contributors. This app includes the Core ML conversion distributed by Apple. Licensed under the Apache License, Version 2.0.")
                Link("Source and model information", destination: URL(string: "https://github.com/DepthAnything/Depth-Anything-V2")!)
                NavigationLink("Apache License 2.0") {
                    ScrollView {
                        Text(apacheLicense).font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding()
                    }
                    .navigationTitle("Apache License 2.0")
                }
            }
        }
        .navigationTitle("Open Source Licenses")
    }
}
