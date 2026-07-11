import SwiftUI
import UniformTypeIdentifiers

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

