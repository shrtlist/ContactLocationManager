//
//  ContactEditor.swift
//  ContactLocationManagerExample
//

import ContactsUI
import SwiftUI

/// Shows a contact in the system contact sheet, ready to edit. Saving or cancelling calls `onFinish`.
struct ContactEditor: UIViewControllerRepresentable {
    let contact: CNContact
    let onFinish: () -> Void

    func makeUIViewController(context: Context) -> UINavigationController {
        let viewController = CNContactViewController(for: contact)
        viewController.allowsEditing = true
        viewController.delegate = context.coordinator
        return UINavigationController(rootViewController: viewController)
    }

    func updateUIViewController(_ uiViewController: UINavigationController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(onFinish: onFinish) }

    final class Coordinator: NSObject, CNContactViewControllerDelegate {
        let onFinish: () -> Void
        init(onFinish: @escaping () -> Void) { self.onFinish = onFinish }

        func contactViewController(_ viewController: CNContactViewController, didCompleteWith contact: CNContact?) {
            onFinish()
        }
    }
}
