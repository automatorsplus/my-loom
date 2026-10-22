import AppKit

/// Sharing a recording as a link, through your own Supabase project: MyLoom makes a smaller copy
/// (`ShareCopy`), uploads it to a private bucket, and copies a link anyone can watch with. The
/// link stops working after 14 days, and the video is deleted from Supabase then too: by a job
/// in Supabase itself (see `supabase/setup.sql`), and by MyLoom whenever it's running.
///
/// Nothing is uploaded unless you set this up and choose to share a recording.
@MainActor
final class Sharing {
    nonisolated static let bucket = "myloom-shares"
    /// How long a link works, and how long the video stays in Supabase.
    nonisolated static let lifetime: TimeInterval = 14 * 24 * 60 * 60

    struct Share: Codable {
        let path: String        // in the bucket: <user id>/<name>.mp4
        let title: String       // the recording's file name
        let link: URL
        let sharedAt: Date
        var expiresAt: Date { sharedAt.addingTimeInterval(Sharing.lifetime) }
    }

    /// Called when shares, the sign-in, or an upload in progress change.
    var onChange: (() -> Void)?
    private(set) var shares: [Share] = []
    private(set) var isSharing = false
    let panel = SharePanel()
    let setup = SharingSetup()

    private var client: Supabase?
    private var task: Task<Void, Never>?
    private var cleanupTimer: Timer?

    private static let sessionAccount = "supabase-session"
    /// The MyLoom user's password, kept in the keychain so MyLoom can sign itself in again if its
    /// session is ever lost, rather than a share failing.
    private static let passwordAccount = "supabase-password"
    private static var sharesFile: URL {
        let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("MyLoom")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appendingPathComponent("shares.json")
    }

    init() {
        shares = (try? JSONDecoder().decode([Share].self, from: Data(contentsOf: Self.sharesFile))) ?? []
        if let address = UserDefaults.standard.string(forKey: "supabaseURL").flatMap(URL.init(string:)),
           let key = UserDefaults.standard.string(forKey: "supabaseKey") {
            let session = Keychain.read(Self.sessionAccount).flatMap { try? JSONDecoder().decode(Supabase.Session.self, from: Data($0.utf8)) }
            connect(to: address, key: key, session: session)
        }
        setup.sharing = self
        panel.onCancel = { [weak self] in self?.task?.cancel() }
        // Clean up now and every few hours, so expired videos don't linger in Supabase.
        cleanupTimer = Timer.scheduledTimer(withTimeInterval: 6 * 60 * 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.removeExpired() }
        }
        removeExpired()
    }

    // MARK: - Setup

    /// Signed in, or able to sign in again by itself with the saved password.
    var isReady: Bool { client != nil && (client?.session != nil || canSignInAgain) }
    var projectURL: String { UserDefaults.standard.string(forKey: "supabaseURL") ?? "" }
    var apiKey: String { UserDefaults.standard.string(forKey: "supabaseKey") ?? "" }
    var signedInEmail: String? { client?.session?.email ?? savedEmail }
    private var savedEmail: String? { UserDefaults.standard.string(forKey: "supabaseEmail") }
    private var canSignInAgain: Bool { savedEmail != nil && Keychain.read(Self.passwordAccount) != nil }

    /// Signs in to the Supabase project at `address` with its public key and the MyLoom user's email
    /// and password, then checks the bucket can be used. The session and the password are kept in
    /// the keychain; the password lets MyLoom sign in again by itself if the session is ever lost.
    func signIn(projectURL address: String, key: String, email: String, password: String) async throws {
        var text = address.trimmingCharacters(in: .whitespacesAndNewlines)
        while text.hasSuffix("/") { text.removeLast() }
        guard let url = URL(string: text), url.scheme == "https" || url.host == "127.0.0.1" || url.host == "localhost" else {
            throw Supabase.Failure.unexpectedReply("the project URL should look like https://abcd.supabase.co")
        }
        let key = key.trimmingCharacters(in: .whitespacesAndNewlines)
        connect(to: url, key: key, session: nil)
        try await client?.signIn(email: email.trimmingCharacters(in: .whitespaces), password: password)
        UserDefaults.standard.set(text, forKey: "supabaseURL")
        UserDefaults.standard.set(key, forKey: "supabaseKey")
        UserDefaults.standard.set(email.trimmingCharacters(in: .whitespaces), forKey: "supabaseEmail")
        Keychain.write(Self.passwordAccount, password)
        // Listing your folder proves the bucket exists and the rules let you in.
        guard let client, let session = client.session else { throw Supabase.Failure.signedOut }
        _ = try await client.list(session.userID, in: Self.bucket)
        onChange?()
    }

    /// Forgets the session and the saved password.
    func signOut() {
        client?.signOut()
        Keychain.write(Self.passwordAccount, nil)
        UserDefaults.standard.removeObject(forKey: "supabaseEmail")
        onChange?()
    }

    /// The client, signed in: if its session is missing or can't be renewed, MyLoom signs in again
    /// with the saved password, so a lost session never stops a share.
    private func signedInClient() async throws -> Supabase {
        guard let client else { throw Supabase.Failure.notConfigured }
        do {
            _ = try await client.accessToken()
            return client
        } catch {
            guard let email = savedEmail, let password = Keychain.read(Self.passwordAccount) else { throw error }
            try await client.signIn(email: email, password: password)
            onChange?()
            return client
        }
    }

    private func connect(to url: URL, key: String, session: Supabase.Session?) {
        let client = Supabase(projectURL: url, apiKey: key, session: session)
        client.onSessionChange = { session in
            Keychain.write(Self.sessionAccount, session.flatMap { try? JSONEncoder().encode($0) }.flatMap { String(data: $0, encoding: .utf8) })
        }
        self.client = client
    }

    // MARK: - Sharing

    /// Makes a copy of `recording` to share, uploads it and copies its link, showing progress in
    /// the share window. Opens Sharing Setup first if sharing isn't set up.
    func share(_ recording: URL) {
        guard isReady else {
            setup.show(message: "Sign in to your Supabase project to share recordings.")
            return
        }
        guard !isSharing else {
            panel.showCurrent()
            return
        }
        isSharing = true
        onChange?()
        let title = recording.deletingPathExtension().lastPathComponent
        panel.begin(title: title)
        task = Task { @MainActor in
            var copy: URL?
            defer {
                if let copy { try? FileManager.default.removeItem(at: copy) }
                isSharing = false
                task = nil
                onChange?()
            }
            do {
                let made = try await ShareCopy.make(from: recording) { fraction in
                    Task { @MainActor in self.panel.show(.preparing(fraction)) }
                }
                copy = made
                try Task.checkCancellation()
                let client = try await signedInClient()
                let (_, userID) = try await client.accessToken()
                let path = "\(userID)/\(Self.fileName(for: recording))"
                try await client.upload(made, to: path, in: Self.bucket, contentType: "video/mp4") { fraction in
                    Task { @MainActor in self.panel.show(.uploading(fraction)) }
                }
                let link: URL
                do {
                    link = try await client.signedLink(to: path, in: Self.bucket, lifetime: Self.lifetime)
                } catch {
                    try? await client.delete([path], in: Self.bucket)   // no link, so don't keep the video
                    throw error
                }
                // Never hand out a link that doesn't play: open it as a viewer would first.
                panel.show(.checking)
                let size = (try? made.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                guard await Self.verify(link, bytes: size) else {
                    try? await client.delete([path], in: Self.bucket)
                    throw Supabase.Failure.unexpectedReply("the new link didn't play the whole video back, so it wasn't kept. Please share again")
                }
                let share = Share(path: path, title: title, link: link, sharedAt: Date())
                shares.insert(share, at: 0)
                save()
                copyToClipboard(share)
                panel.show(.done(share))
            } catch is CancellationError {
                panel.show(.failed("Sharing was cancelled."))
            } catch let error as URLError where error.code == .cancelled {
                panel.show(.failed("Sharing was cancelled."))
            } catch {
                panel.show(.failed(error.localizedDescription))
            }
        }
    }

    /// Opens `link` as someone you send it to would (no sign-in) and checks the whole video is
    /// there: a video, of the size uploaded, served the way a browser starts playing it. Tries a few
    /// times over several seconds, in case a new upload takes a moment to be served.
    nonisolated static func verify(_ link: URL, bytes expected: Int) async -> Bool {
        for attempt in 0..<4 {
            if attempt > 0 { try? await Task.sleep(nanoseconds: UInt64(attempt) * 1_500_000_000) }
            var request = URLRequest(url: link, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
            request.setValue("bytes=0-0", forHTTPHeaderField: "Range")
            guard let (_, response) = try? await URLSession.shared.data(for: request),
                  let http = response as? HTTPURLResponse else { continue }
            // A browser asks for part of the video and expects 206 with the total size; a server
            // that ignores the request sends the whole thing with 200.
            let total = http.value(forHTTPHeaderField: "Content-Range").flatMap { $0.split(separator: "/").last.flatMap { Int($0) } }
                ?? (http.statusCode == 200 ? Int(http.expectedContentLength) : nil)
            let isVideo = http.value(forHTTPHeaderField: "Content-Type")?.hasPrefix("video/mp4") == true
            if [200, 206].contains(http.statusCode), isVideo, total == expected { return true }
        }
        return false
    }

    /// Shares still within their 14 days, newest first.
    var activeShares: [Share] { shares.filter { $0.expiresAt > Date() } }

    func copyToClipboard(_ share: Share) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(share.link.absoluteString, forType: .string)
    }

    /// Deletes a shared video from Supabase now, so its link stops working.
    func delete(_ share: Share) async throws {
        let client = try await signedInClient()
        try await client.delete([share.path], in: Self.bucket)
        shares.removeAll { $0.path == share.path }
        save()
        onChange?()
    }

    /// Forgets shares past their 14 days and deletes any videos of yours in Supabase older than that.
    func removeExpired() {
        let before = shares.count
        shares.removeAll { $0.expiresAt <= Date() }
        if shares.count != before { save(); onChange?() }
        guard isReady else { return }
        Task { @MainActor in
            guard let client = try? await signedInClient() else { return }
            _ = try? await Self.deleteExpired(using: client)
        }
    }

    /// Deletes the signed-in user's videos that are older than 14 days. Returns how many.
    nonisolated static func deleteExpired(using client: Supabase) async throws -> Int {
        let (_, userID) = try await client.accessToken()
        let cutoff = Date().addingTimeInterval(-lifetime)
        let expired = try await client.list(userID, in: bucket)
            .filter { ($0.createdAt ?? .distantFuture) < cutoff }
            .map { "\(userID)/\($0.name)" }
        try await client.delete(expired, in: bucket)
        return expired.count
    }

    private func save() {
        try? JSONEncoder().encode(shares).write(to: Self.sharesFile, options: .atomic)
    }

    /// A name for the upload that can't be guessed, starting with the date for anyone looking in Supabase.
    private static func fileName(for recording: URL) -> String {
        let date = ISO8601DateFormatter.string(from: Date(), timeZone: .current, formatOptions: [.withFullDate])
        let random = (0..<16).map { _ in String(format: "%02x", UInt8.random(in: 0...255)) }.joined()
        return "\(date)-\(random).mp4"
    }

    /// The setup SQL, bundled with the app, for Sharing Setup's Copy button.
    static var setupSQL: String? {
        Bundle.main.url(forResource: "setup", withExtension: "sql").flatMap { try? String(contentsOf: $0) }
    }
}

// MARK: - The share window

/// Shows a share's progress, then its link with Copy and Open buttons. It floats over other windows
/// and is left out of recordings.
@MainActor
final class SharePanel: NSObject {
    enum State {
        case preparing(Double)
        case uploading(Double)
        case checking
        case done(Sharing.Share)
        case failed(String)
    }

    var onCancel: (() -> Void)?
    var windowID: CGWindowID { CGWindowID(panel.windowNumber) }

    private let panel: NSPanel
    private let heading = NSTextField(labelWithString: "")
    private let status = NSTextField(wrappingLabelWithString: "")
    private let bar = NSProgressIndicator()
    private let linkField = NSTextField(labelWithString: "")
    private let copyButton = NSButton(title: "Copy Link", target: nil, action: nil)
    private let openButton = NSButton(title: "Open", target: nil, action: nil)
    private let closeButton = NSButton(title: "Cancel", target: nil, action: nil)
    private var share: Sharing.Share?
    private var working = false

    override init() {
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 440, height: 170),
                        styleMask: [.titled, .closable, .utilityWindow], backing: .buffered, defer: false)
        super.init()
        panel.title = "Share"
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        heading.font = .boldSystemFont(ofSize: 13)
        heading.lineBreakMode = .byTruncatingMiddle
        status.textColor = .secondaryLabelColor
        status.isSelectable = false
        bar.isIndeterminate = false
        bar.minValue = 0
        bar.maxValue = 1
        linkField.isSelectable = true
        linkField.lineBreakMode = .byTruncatingMiddle
        linkField.font = .systemFont(ofSize: 11)
        // The link is long: show its start and end in one line rather than widening the window.
        linkField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        heading.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        for (button, action) in [(copyButton, #selector(copyLink)), (openButton, #selector(openLink)), (closeButton, #selector(close))] {
            button.target = self
            button.action = action
            button.bezelStyle = .rounded
        }
        copyButton.keyEquivalent = "\r"
        let buttons = NSStackView(views: [closeButton, NSView(), openButton, copyButton])
        buttons.orientation = .horizontal
        let stack = NSStackView(views: [heading, status, bar, linkField, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 20, bottom: 16, right: 20)
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.widthAnchor.constraint(equalToConstant: 460).isActive = true
        for view in [heading, status, bar, linkField, buttons] {
            view.translatesAutoresizingMaskIntoConstraints = false
            view.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -40).isActive = true
        }
        panel.contentView = stack
    }

    func begin(title: String) {
        share = nil
        heading.stringValue = "Sharing “\(title)”"
        show(.preparing(0))
        if !panel.isVisible { panel.center() }
        panel.orderFrontRegardless()
    }

    func showCurrent() { panel.orderFrontRegardless() }

    func show(_ state: State) {
        switch state {
        case .preparing(let fraction):
            working = true
            status.stringValue = "Making a smaller copy to upload… \(Int(fraction * 100))%"
            bar.doubleValue = fraction * 0.3
        case .uploading(let fraction):
            working = true
            status.stringValue = "Uploading… \(Int(fraction * 100))%"
            bar.doubleValue = 0.3 + fraction * 0.65
        case .checking:
            working = true
            status.stringValue = "Checking the link plays…"
            bar.doubleValue = 0.97
        case .done(let share):
            working = false
            self.share = share
            let date = share.expiresAt.formatted(date: .abbreviated, time: .shortened)
            status.stringValue = "The link is copied: paste it anywhere. Anyone with it can watch until \(date), when the video is deleted."
            bar.doubleValue = 1
            linkField.stringValue = share.link.absoluteString
        case .failed(let message):
            working = false
            status.stringValue = "Couldn't share: \(message)"
            bar.doubleValue = 0
        }
        bar.isHidden = !working
        linkField.isHidden = share == nil
        copyButton.isHidden = share == nil
        openButton.isHidden = share == nil
        closeButton.title = working ? "Cancel" : "Close"
        panel.layoutIfNeeded()
        panel.setContentSize(panel.contentView?.fittingSize ?? panel.frame.size)
    }

    @objc private func copyLink() {
        guard let share else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(share.link.absoluteString, forType: .string)
        status.stringValue = "Copied again."
    }

    @objc private func openLink() {
        if let share { NSWorkspace.shared.open(share.link) }
    }

    @objc private func close() {
        if working { onCancel?() } else { panel.orderOut(nil) }
    }
}

// MARK: - Setup window

/// Where you connect MyLoom to your Supabase project, once: its address and public key, and the
/// email and password of the user made for MyLoom. Also copies the setup SQL for Supabase.
@MainActor
final class SharingSetup: NSObject {
    weak var sharing: Sharing?
    private var window: NSWindow?
    private let urlField = NSTextField()
    private let keyField = NSTextField()
    private let emailField = NSTextField()
    private let passwordField = NSSecureTextField()
    private let status = NSTextField(wrappingLabelWithString: "")
    private let signInButton = NSButton(title: "Sign In", target: nil, action: nil)
    private let signOutButton = NSButton(title: "Sign Out", target: nil, action: nil)

    func show(message: String? = nil) {
        if window == nil { build() }
        guard let sharing, let window else { return }
        urlField.stringValue = sharing.projectURL
        keyField.stringValue = sharing.apiKey
        if let email = sharing.signedInEmail { emailField.stringValue = email }
        passwordField.stringValue = ""
        refresh(message: message)
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    private func refresh(message: String? = nil) {
        guard let sharing else { return }
        if let message {
            status.stringValue = message
        } else if let email = sharing.signedInEmail {
            status.stringValue = "Signed in as \(email). Ready to share."
        } else {
            status.stringValue = "Not signed in. Nothing is uploaded until you are, and then only recordings you share."
        }
        signOutButton.isEnabled = sharing.isReady
    }

    private func build() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 420), styleMask: [.titled, .closable],
                              backing: .buffered, defer: false)
        window.title = "Sharing Setup"
        window.isReleasedWhenClosed = false
        let steps = NSTextField(wrappingLabelWithString: """
            Once, in your Supabase dashboard:
            1. Project Settings → Storage: set the upload file size limit to 1 GB.
            2. Authentication → Users → Add user: an email and password just for MyLoom (tick Auto Confirm).
            3. SQL Editor: paste the setup SQL (Copy Setup SQL below), fill in your project URL, secret key \
            and that user's email at the top, and Run. It makes the private bucket, lets only that user \
            share, and adds the job that deletes videos after 14 days.
            Then fill in below. The URL and public (anon or publishable) key are under Project Settings → API.
            """)
        steps.font = .systemFont(ofSize: 12)
        urlField.placeholderString = "https://abcdefgh.supabase.co"
        keyField.placeholderString = "Public key (anon or sb_publishable_…)"
        emailField.placeholderString = "Email of the MyLoom user"
        passwordField.placeholderString = "Its password (kept in your keychain)"
        let grid = NSGridView(views: [
            [NSTextField(labelWithString: "Project URL"), urlField],
            [NSTextField(labelWithString: "Public key"), keyField],
            [NSTextField(labelWithString: "Email"), emailField],
            [NSTextField(labelWithString: "Password"), passwordField],
        ])
        grid.column(at: 0).xPlacement = .trailing
        grid.rowSpacing = 8
        for field in [urlField, keyField, emailField, passwordField] {
            field.widthAnchor.constraint(equalToConstant: 360).isActive = true
        }
        status.textColor = .secondaryLabelColor
        status.isSelectable = false
        let copySQL = NSButton(title: "Copy Setup SQL", target: self, action: #selector(copySetupSQL))
        signInButton.target = self
        signInButton.action = #selector(signIn)
        signInButton.keyEquivalent = "\r"
        signOutButton.target = self
        signOutButton.action = #selector(signOut)
        let buttons = NSStackView(views: [copySQL, NSView(), signOutButton, signInButton])
        let stack = NSStackView(views: [steps, grid, status, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        stack.edgeInsets = NSEdgeInsets(top: 18, left: 20, bottom: 18, right: 20)
        for view in [steps, status, buttons] {
            view.translatesAutoresizingMaskIntoConstraints = false
            view.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -40).isActive = true
        }
        window.contentView = stack
        window.setContentSize(stack.fittingSize)
        window.center()
        self.window = window
    }

    @objc private func signIn() {
        guard let sharing else { return }
        signInButton.isEnabled = false
        status.stringValue = "Signing in…"
        Task { @MainActor in
            defer { signInButton.isEnabled = true }
            do {
                try await sharing.signIn(projectURL: urlField.stringValue, key: keyField.stringValue,
                                         email: emailField.stringValue, password: passwordField.stringValue)
                passwordField.stringValue = ""
                refresh()
            } catch {
                refresh(message: "Couldn't sign in: \(error.localizedDescription)")
            }
        }
    }

    @objc private func signOut() {
        sharing?.signOut()
        refresh()
    }

    @objc private func copySetupSQL() {
        guard let sql = Sharing.setupSQL else {
            status.stringValue = "The setup SQL wasn't found in the app. It's also in MyLoom/supabase/setup.sql."
            return
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(sql, forType: .string)
        status.stringValue = "Setup SQL copied. Paste it into Supabase's SQL Editor, fill in the three values at the top, and Run."
    }
}
