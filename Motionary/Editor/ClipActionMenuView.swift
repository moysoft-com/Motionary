import SwiftUI

struct ClipActionMenuView: View {
    var onDelete: () -> Void
    
    var body: some View {
        HStack {
            Spacer()
            Button {
                onDelete()
            } label: {
                Image(systemName: "trash")
                    .font(.title)
                    .foregroundColor(.white)
            }
            Spacer()
        }
        .padding()
        .background(Color.gray.opacity(0.8))
    }
}
