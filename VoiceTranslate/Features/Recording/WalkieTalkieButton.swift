import SwiftUI

struct WalkieTalkieButton: View {
    let isRecording: Bool
    let isProcessing: Bool
    let onStartRecording: () -> Void
    let onStopRecording: () -> Void

    @State private var isPressing = false

    var body: some View {
        Circle()
            .fill(buttonColor)
            .frame(width: 56, height: 56)
            .overlay {
                if isProcessing {
                    SpinnerView()
                } else {
                    Image(systemName: isRecording ? "mic.fill" : "mic")
                        .font(.system(size: 24))
                        .foregroundStyle(.white)
                }
            }
            .scaleEffect(isPressing ? 1.15 : 1.0)
            .animation(.easeInOut(duration: 0.15), value: isPressing)
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in
                        guard !isPressing, !isProcessing else { return }
                        isPressing = true
                        onStartRecording()
                    }
                    .onEnded { _ in
                        guard isPressing else { return }
                        isPressing = false
                        onStopRecording()
                    }
            )
            .accessibilityLabel("Hold to speak")
    }

    private var buttonColor: Color {
        if isProcessing { return .gray }
        if isRecording { return .red }
        return .blue
    }
}

private struct SpinnerView: View {
    @State private var rotation = 0.0

    var body: some View {
        Circle()
            .trim(from: 0, to: 0.7)
            .stroke(.white, style: StrokeStyle(lineWidth: 3, lineCap: .round))
            .frame(width: 24, height: 24)
            .rotationEffect(.degrees(rotation))
            .onAppear {
                withAnimation(.linear(duration: 0.8).repeatForever(autoreverses: false)) {
                    rotation = 360
                }
            }
    }
}
