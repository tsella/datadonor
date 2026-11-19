import SwiftUI
import AVFoundation

struct QRScannerView: View {
    @Environment(\.dismiss) private var dismiss
    var onResult: (String) -> Void

    var body: some View {
        ZStack(alignment: .topTrailing) {
            QRScannerControllerRepresentable(onResult: onResult)
                .ignoresSafeArea()

            Button(action: { dismiss() }) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 30))
                    .foregroundColor(.white.opacity(0.85))
                    .padding(20)
            }
        }
    }
}

private struct QRScannerControllerRepresentable: UIViewControllerRepresentable {
    var onResult: (String) -> Void
    
    func makeUIViewController(context: Context) -> ScannerViewController {
        let viewController = ScannerViewController()
        viewController.onResult = onResult
        return viewController
    }
    
    func updateUIViewController(_ uiViewController: ScannerViewController, context: Context) {
    }
}

class ScannerViewController: UIViewController, AVCaptureMetadataOutputObjectsDelegate {
    enum ScannerState: Equatable {
        case checkingPermission
        case ready
        case running
        case scanned
        case unavailable
    }

    var captureSession: AVCaptureSession?
    var previewLayer: AVCaptureVideoPreviewLayer?
    var onResult: ((String) -> Void)?
    private(set) var scannerState: ScannerState = .checkingPermission
    private var isViewVisible = false
    /// Dedicated serial queue for all `AVCaptureSession` start/stop transitions so rapid
    /// appearance/disappearance or scan teardown never interleaves concurrently.
    private let sessionQueue = DispatchQueue(label: "la.tsel.datadonor.qrscanner")
    
    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = UIColor.black
        checkPermissionAndConfigure()
    }

    private func checkPermissionAndConfigure() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            configureSession()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                DispatchQueue.main.async {
                    guard let self else { return }
                    if granted {
                        self.configureSession()
                    } else {
                        self.scannerState = .unavailable
                        self.showMessage("Camera access is required to scan your API Key QR code. Enable camera access in Settings.")
                    }
                }
            }
        case .denied, .restricted:
            scannerState = .unavailable
            showMessage("Camera access is denied. Enable camera access for DataDonor in iOS Settings.")
        @unknown default:
            scannerState = .unavailable
            showMessage("Camera is unavailable.")
        }
    }

    private func configureSession() {
        guard captureSession == nil, scannerState != .scanned else { return }

        let session = AVCaptureSession()

        guard let videoCaptureDevice = AVCaptureDevice.default(for: .video),
              let videoInput = try? AVCaptureDeviceInput(device: videoCaptureDevice),
              session.canAddInput(videoInput) else {
            scannerState = .unavailable
            showMessage("No camera available on this device.")
            return
        }
        session.addInput(videoInput)

        let metadataOutput = AVCaptureMetadataOutput()
        guard session.canAddOutput(metadataOutput) else {
            scannerState = .unavailable
            showMessage("Could not configure QR code scanner.")
            return
        }
        session.addOutput(metadataOutput)
        metadataOutput.setMetadataObjectsDelegate(self, queue: DispatchQueue.main)
        metadataOutput.metadataObjectTypes = [.qr]

        let layer = AVCaptureVideoPreviewLayer(session: session)
        layer.frame = view.layer.bounds
        layer.videoGravity = .resizeAspectFill
        view.layer.insertSublayer(layer, at: 0)

        captureSession = session
        previewLayer = layer
        scannerState = .ready

        if isViewVisible {
            startSession()
        }
    }

    private func showMessage(_ text: String) {
        let label = UILabel()
        label.text = text
        label.textColor = .white
        label.textAlignment = .center
        label.numberOfLines = 0
        label.font = .preferredFont(forTextStyle: .body)
        label.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 32),
            label.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -32),
            label.centerYAnchor.constraint(equalTo: view.centerYAnchor)
        ])
    }

    /// `startRunning()`/`stopRunning()` block, so all session lifecycle calls are serialized
    /// on `sessionQueue` rather than a concurrent global queue.
    private func startSession() {
        guard scannerState == .ready, let session = captureSession else { return }
        scannerState = .running
        sessionQueue.async {
            if !session.isRunning {
                session.startRunning()
            }
        }
    }

    private func stopSession(nextState: ScannerState) {
        if scannerState == .running || scannerState == .ready {
            scannerState = nextState
        }
        guard let session = captureSession else { return }
        sessionQueue.async {
            if session.isRunning {
                session.stopRunning()
            }
        }
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        isViewVisible = true
        startSession()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        isViewVisible = false
        if scannerState != .scanned {
            stopSession(nextState: .ready)
        }
    }
    
    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        previewLayer?.frame = view.bounds
    }

    /// Processes a decoded QR payload, guaranteeing single emission across rapid frames.
    @discardableResult
    internal func handleScannedCode(_ code: String?) -> Bool {
        guard scannerState != .scanned,
              let value = code,
              !value.isEmpty else {
            return false
        }
        stopSession(nextState: .scanned)
        scannerState = .scanned
        AudioServicesPlaySystemSound(SystemSoundID(kSystemSoundID_Vibrate))
        onResult?(value)
        return true
    }
    
    func metadataOutput(_ output: AVCaptureMetadataOutput, didOutput metadataObjects: [AVMetadataObject], from connection: AVCaptureConnection) {
        // Only tear down the session once we have a usable value. Stopping first meant an
        // unreadable code left the preview frozen with no way to retry.
        let readableObject = metadataObjects.first as? AVMetadataMachineReadableCodeObject
        _ = handleScannedCode(readableObject?.stringValue)
    }
}
