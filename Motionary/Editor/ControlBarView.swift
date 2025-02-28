import SwiftUI

struct ControlBarView: View {
    let isPlaying: Bool
    let onPlayPause: () -> Void
    let onUndo: () -> Void
    let onRedo: () -> Void
    let onDelete: () -> Void
    let canUndo: Bool
    let canRedo: Bool
    let hasSelection: Bool
    
    var body: some View {
        HStack {
            Button { onUndo() } label: {
                Image(systemName: "arrow.uturn.backward")
            }
            .disabled(!canUndo)
            .opacity(canUndo ? 1 : 0.5)
            
            Button { onRedo() } label: {
                Image(systemName: "arrow.uturn.forward")
            }
            .disabled(!canRedo)
            .opacity(canRedo ? 1 : 0.5)
            
            Spacer()
            
            Button { onPlayPause() } label: {
                Image(systemName: isPlaying ? "pause.fill" : "play.fill")
            }
            
            Spacer()
            
            if hasSelection {
                Button { onDelete() } label: {
                    Image(systemName: "trash.fill")
                        .foregroundColor(.red)
                }
            }
        }
        .padding()
    }
}