import Foundation

/// The S3 rules that existing backups depend on. Ported from
/// cmd/s3_destination.go.
public enum S3Rules {
    public enum LocationError: Error, CustomStringConvertible, Equatable {
        case invalid(String)

        public var description: String {
            switch self {
            case .invalid(let message): message
            }
        }
    }

    /// Splits `s3://bucket/some/prefix/` into the bucket and `some/prefix`.
    /// Ported from `parseS3URI`.
    public static func parse(_ raw: String) throws -> (bucket: String, prefix: String) {
        guard let components = URLComponents(string: raw) else {
            throw LocationError.invalid("invalid S3 URI: \(raw)")
        }
        guard components.scheme == "s3" else {
            throw LocationError.invalid("unsupported destination scheme: \(components.scheme ?? "")")
        }
        guard let bucket = components.host, !bucket.isEmpty else {
            throw LocationError.invalid("S3 URI missing bucket: \(raw)")
        }
        if components.user != nil || components.password != nil || components.query != nil || components.fragment != nil {
            throw LocationError.invalid("S3 URI must not include user info, query, or fragment")
        }
        let prefix = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return (bucket, prefix)
    }

    /// `<prefix>/<name>`, or `<name>` without a prefix.
    public static func objectKey(prefix: String, name: String) -> String {
        prefix.isEmpty ? name : prefix + "/" + name
    }

    /// The user metadata on each object. Dates are RFC 3339 in UTC, to the
    /// second.
    public static func metadata(for asset: Asset) -> [String: String] {
        var metadata = ["darwin-photos-uuid": asset.uuid]
        if let created = asset.dateCreated {
            metadata["date-created"] = created.iso8601Seconds
        }
        if let modified = asset.dateModified {
            metadata["date-modified"] = modified.iso8601Seconds
        }
        if !asset.originalFilename.isEmpty {
            metadata["original-filename"] = asset.originalFilename
        } else if !asset.filename.isEmpty {
            metadata["original-filename"] = asset.filename
        }
        return metadata
    }

    /// Ported from `contentTypeForFilename`. The fallback is Go's
    /// `mime.TypeByExtension`: its built-in table, then the system
    /// mime.types files, where a later file wins.
    public static func contentType(forFilename filename: String) -> String {
        let ext = "." + (filename as NSString).pathExtension.lowercased()
        switch ext {
        case ".heic": return "image/heic"
        case ".heif": return "image/heif"
        case ".jpg", ".jpeg": return "image/jpeg"
        case ".png": return "image/png"
        case ".gif": return "image/gif"
        case ".mov": return "video/quicktime"
        case ".mp4": return "video/mp4"
        default: return goMimeTypes[ext] ?? "application/octet-stream"
        }
    }

    /// Go's built-in table, with the system files loaded over it.
    static let goMimeTypes: [String: String] = {
        var types = [
            ".avif": "image/avif", ".css": "text/css; charset=utf-8", ".gif": "image/gif",
            ".htm": "text/html; charset=utf-8", ".html": "text/html; charset=utf-8",
            ".jpeg": "image/jpeg", ".jpg": "image/jpeg", ".js": "text/javascript; charset=utf-8",
            ".json": "application/json", ".mjs": "text/javascript; charset=utf-8",
            ".pdf": "application/pdf", ".png": "image/png", ".svg": "image/svg+xml",
            ".wasm": "application/wasm", ".webp": "image/webp", ".xml": "text/xml; charset=utf-8",
        ]
        for path in ["/etc/mime.types", "/etc/apache2/mime.types", "/etc/apache/mime.types", "/etc/httpd/conf/mime.types"] {
            guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { continue }
            for line in text.split(whereSeparator: \.isNewline) {
                let fields = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
                guard fields.count > 1, !fields[0].hasPrefix("#") else { continue }
                for ext in fields.dropFirst() {
                    if ext.hasPrefix("#") { break }
                    types["." + ext] = addCharset(fields[0])
                }
            }
        }
        return types
    }()

    /// Go adds `charset=utf-8` to text types that have no parameters.
    private static func addCharset(_ type: String) -> String {
        type.hasPrefix("text/") && !type.contains(";") ? type + "; charset=utf-8" : type
    }
}
