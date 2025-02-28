import SwiftUI
import PhotosUI

struct MediaImportView: View {
    @Environment(\.dismiss) var dismiss
    @Binding var importedMedia: [URL]
    @State private var pickedItems: [PhotosPickerItem] = []

    var body: some View {
        NavigationView {
            VStack(spacing: 20) {
                PhotosPicker(
                    selection: $pickedItems,
                    maxSelectionCount: 10,
                    matching: .any(of: [.images, .videos])
                ) {
                    Label("Medien auswählen", systemImage: "photo.on.rectangle")
                        .padding()
                        .background(Color.blue)
                        .cornerRadius(8)
                        .foregroundColor(.white)
                }
                .onChange(of: pickedItems) { newItems in
                    Task {
                        for item in newItems {
                            if let url = try? await item.loadTransferable(type: URL.self) {
                                importedMedia.append(url)
                            }
                        }
                    }
                }
                Spacer()
            }
            .padding()
            .navigationTitle("Medien importieren")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Fertig") { dismiss() }
                }
            }
        }
    }
}