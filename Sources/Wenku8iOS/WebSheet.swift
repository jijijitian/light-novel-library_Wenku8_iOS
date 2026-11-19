import SwiftUI
import SafariServices
import Wenku8Core

struct WebSheet: UIViewControllerRepresentable {
    var url: URL?

    func makeUIViewController(context: Context) -> SFSafariViewController {
        let configuration = SFSafariViewController.Configuration()
        configuration.entersReaderIfAvailable = false
        let controller = SFSafariViewController(
            url: url ?? SiteDomain.current.webURL("/"),
            configuration: configuration
        )
        controller.preferredControlTintColor = UIColor(AppTheme.accent)
        return controller
    }

    func updateUIViewController(_ uiViewController: SFSafariViewController, context: Context) {}
}

struct WebSheetItem: Identifiable {
    var id = UUID()
    var url: URL?
}
