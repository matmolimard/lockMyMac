import AVFoundation
import SwiftUI

/// Aperçu en direct, en miroir. Affichage seul : rien n'est enregistré.
struct CameraPreview: NSViewRepresentable {
    let session: AVCaptureSession

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        let layer = AVCaptureVideoPreviewLayer(session: session)
        layer.videoGravity = .resizeAspect
        layer.backgroundColor = NSColor.black.cgColor
        view.layer = layer
        view.wantsLayer = true
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        // La connexion n'existe qu'une fois la caméra branchée : on règle le miroir dès qu'elle apparaît.
        guard let connection = (view.layer as? AVCaptureVideoPreviewLayer)?.connection,
              connection.isVideoMirroringSupported else { return }
        if connection.automaticallyAdjustsVideoMirroring { connection.automaticallyAdjustsVideoMirroring = false }
        if !connection.isVideoMirrored { connection.isVideoMirrored = true }
    }
}

/// Aperçu + cadres autour des visages (verts : propriétaire, rouges : inconnus).
struct PreviewWithFaces: View {
    @ObservedObject var model: AppModel
    var showFaces = true

    var body: some View {
        CameraPreview(session: model.camera.session)
            .aspectRatio(model.videoAspect, contentMode: .fit)
            .overlay {
                if showFaces {
                    GeometryReader { geo in
                        ForEach(model.liveFaces) { face in
                            // Vision : origine en bas à gauche ; l'aperçu est en miroir.
                            let w = face.box.width * geo.size.width, h = face.box.height * geo.size.height
                            let x = (1 - face.box.maxX) * geo.size.width, y = (1 - face.box.maxY) * geo.size.height
                            let color: Color = face.isOwner ? .green : .red
                            RoundedRectangle(cornerRadius: 6)
                                .stroke(color, lineWidth: 2.5)
                                .frame(width: w, height: h)
                                .overlay(alignment: .top) {
                                    Text(label(face))
                                        .font(.caption.bold().monospacedDigit())
                                        .padding(.horizontal, 5).padding(.vertical, 2)
                                        .background(color, in: Capsule())
                                        .foregroundStyle(.black)
                                        .fixedSize()
                                        .offset(y: -22)
                                }
                                .offset(x: x, y: y)
                        }
                    }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private func label(_ face: LiveFace) -> String {
        guard let s = face.similarity else { return "trop loin" }
        return (face.isOwner ? "moi " : "inconnu ") + String(format: "%.2f", s)
    }
}
