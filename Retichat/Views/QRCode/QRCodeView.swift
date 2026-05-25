//
//  QRCodeView.swift
//  Retichat
//
//  Display own destination hash as QR code, or scan another user's QR code.
//  Mirrors Android QrCodeScreen.kt.
//  Uses CoreImage for QR generation and AVFoundation camera for scanning.
//

import SwiftUI
import CoreImage.CIFilterBuiltins
import AVFoundation

// MARK: - Mode

enum QRMode {
    case display
    case scan
}

// MARK: - QRCodeView

struct QRCodeView: View {
    @EnvironmentObject var repository: ChatRepository
    @Environment(\.dismiss) private var dismiss

    var mode: QRMode = .display
    var onScanned: ((SharedPeerIdentity) -> Void)?

    @State private var currentTab: QRMode = .display

    var body: some View {
        NavigationStack {
            ZStack {
                Color.retichatBackground.ignoresSafeArea()

                VStack(spacing: 0) {
                    // Tab selector
                    Picker("Mode", selection: $currentTab) {
                        Text("My QR Code").tag(QRMode.display)
                        Text("Scan").tag(QRMode.scan)
                    }
                    .pickerStyle(.segmented)
                    .padding()

                    Spacer()

                    switch currentTab {
                    case .display:
                        displayView
                    case .scan:
                        scanView
                    }

                    Spacer()
                }
            }
            .navigationTitle("QR Code")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
            .onAppear {
                currentTab = mode
            }
        }
    }

    // MARK: Display own QR

    private var displayView: some View {
        VStack(spacing: 24) {
            let hash = repository.ownHashHex
            if hash.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.largeTitle)
                        .foregroundColor(.retichatError)
                    Text("Identity not loaded yet.\nStart the service first.")
                        .multilineTextAlignment(.center)
                        .foregroundColor(.retichatOnSurfaceVariant)
                }
            } else {
                let publicKey = repository.lxmfClient.flatMap {
                    RetichatBridge.shared.identityPublicKey(handle: $0.identityHandle)
                }
                let shareUri = IdentityShareFormat.encode(
                    destinationHashHex: hash,
                    publicKey: publicKey
                ) ?? "lxmf://\(hash)"

                if let qrImage = generateQRCode(from: shareUri) {
                    Image(uiImage: qrImage)
                        .interpolation(.none)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 260, height: 260)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                        .glassBackground(cornerRadius: 16)
                }

                Text(hash)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundColor(.retichatOnSurfaceVariant)
                    .textSelection(.enabled)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)

                Button {
                    UIPasteboard.general.string = hash
                } label: {
                    Label("Copy Hash", systemImage: "doc.on.doc")
                }
                .buttonStyle(.bordered)
                .tint(.retichatPrimary)

                Button {
                    UIPasteboard.general.string = shareUri
                } label: {
                    Label("Copy Contact URI", systemImage: "link")
                }
                .buttonStyle(.bordered)
                .tint(.retichatPrimary)
            }
        }
        .padding()
    }

    // MARK: Scan QR

    private var scanView: some View {
        QRScannerView { scannedString in
            if let peer = IdentityShareFormat.parse(scannedString) {
                handleScannedPeer(peer)
                dismiss()
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .padding()
        .overlay {
            Text("Point camera at a Retichat or Columba QR code")
                .font(.caption)
                .foregroundColor(.retichatOnSurfaceVariant)
                .frame(maxHeight: .infinity, alignment: .bottom)
                .padding(.bottom, 40)
        }
    }

    private func handleScannedPeer(_ peer: SharedPeerIdentity) {
        if let onScanned {
            onScanned(peer)
            return
        }

        let chatId = repository.createDirectChat(
            destHash: peer.destinationHashHex,
            publicKey: peer.publicKey
        )
        NotificationCenter.default.post(
            name: .openChatFromNotification,
            object: chatId
        )
    }

    // MARK: QR Generation

    private func generateQRCode(from string: String) -> UIImage? {
        let context = CIContext()
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(string.utf8)
        filter.correctionLevel = "M"

        guard let outputImage = filter.outputImage else { return nil }

        // Scale up for crisp rendering
        let scale = 260.0 / outputImage.extent.width
        let scaled = outputImage.transformed(by: CGAffineTransform(scaleX: scale, y: scale))

        // White QR on dark background → invert for dark theme readability
        guard let cgImage = context.createCGImage(scaled, from: scaled.extent) else { return nil }
        return UIImage(cgImage: cgImage)
    }
}

// MARK: - QR Scanner (AVFoundation)

struct QRScannerView: UIViewControllerRepresentable {
    var onFound: (String) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onFound: onFound)
    }

    func makeUIViewController(context: Context) -> ScannerViewController {
        let vc = ScannerViewController()
        vc.delegate = context.coordinator
        return vc
    }

    func updateUIViewController(_ uiViewController: ScannerViewController, context: Context) {}

    class Coordinator: NSObject, AVCaptureMetadataOutputObjectsDelegate {
        var onFound: (String) -> Void
        private var hasReported = false

        init(onFound: @escaping (String) -> Void) {
            self.onFound = onFound
        }

        func metadataOutput(
            _ output: AVCaptureMetadataOutput,
            didOutput metadataObjects: [AVMetadataObject],
            from connection: AVCaptureConnection
        ) {
            guard !hasReported,
                  let object = metadataObjects.first as? AVMetadataMachineReadableCodeObject,
                  object.type == .qr,
                  let value = object.stringValue else { return }
            hasReported = true
            DispatchQueue.main.async { [weak self] in
                self?.onFound(value)
            }
        }
    }

    class ScannerViewController: UIViewController {
        weak var delegate: Coordinator?
        private let session = AVCaptureSession()

        override func viewDidLoad() {
            super.viewDidLoad()
            view.backgroundColor = .black

            guard let device = AVCaptureDevice.default(for: .video),
                  let input = try? AVCaptureDeviceInput(device: device) else {
                showFallback("Camera not available")
                return
            }

            if session.canAddInput(input) { session.addInput(input) }

            let output = AVCaptureMetadataOutput()
            if session.canAddOutput(output) {
                session.addOutput(output)
                output.setMetadataObjectsDelegate(delegate, queue: .main)
                output.metadataObjectTypes = [.qr]
            }

            let preview = AVCaptureVideoPreviewLayer(session: session)
            preview.frame = view.bounds
            preview.videoGravity = .resizeAspectFill
            view.layer.addSublayer(preview)

            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                self?.session.startRunning()
            }
        }

        override func viewDidLayoutSubviews() {
            super.viewDidLayoutSubviews()
            if let preview = view.layer.sublayers?.first(where: { $0 is AVCaptureVideoPreviewLayer }) {
                preview.frame = view.bounds
            }
        }

        override func viewWillDisappear(_ animated: Bool) {
            super.viewWillDisappear(animated)
            session.stopRunning()
        }

        private func showFallback(_ message: String) {
            let label = UILabel()
            label.text = message
            label.textColor = .white
            label.textAlignment = .center
            label.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(label)
            NSLayoutConstraint.activate([
                label.centerXAnchor.constraint(equalTo: view.centerXAnchor),
                label.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            ])
        }
    }
}
