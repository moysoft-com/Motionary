import UIKit

/// Receives Motionary projects from the system share sheet and hands them off through the app group.
final class ShareViewController: UIViewController {
    private let message = UILabel()
    private let spinner = UIActivityIndicatorView(style: .medium)
    private let done = UIButton(type: .system)

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .secondarySystemBackground
        preferredContentSize = CGSize(width: 360, height: 200)
        message.text = "Sending project to Motionary…"
        message.font = .preferredFont(forTextStyle: .body)
        message.adjustsFontForContentSizeCategory = true
        message.textAlignment = .center
        message.numberOfLines = 0
        spinner.startAnimating()
        done.setTitle("Done", for: .normal)
        done.addTarget(self, action: #selector(finish), for: .touchUpInside)
        done.isHidden = true
        let stack = UIStackView(arrangedSubviews: [spinner, message, done])
        stack.axis = .vertical
        stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: view.layoutMarginsGuide.leadingAnchor, constant: 12),
            stack.trailingAnchor.constraint(equalTo: view.layoutMarginsGuide.trailingAnchor, constant: -12),
            stack.centerYAnchor.constraint(equalTo: view.safeAreaLayoutGuide.centerYAnchor),
        ])

        let items = (extensionContext?.inputItems as? [NSExtensionItem]) ?? []
        let provider = items.flatMap { $0.attachments ?? [] }
            .first { $0.hasItemConformingToTypeIdentifier(MotionaryShareInbox.projectType) }
        guard let provider else {
            report(.failure(MotionaryShareInbox.FailedToQueue()))
            return
        }
        provider.loadFileRepresentation(forTypeIdentifier: MotionaryShareInbox.projectType) { [weak self] url, error in
            // The provider's URL expires when this callback returns.
            let result = Result {
                guard let url else { throw error ?? MotionaryShareInbox.FailedToQueue() }
                try MotionaryShareInbox.queueProject(at: url)
            }
            DispatchQueue.main.async { self?.report(result) }
        }
    }

    private func report(_ result: Result<Void, Error>) {
        spinner.stopAnimating()
        spinner.isHidden = true
        switch result {
        case .success:
            finish()
        case .failure:
            message.text = "Couldn’t send this project to Motionary."
            done.isHidden = false
        }
    }

    @objc private func finish() {
        extensionContext?.completeRequest(returningItems: nil)
    }
}
