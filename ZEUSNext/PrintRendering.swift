import UIKit

final class BrowserPrintRenderer: UIPrintPageRenderer {
    var documentTitle = ""
    var showsHeader = true
    var showsFooter = true
    var margin: CGFloat = 24
    override var paperRect: CGRect { CGRect(x: 0, y: 0, width: 595.2, height: 841.8) }
    override var printableRect: CGRect { paperRect.insetBy(dx: margin, dy: margin) }
    override func drawHeaderForPage(at pageIndex: Int, in headerRect: CGRect) {
        guard showsHeader else { return }
        (documentTitle as NSString).draw(in: headerRect, withAttributes: [.font: UIFont.systemFont(ofSize: 10), .foregroundColor: UIColor.black])
    }
    override func drawFooterForPage(at pageIndex: Int, in footerRect: CGRect) {
        guard showsFooter else { return }
        let style = NSMutableParagraphStyle(); style.alignment = .center
        ("\(pageIndex + 1) / \(numberOfPages)" as NSString).draw(in: footerRect, withAttributes: [.font: UIFont.systemFont(ofSize: 10), .foregroundColor: UIColor.black, .paragraphStyle: style])
    }
}
