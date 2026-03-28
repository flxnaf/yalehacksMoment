import SwiftUI

/// Draws detected-person bounding boxes and the scene classification label
/// on top of the camera/depth feed so the user can verify Vision is working.
struct VisionOverlay: View {
    let persons: [PersonDetection]
    let sceneLabel: String?
    let frameSize: CGSize

    var body: some View {
        ZStack(alignment: .topLeading) {
            ForEach(Array(persons.enumerated()), id: \.offset) { _, person in
                personBox(person)
            }

            if let label = sceneLabel {
                Text(label)
                    .font(.caption2.bold())
                    .foregroundColor(.white)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(Color.purple.opacity(0.75)))
                    .padding(.leading, 12)
                    .padding(.top, 60)
            }
        }
        .frame(width: frameSize.width, height: frameSize.height)
    }

    /// Converts a Vision bounding box (normalised, origin bottom-left) into
    /// screen coordinates and draws a labelled rectangle.
    @ViewBuilder
    private func personBox(_ person: PersonDetection) -> some View {
        let box = person.boundingBox
        let w = frameSize.width
        let h = frameSize.height

        let x = box.minX * w
        let y = (1 - box.maxY) * h
        let bw = box.width * w
        let bh = box.height * h

        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 4)
                .stroke(Color.cyan, lineWidth: 2)
                .frame(width: bw, height: bh)

            HStack(spacing: 4) {
                Circle()
                    .fill(Color.cyan)
                    .frame(width: 6, height: 6)
                Text(depthLabel(person))
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundColor(.white)
            }
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(RoundedRectangle(cornerRadius: 4).fill(Color.black.opacity(0.6)))
            .offset(y: -18)
        }
        .position(x: x + bw / 2, y: y + bh / 2)
    }

    private func depthLabel(_ p: PersonDetection) -> String {
        if let d = p.estimatedDepth {
            let pct = Int(d * 100)
            return "Person \(pct)%"
        }
        return "Person"
    }
}
