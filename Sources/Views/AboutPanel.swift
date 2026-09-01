// ABOUTME: Credits shown in the standard macOS About panel.
// ABOUTME: Attribution lives here so the App menu and Help pane say the same thing.

import AppKit

enum AboutPanel {
    static func show() {
        NSApp.orderFrontStandardAboutPanel(options: [.credits: credits])
    }

    /// The About panel renders whatever attributed string it is handed, so the
    /// colour has to be a dynamic system colour or the text disappears in dark mode.
    private static var credits: NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.paragraphSpacing = 6

        let text = """
        Forked by Tad Thorley

        based on Factory Floor by David Poblador i Garcia
        and additional work by Andrés González
        """

        let credits = NSMutableAttributedString(
            string: text,
            attributes: [
                .font: NSFont.systemFont(ofSize: 11),
                .foregroundColor: NSColor.secondaryLabelColor,
                .paragraphStyle: paragraph,
            ]
        )

        let links: [(String, URL)] = [
            ("Tad Thorley", AppConstants.repositoryURL),
            ("Factory Floor", AppConstants.upstreamURL),
            ("David Poblador i Garcia", AppConstants.upstreamAuthorURL),
            ("Andrés González", AppConstants.upstreamEnhancerURL),
        ]
        for (name, url) in links {
            let range = (credits.string as NSString).range(of: name)
            guard range.location != NSNotFound else { continue }
            credits.addAttribute(.link, value: url, range: range)
        }

        return credits
    }
}
