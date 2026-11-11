// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import Darwin

struct SharedPlistError: LocalizedError {
    let key: String
    var errorDescription: String? { NSLocalizedString(key, comment: "") }
}

struct SharedPlistEntry: Codable, Identifiable, Sendable {
    let id: UUID
    let name: String
    let created: Date
    let byteCount: Int
}

struct SharedPlistInbox: Sendable {
    static let maximumByteCount = 16 * 1024 * 1024
    private static let maximumMetadataByteCount = 4096
    let directory: URL
    private let container: URL
    private let namespace: String

    init(container: URL, namespace: String) throws {
        guard !namespace.isEmpty, namespace.utf8.allSatisfy({
            (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || [45, 46, 95].contains($0)
        }), namespace != ".", namespace != ".." else { throw Self.invalidQueue }
        self.container = container
        self.namespace = namespace
        directory = container.appendingPathComponent("GestaltX/ShareInbox", isDirectory: true)
            .appendingPathComponent(namespace, isDirectory: true)
    }

    private static var invalidQueue: SharedPlistError {
        SharedPlistError(key: "The shared plist could not be read. Share it again.")
    }

    static func validate(_ data: Data) throws {
        guard data.count <= maximumByteCount else { throw SharedPlistError(key: "Choose a plist smaller than 16 MB.") }
        guard let root = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any],
              root["CacheExtra"] is [String: Any] else {
            throw SharedPlistError(key: "Choose a MobileGestalt plist with a CacheExtra dictionary.")
        }
    }

    // Read within the item-provider callback, while its temporary URL is valid.
    static func readDocument(at url: URL, coordinator: NSFileCoordinator = NSFileCoordinator()) throws -> Data {
        guard url.isFileURL else { throw invalidQueue }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        // Coordination itself can wait on a FIFO before invoking the accessor.
        // Reject known special files first, but let File Providers materialize
        // missing placeholders or supply a different URL during coordination.
        var info = stat()
        let status = url.withUnsafeFileSystemRepresentation { path in
            path.map { lstat($0, &info) } ?? -1
        }
        guard status != 0 || (info.st_mode & S_IFMT) == S_IFREG else { throw invalidQueue }
        // A security scope grants access, while coordination asks File Providers
        // to materialize their document and keeps concurrent changes out of the read.
        var coordinationError: NSError?
        var result: Result<Data, Error>?
        coordinator.coordinate(readingItemAt: url, options: [], error: &coordinationError) { readableURL in
            result = Result {
                let data = try readLimited(readableURL, limit: maximumByteCount)
                try validate(data)
                return data
            }
        }
        if let coordinationError { throw coordinationError }
        guard let result else { throw invalidQueue }
        return try result.get()
    }

    private static func readLimited(_ url: URL, limit: Int) throws -> Data {
        // Open without waiting for a writer and check the opened descriptor, not
        // just the path: a FIFO must not block the app while scanning its inbox.
        let descriptor = url.withUnsafeFileSystemRepresentation { path in
            path.map { open($0, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC) } ?? -1
        }
        return try readLimited(descriptor: descriptor, limit: limit)
    }

    private static func readLimited(_ name: String, in directory: Int32, limit: Int) throws -> Data {
        try readLimited(descriptor: openat(directory, name, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC), limit: limit)
    }

    private static func readLimited(descriptor: Int32, limit: Int) throws -> Data {
        guard descriptor >= 0 else { throw fileError() }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        var info = stat()
        guard fstat(descriptor, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else { throw invalidQueue }
        var data = Data()
        while true {
            let part = try handle.read(upToCount: min(64 * 1024, limit - data.count + 1)) ?? Data()
            if part.isEmpty { return data }
            guard part.count <= limit - data.count else { throw SharedPlistError(key: "Choose a plist smaller than 16 MB.") }
            data.append(part)
        }
    }

    func enqueue(_ data: Data, name: String) throws -> SharedPlistEntry {
        try Self.validate(data)
        guard let parent = try openDirectory(create: true) else { throw Self.invalidQueue }
        defer { close(parent) }
        let id = UUID()
        let entry = SharedPlistEntry(id: id, name: Self.displayName(name),
                                    created: Date(), byteCount: data.count)
        let metadata = try JSONEncoder().encode(entry)
        guard metadata.count <= Self.maximumMetadataByteCount else { throw Self.invalidQueue }
        let staging = "." + id.uuidString + ".pending"
        do {
            guard mkdirat(parent, staging, 0o700) == 0 else { throw Self.fileError() }
            let stagingDirectory = try Self.openChild(staging, in: parent)
            defer { close(stagingDirectory) }
            try Self.write(data, named: "document.plist", in: stagingDirectory)
            try Self.write(metadata, named: "entry.json", in: stagingDirectory)
            // Publish only complete pairs. The main app ignores hidden staging folders.
            guard renameat(parent, staging, parent, id.uuidString) == 0 else { throw Self.fileError() }
        } catch {
            try? Self.removeDirectory(staging, in: parent)
            throw error
        }
        return entry
    }

    func entries() throws -> [SharedPlistEntry] {
        guard let parent = try openDirectory(create: false) else { return [] }
        defer { close(parent) }
        return try Self.names(in: parent).compactMap { name -> SharedPlistEntry? in
                guard let id = UUID(uuidString: name),
                      let child = try? Self.openChild(name, in: parent) else { return nil }
                defer { close(child) }
                guard let bytes = try? Self.readLimited("entry.json", in: child, limit: Self.maximumMetadataByteCount),
                      let entry = try? JSONDecoder().decode(SharedPlistEntry.self, from: bytes), entry.id == id,
                      (0...Self.maximumByteCount).contains(entry.byteCount) else { return nil }
                return entry
            }.sorted { $0.created == $1.created ? $0.id.uuidString < $1.id.uuidString : $0.created < $1.created }
    }

    func read(_ entry: SharedPlistEntry) throws -> Data {
        guard let parent = try openDirectory(create: false) else { throw Self.invalidQueue }
        defer { close(parent) }
        let child = try Self.openChild(entry.id.uuidString, in: parent)
        defer { close(child) }
        // Published inbox files are local copies, not File Provider URLs. Open
        // relative to the pinned directory so replacing a path cannot redirect
        // a read into a different namespace while it is in progress.
        let bytes = try Self.readLimited("document.plist", in: child, limit: Self.maximumByteCount)
        try Self.validate(bytes)
        guard bytes.count == entry.byteCount else { throw Self.invalidQueue }
        return bytes
    }

    func acknowledge(_ entry: SharedPlistEntry) throws {
        guard let parent = try openDirectory(create: false) else { throw Self.invalidQueue }
        defer { close(parent) }
        try Self.removeDirectory(entry.id.uuidString, in: parent)
    }

    func reject(_ entry: SharedPlistEntry) {
        guard let parent = try? openDirectory(create: false) else { return }
        defer { close(parent) }
        _ = renameat(parent, entry.id.uuidString, parent, "." + entry.id.uuidString + ".rejected")
    }

    private static func fileError() -> NSError { NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }

    private static func openChild(_ name: String, in parent: Int32) throws -> Int32 {
        let descriptor = openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw fileError() }
        return descriptor
    }

    private func openDirectory(create: Bool) throws -> Int32? {
        if create { try FileManager.default.createDirectory(at: container, withIntermediateDirectories: true) }
        var descriptor = container.withUnsafeFileSystemRepresentation { path in
            path.map { open($0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC) } ?? -1
        }
        if descriptor < 0 {
            if !create && errno == ENOENT { return nil }
            throw Self.fileError()
        }
        do {
            // Check every component below the trusted App Group container. The
            // descriptor walk also survives concurrent renaming of an ancestor.
            for name in ["GestaltX", "ShareInbox", namespace] {
                if create && mkdirat(descriptor, name, 0o700) != 0 && errno != EEXIST { throw Self.fileError() }
                let next: Int32
                do { next = try Self.openChild(name, in: descriptor) }
                catch {
                    if !create && (error as NSError).code == Int(ENOENT) { close(descriptor); return nil }
                    throw error
                }
                close(descriptor)
                descriptor = next
            }
            return descriptor
        } catch { close(descriptor); throw error }
    }

    private static func names(in directory: Int32) throws -> [String] {
        let duplicate = dup(directory)
        guard duplicate >= 0 else { throw fileError() }
        guard let stream = fdopendir(duplicate) else { let error = fileError(); close(duplicate); throw error }
        defer { closedir(stream) }
        rewinddir(stream)
        var result: [String] = []
        errno = 0
        while let entry = readdir(stream) {
            let capacity = MemoryLayout.size(ofValue: entry.pointee.d_name)
            let name = withUnsafePointer(to: &entry.pointee.d_name) { pointer in
                pointer.withMemoryRebound(to: CChar.self, capacity: capacity) {
                    String(cString: $0)
                }
            }
            if name != ".", name != ".." { result.append(name) }
            errno = 0
        }
        guard errno == 0 else { throw fileError() }
        return result
    }

    private static func write(_ data: Data, named name: String, in directory: Int32) throws {
        let descriptor = openat(directory, name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw fileError() }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        try handle.write(contentsOf: data)
    }

    private static func removeDirectory(_ name: String, in parent: Int32, depth: Int = 0) throws {
        guard depth < 64 else { throw invalidQueue }
        let directory = try openChild(name, in: parent)
        defer { close(directory) }
        for child in try names(in: directory) {
            var info = stat()
            guard fstatat(directory, child, &info, AT_SYMLINK_NOFOLLOW) == 0 else { throw fileError() }
            if (info.st_mode & S_IFMT) == S_IFDIR { try removeDirectory(child, in: directory, depth: depth + 1) }
            else if unlinkat(directory, child, 0) != 0 { throw fileError() }
        }
        guard unlinkat(parent, name, AT_REMOVEDIR) == 0 else { throw fileError() }


    private static func displayName(_ name: String) -> String {
        let leaf = (name as NSString).lastPathComponent.filter { !$0.isNewline && !$0.isASCIIControl }
        var result = ""
        var byteCount = 0
        // A Character may contain many UTF-8 bytes, so a character count alone
        // cannot keep entry.json within the reader's limit. Leave room for JSON
        // escaping and the remaining metadata, without splitting a grapheme.
        for character in leaf.prefix(200) {
            let count = String(character).utf8.count
            guard count <= 1024 - byteCount else { break }
            result.append(character)
            byteCount += count
        }
        return result.isEmpty ? "MobileGestalt.plist" : result
    }
}

private extension Character {
    var isASCIIControl: Bool { unicodeScalars.contains { $0.value < 32 || $0.value == 127 } }
}
