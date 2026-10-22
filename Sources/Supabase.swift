import Foundation

/// Just enough of Supabase for sharing recordings: signing in as your MyLoom user, uploading a
/// video in resumable pieces, making a link that expires, listing your uploads and deleting them.
/// It talks to Supabase's HTTP APIs directly, so MyLoom needs no extra libraries.
///
/// Everything happens as the signed-in user, never with the all-powerful secret key, and the
/// storage rules in `supabase/setup.sql` only let that user touch their own folder.
final class Supabase {
    struct Session: Codable {
        var accessToken: String
        var refreshToken: String
        var expiresAt: Date
        var userID: String
        var email: String
    }

    struct StoredObject {
        let name: String        // inside the folder that was listed
        let createdAt: Date?
    }

    enum Failure: LocalizedError {
        case notConfigured
        case signedOut
        case http(Int, String)
        case unexpectedReply(String)

        var errorDescription: String? {
            switch self {
            case .notConfigured: return "Sharing isn't set up yet. Choose Sharing Setup… in MyLoom's menu."
            case .signedOut: return "MyLoom isn't signed in to Supabase any more. Sign in again under Sharing Setup…."
            case .http(let status, let message): return "Supabase said: \(message) (\(status))"
            case .unexpectedReply(let what): return "Supabase sent an unexpected reply (\(what))."
            }
        }
    }

    /// Supabase takes resumable uploads in pieces of exactly this size (the last may be smaller).
    static let chunkSize = 6 * 1024 * 1024

    let projectURL: URL
    let apiKey: String
    /// Called whenever the session changes (signed in, refreshed), so it can be saved.
    var onSessionChange: ((Session?) -> Void)?
    private(set) var session: Session?
    private let urlSession: URLSession

    init(projectURL: URL, apiKey: String, session: Session?) {
        self.projectURL = projectURL
        self.apiKey = apiKey
        self.session = session
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 120
        urlSession = URLSession(configuration: configuration)
    }

    // MARK: - Signing in

    /// Signs in with the email and password of the user made for MyLoom in Supabase.
    func signIn(email: String, password: String) async throws {
        try await requestSession(grant: "password", body: ["email": email, "password": password])
    }

    func signOut() {
        session = nil
        onSessionChange?(nil)
    }

    /// A valid access token, refreshing the session first if it's about to run out.
    func accessToken() async throws -> (token: String, userID: String) {
        guard let session else { throw Failure.signedOut }
        if session.expiresAt.timeIntervalSinceNow < 120 {
            do {
                try await requestSession(grant: "refresh_token", body: ["refresh_token": session.refreshToken])
            } catch Failure.http(let status, _) where (400...401).contains(status) {
                signOut()
                throw Failure.signedOut
            }
        }
        guard let session = self.session else { throw Failure.signedOut }
        return (session.accessToken, session.userID)
    }

    private func requestSession(grant: String, body: [String: String]) async throws {
        var request = URLRequest(url: endpoint("auth/v1/token", query: ["grant_type": grant]))
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "apikey")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let reply = try await json(for: request)
        guard let access = reply["access_token"] as? String, let refresh = reply["refresh_token"] as? String,
              let user = reply["user"] as? [String: Any], let id = user["id"] as? String else {
            throw Failure.unexpectedReply("no session in the sign-in reply")
        }
        let lifetime = (reply["expires_in"] as? Double) ?? 3600
        session = Session(accessToken: access, refreshToken: refresh, expiresAt: Date().addingTimeInterval(lifetime),
                          userID: id, email: (user["email"] as? String) ?? body["email"] ?? "")
        onSessionChange?(session)
    }

    // MARK: - Storage

    /// Uploads `file` to `path` in `bucket` with Supabase's resumable (tus) uploads, in 6 MB pieces,
    /// picking up where it left off if a piece fails. `progress` gets the share sent, 0 to 1.
    func upload(_ file: URL, to path: String, in bucket: String, contentType: String,
                progress: @escaping (Double) -> Void) async throws {
        let size = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        func metadata(_ pairs: [(String, String)]) -> String {
            pairs.map { "\($0.0) \(Data($0.1.utf8).base64EncodedString())" }.joined(separator: ",")
        }
        var create = URLRequest(url: endpoint("storage/v1/upload/resumable"))
        create.httpMethod = "POST"
        try await authorize(&create)
        create.setValue("1.0.0", forHTTPHeaderField: "Tus-Resumable")
        create.setValue(String(size), forHTTPHeaderField: "Upload-Length")
        create.setValue("false", forHTTPHeaderField: "x-upsert")
        create.setValue(metadata([("bucketName", bucket), ("objectName", path), ("contentType", contentType),
                                  ("cacheControl", "3600")]), forHTTPHeaderField: "Upload-Metadata")
        let (_, created) = try await data(for: create, expecting: [201])
        guard let location = created.value(forHTTPHeaderField: "Location"),
              let uploadURL = URL(string: location, relativeTo: projectURL)?.absoluteURL else {
            throw Failure.unexpectedReply("no upload address")
        }

        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var offset = 0
        var failures = 0
        progress(0)
        while offset < size {
            try handle.seek(toOffset: UInt64(offset))
            let chunk = try handle.read(upToCount: Self.chunkSize) ?? Data()
            var patch = URLRequest(url: uploadURL)
            patch.httpMethod = "PATCH"
            try await authorize(&patch)
            patch.setValue("1.0.0", forHTTPHeaderField: "Tus-Resumable")
            patch.setValue(String(offset), forHTTPHeaderField: "Upload-Offset")
            patch.setValue("application/offset+octet-stream", forHTTPHeaderField: "Content-Type")
            do {
                let (_, reply) = try await urlSession.upload(for: patch, from: chunk)
                guard let reply = reply as? HTTPURLResponse, reply.statusCode == 204,
                      let next = reply.value(forHTTPHeaderField: "Upload-Offset").flatMap(Int.init) else {
                    throw Failure.http((reply as? HTTPURLResponse)?.statusCode ?? 0, "upload piece refused")
                }
                offset = next
                failures = 0
                progress(Double(offset) / Double(max(size, 1)))
            } catch {
                // A dropped connection: ask how much arrived, wait a little longer each time, carry on.
                failures += 1
                guard failures <= 5 else { throw error }
                try await Task.sleep(nanoseconds: UInt64(failures) * 2_000_000_000)
                var head = URLRequest(url: uploadURL)
                head.httpMethod = "HEAD"
                try await authorize(&head)
                head.setValue("1.0.0", forHTTPHeaderField: "Tus-Resumable")
                if let (_, reply) = try? await data(for: head, expecting: [200, 204]),
                   let arrived = reply.value(forHTTPHeaderField: "Upload-Offset").flatMap(Int.init) {
                    offset = arrived
                }
            }
        }
    }

    /// A link to `path` that anyone can open, until it stops working after `lifetime` seconds.
    func signedLink(to path: String, in bucket: String, lifetime: TimeInterval) async throws -> URL {
        var request = URLRequest(url: endpoint("storage/v1/object/sign/\(bucket)/\(path)"))
        request.httpMethod = "POST"
        try await authorize(&request)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["expiresIn": Int(lifetime)])
        let reply = try await json(for: request)
        guard let signed = (reply["signedURL"] ?? reply["signedUrl"]) as? String,
              let link = URL(string: projectURL.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                                 + "/storage/v1" + (signed.hasPrefix("/") ? signed : "/" + signed)) else {
            throw Failure.unexpectedReply("no link")
        }
        return link
    }

    /// The files in `folder` of `bucket`, oldest first.
    func list(_ folder: String, in bucket: String) async throws -> [StoredObject] {
        var request = URLRequest(url: endpoint("storage/v1/object/list/\(bucket)"))
        request.httpMethod = "POST"
        try await authorize(&request)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "prefix": folder, "limit": 1000, "offset": 0,
            "sortBy": ["column": "created_at", "order": "asc"],
        ] as [String: Any])
        let (data, _) = try await data(for: request, expecting: [200])
        guard let items = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            throw Failure.unexpectedReply("not a list")
        }
        let dates = ISO8601DateFormatter()
        dates.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return items.compactMap { item in
            guard let name = item["name"] as? String, item["id"] is String else { return nil }   // folders have no id
            let created = (item["created_at"] as? String).flatMap { dates.date(from: $0) ?? ISO8601DateFormatter().date(from: $0) }
            return StoredObject(name: name, createdAt: created)
        }
    }

    /// Deletes `paths` from `bucket`. Paths that are already gone are fine.
    func delete(_ paths: [String], in bucket: String) async throws {
        guard !paths.isEmpty else { return }
        var request = URLRequest(url: endpoint("storage/v1/object/\(bucket)"))
        request.httpMethod = "DELETE"
        try await authorize(&request)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["prefixes": paths])
        _ = try await data(for: request, expecting: [200])
    }

    // MARK: - HTTP

    private func endpoint(_ path: String, query: [String: String] = [:]) -> URL {
        var components = URLComponents(url: projectURL.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty { components.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) } }
        return components.url!
    }

    private func authorize(_ request: inout URLRequest) async throws {
        let token = try await accessToken().token
        request.setValue(apiKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    }

    private func data(for request: URLRequest, expecting statuses: Set<Int>) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await urlSession.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw Failure.unexpectedReply("no HTTP response") }
        guard statuses.contains(http.statusCode) else {
            let reply = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            let message = (reply?["msg"] ?? reply?["message"] ?? reply?["error_description"] ?? reply?["error"]) as? String
            throw Failure.http(http.statusCode, message ?? String(data: data, encoding: .utf8)?.prefix(200).description ?? "error")
        }
        return (data, http)
    }

    private func json(for request: URLRequest) async throws -> [String: Any] {
        let (data, _) = try await data(for: request, expecting: [200])
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw Failure.unexpectedReply("not JSON")
        }
        return object
    }
}
