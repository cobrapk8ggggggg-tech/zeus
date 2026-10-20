import UIKit

@MainActor enum BrowserPresentation {
    private static var alert: UIAlertController?
    private static var reply: ((String?) -> Void)?
    private static var generation = UUID()
    static func present(_ dialog: WebDialog, attempt: Int = 0, epoch: UUID? = nil) {
        let validEpoch = epoch ?? generation
        guard validEpoch == generation else { dialog.complete(nil); return }
        guard alert == nil else { dialog.complete(nil); return }
        guard let root = topController(), !root.isBeingPresented, !root.isBeingDismissed else {
            if attempt < 8 { DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { present(dialog, attempt: attempt + 1, epoch: validEpoch) } } else { dialog.complete(nil) }
            return
        }
        guard !(root is UIAlertController) else { dialog.complete(nil); return }
        let controller = UIAlertController(title: "ZEUS", message: dialog.text, preferredStyle: .alert)
        controller.overrideUserInterfaceStyle = .dark; controller.view.tintColor = .white
        if dialog.kind == .prompt { controller.addTextField { $0.text = dialog.initial } }
        alert = controller; reply = dialog.complete; let ticket = UUID(); generation = ticket
        controller.addAction(UIAlertAction(title: "موافق", style: .default) { _ in finish(controller.textFields?.first?.text ?? "", ticket: ticket) })
        if dialog.kind != .alert { controller.addAction(UIAlertAction(title: "إلغاء", style: .cancel) { _ in finish(nil, ticket: ticket) }) }
        root.present(controller, animated: true)
    }
    static func notice(_ text: String) { present(WebDialog(kind: .alert, text: text, complete: { _ in })) }
    private static func finish(_ value: String?, ticket: UUID) { guard ticket == generation else { return }; let callback = reply; reply = nil; alert = nil; callback?(value) }
    static func cancel() { generation = UUID(); let callback = reply; reply = nil; alert?.dismiss(animated: false); alert = nil; callback?(nil) }
    static func dismissTools() {
        for case let scene as UIWindowScene in UIApplication.shared.connectedScenes { scene.windows.first(where: { $0.isKeyWindow })?.rootViewController?.dismiss(animated: false) }
    }
    private static func topController() -> UIViewController? {
        guard let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first(where: { $0.activationState == .foregroundActive }), var controller = scene.windows.first(where: { $0.isKeyWindow })?.rootViewController else { return nil }
        while let presented = controller.presentedViewController { controller = presented }
        return controller
    }
}
