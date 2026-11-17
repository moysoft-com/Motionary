import SwiftUI
import UIKit

struct DeleteMenuButton: View {
    let action: () -> Void

    private static let icon = UIImage(systemName: "trash")?
        .withTintColor(.systemRed, renderingMode: .alwaysOriginal)

    var body: some View {
        Button(role: .destructive, action: action) {
            Label {
                Text("Delete")
            } icon: {
                if let icon = Self.icon {
                    Image(uiImage: icon)
                        .renderingMode(.original)
                }
            }
        }
    }
}
