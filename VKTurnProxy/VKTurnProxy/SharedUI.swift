import SwiftUI
import UniformTypeIdentifiers
import AVFoundation

struct IdentifiableURL: Identifiable {
    let url: URL
    var id: String { url.absoluteString }
}

// MARK: - Document Picker (Import file)

/// UIDocumentPickerViewController wrapper for picking a JSON backup file.
/// The picker hands back a security-scoped URL that the caller must
/// access via startAccessingSecurityScopedResource — BackupManager.importFromFileURL
/// handles that internally so this wrapper just forwards the URL.
///
/// contentTypes is `[UTType]` rather than `[String]` so callers pass the
/// type-safe `UTType.json` (or similar) directly — earlier code took a
/// `[String]` of UTI identifiers and converted via the failable
/// `UTType(_:)` init. When that init returned nil for any reason, the
/// resulting empty filter let the picker show every file as selectable
/// AND failed to highlight the genuine JSON ones — observed empirically
/// during the schema migration test where vkturnproxy-backup-*.json sat
/// un-highlighted in Files.app's Downloads view and had to be located by
/// search instead of by browsing.
struct DocumentPicker: UIViewControllerRepresentable {
    let contentTypes: [UTType]
    let onPicked: (URL) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onPicked: onPicked)
    }

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(
            forOpeningContentTypes: contentTypes
        )
        picker.delegate = context.coordinator
        picker.allowsMultipleSelection = false
        return picker
    }

    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {}

    class Coordinator: NSObject, UIDocumentPickerDelegate {
        let onPicked: (URL) -> Void
        init(onPicked: @escaping (URL) -> Void) {
            self.onPicked = onPicked
        }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            guard let url = urls.first else { return }
            onPicked(url)
        }
    }
}

// MARK: - QR scanner

struct QRCodeScannerView: UIViewControllerRepresentable {
    let onResult: (String) -> Void
    let onError: (String) -> Void

    func makeUIViewController(context: Context) -> QRScannerViewController {
        QRScannerViewController(onResult: onResult, onError: onError)
    }

    func updateUIViewController(_ uiViewController: QRScannerViewController, context: Context) {}
}

final class QRScannerViewController: UIViewController, AVCaptureMetadataOutputObjectsDelegate {
    private let session = AVCaptureSession()
    private var previewLayer: AVCaptureVideoPreviewLayer?
    private let onResult: (String) -> Void
    private let onError: (String) -> Void
    private var completed = false

    init(onResult: @escaping (String) -> Void, onError: @escaping (String) -> Void) {
        self.onResult = onResult
        self.onError = onError
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            configureCapture()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                DispatchQueue.main.async {
                    guard let self else { return }
                    granted ? self.configureCapture() : self.fail("Доступ к камере запрещён.")
                }
            }
        default:
            fail("Разрешите доступ к камере в системных настройках Orbit.")
        }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        previewLayer?.frame = view.bounds
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        session.stopRunning()
    }

    private func configureCapture() {
        guard let camera = AVCaptureDevice.default(for: .video) else {
            fail("Камера на устройстве недоступна.")
            return
        }
        do {
            let input = try AVCaptureDeviceInput(device: camera)
            guard session.canAddInput(input) else { throw ScannerError.configuration }
            session.addInput(input)
            let output = AVCaptureMetadataOutput()
            guard session.canAddOutput(output) else { throw ScannerError.configuration }
            session.addOutput(output)
            output.setMetadataObjectsDelegate(self, queue: .main)
            output.metadataObjectTypes = [.qr]

            let preview = AVCaptureVideoPreviewLayer(session: session)
            preview.videoGravity = .resizeAspectFill
            preview.frame = view.bounds
            view.layer.insertSublayer(preview, at: 0)
            previewLayer = preview
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in self?.session.startRunning() }
        } catch {
            fail("Не удалось запустить сканер QR-кодов.")
        }
    }

    func metadataOutput(_ output: AVCaptureMetadataOutput,
                        didOutput metadataObjects: [AVMetadataObject],
                        from connection: AVCaptureConnection) {
        guard !completed,
              let object = metadataObjects.first as? AVMetadataMachineReadableCodeObject,
              let value = object.stringValue else { return }
        completed = true
        session.stopRunning()
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        onResult(value)
    }

    private func fail(_ message: String) {
        guard !completed else { return }
        completed = true
        onError(message)
    }

    private enum ScannerError: Error { case configuration }
}
