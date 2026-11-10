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
    let directory: URL
    private let container: URL

    init(container: URL, namespace: String) throws {
        guard !namespace.isEmpty, namespace.utf8.allSatisfy({
            (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || [45, 46, 95].contains($0)
        }), namespace != ".", namespace != ".." else { throw Self.invalidQueue }
        self.container = container
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
        guard descriptor >= 0 else { throw invalidQueue }
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
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        cleanupStaleEntries()
        let id = UUID()
        let leaf = (name as NSString).lastPathComponent.filter { !$0.isNewline && !$0.isASCIIControl }
        let entry = SharedPlistEntry(id: id, name: leaf.isEmpty ? "MobileGestalt.plist" : String(leaf.prefix(200)),
                                    created: Date(), byteCount: data.count)
        let staging = directory.appendingPathComponent("." + id.uuidString + ".pending", isDirectory: true)
        do {
            try fm.createDirectory(at: staging, withIntermediateDirectories: false)
            let lease = try SharedInboxHousekeeping.writerLock(at: staging)
            defer { close(lease) }
            try data.write(to: staging.appendingPathComponent("document.plist"), options: .atomic)
            try JSONEncoder().encode(entry).write(to: staging.appendingPathComponent("entry.json"), options: .atomic)
            // Publish only complete pairs. The main app ignores hidden staging folders.
            try fm.moveItem(at: staging, to: batch(id))
        } catch {
            try? fm.removeItem(at: staging)
            throw error
        }
        return entry
    }

    func entries() throws -> [SharedPlistEntry] {
        let fm = FileManager.default
        guard fm.fileExists(atPath: directory.path) else { return [] }
        cleanupStaleEntries()
        return try fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey], options: .skipsHiddenFiles)
            .compactMap { url in
                guard let id = UUID(uuidString: url.lastPathComponent),
                      let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
                      values.isDirectory == true, values.isSymbolicLink != true,
                      let bytes = try? Self.readLimited(url.appendingPathComponent("entry.json"), limit: 4096),
                      let entry = try? JSONDecoder().decode(SharedPlistEntry.self, from: bytes), entry.id == id,
                      (0...Self.maximumByteCount).contains(entry.byteCount) else { return nil }
                return entry
            }.sorted { $0.created == $1.created ? $0.id.uuidString < $1.id.uuidString : $0.created < $1.created }
    }

    func read(_ entry: SharedPlistEntry) throws -> Data {
        let url = batch(entry.id)
        let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        let file = url.appendingPathComponent("document.plist")
        let fileValues = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard values.isDirectory == true, values.isSymbolicLink != true,
              fileValues.isRegularFile == true, fileValues.isSymbolicLink != true else { throw Self.invalidQueue }
        let bytes = try Self.readDocument(at: file)
        guard bytes.count == entry.byteCount else { throw Self.invalidQueue }
        return bytes
    }

    func acknowledge(_ entry: SharedPlistEntry) throws {
        try FileManager.default.removeItem(at: batch(entry.id))
    }

    func reject(_ entry: SharedPlistEntry) {
        let source = batch(entry.id)
        let destination = directory.appendingPathComponent("." + entry.id.uuidString + ".rejected")
        do {
            try FileManager.default.moveItem(at: source, to: destination)
            try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: destination.path)
        } catch { /* A failed quarantine remains visible to the next scan. */ }
    }

    @discardableResult
    func cleanupStaleEntries(now: Date = Date()) -> Int {
        SharedInboxHousekeeping.clean(container: container, namespace: directory.lastPathComponent, now: now)
    }

    private func batch(_ id: UUID) -> URL { directory.appendingPathComponent(id.uuidString, isDirectory: true) }
}

private enum SharedInboxHousekeeping {
    private static let lockName = ".writer.lock"

    static func writerLock(at directory: URL) throws -> Int32 {
        let path = directory.appendingPathComponent(lockName)
        let descriptor = path.withUnsafeFileSystemRepresentation { path in
            path.map { open($0, O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600) } ?? -1
        }
        guard descriptor >= 0 else { throw error() }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else { let failure = error(); close(descriptor); throw failure }
        return descriptor
    }

    static func clean(container: URL, namespace: String, now: Date) -> Int {
        // Housekeeping is best effort. A failed scan must never prevent normal
        // enqueue/read operations, and an active producer is never waited on.
        guard let parent = try? openDirectory(container: container, namespace: namespace) else { return 0 }
        defer { close(parent) }
        guard let names = try? names(in: parent) else { return 0 }
        var removed = 0
        for name in names {
            guard removed < 32, let retention = retention(for: name) else { continue }
            let child = openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard child >= 0 else { continue }
            defer { close(child) }
            var info = stat()
            guard fstat(child, &info) == 0,
                  now.timeIntervalSince1970 - Double(info.st_mtimespec.tv_sec) >= retention else { continue }
            let lease = openat(child, lockName, O_RDWR | O_CREAT | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC, 0o600)
            guard lease >= 0 else { continue }
            defer { close(lease) }
            var lockInfo = stat()
            guard fstat(lease, &lockInfo) == 0, (lockInfo.st_mode & S_IFMT) == S_IFREG,
                  flock(lease, LOCK_EX | LOCK_NB) == 0 else { continue }
            var current = stat()
            guard fstatat(parent, name, &current, AT_SYMLINK_NOFOLLOW) == 0,
                  current.st_dev == info.st_dev, current.st_ino == info.st_ino else { continue }
            do { try removeContents(in: child); guard unlinkat(parent, name, AT_REMOVEDIR) == 0 else { continue }; removed += 1 }
            catch { continue }
        }
        return removed
    }

    private static func retention(for name: String) -> TimeInterval? {
        let suffix: String
        let age: TimeInterval
        if name.hasSuffix(".pending") { suffix = ".pending"; age = 24 * 60 * 60 }
        else if name.hasSuffix(".rejected") { suffix = ".rejected"; age = 7 * 24 * 60 * 60 }
        else { return nil }
        guard name.hasPrefix(".") else { return nil }
        let identifier = String(name.dropFirst().dropLast(suffix.count))
        guard let id = UUID(uuidString: identifier), id.uuidString == identifier else { return nil }
        return age
    }

    private static func openDirectory(container: URL, namespace: String) throws -> Int32 {
        var descriptor = container.withUnsafeFileSystemRepresentation { path in
            path.map { open($0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC) } ?? -1
        }
        guard descriptor >= 0 else { throw error() }
        for component in ["GestaltX", "ShareInbox", namespace] {
            let next = openat(descriptor, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            let failure = error()
            close(descriptor)
            guard next >= 0 else { throw failure }
            descriptor = next
        }
        return descriptor
    }

    private static func names(in directory: Int32) throws -> [String] {
        let duplicate = dup(directory)
        guard duplicate >= 0 else { throw error() }
        guard let stream = fdopendir(duplicate) else { let failure = error(); close(duplicate); throw failure }
        defer { closedir(stream) }
        rewinddir(stream)
        var result: [String] = []
        errno = 0
        while let entry = readdir(stream) {
            let capacity = MemoryLayout.size(ofValue: entry.pointee.d_name)
            let name = withUnsafePointer(to: &entry.pointee.d_name) { pointer in
                pointer.withMemoryRebound(to: CChar.self, capacity: capacity) { String(cString: $0) }
            }
            if name != ".", name != ".." { result.append(name) }
            errno = 0
        }
        guard errno == 0 else { throw error() }
        return result
    }

    private static func removeContents(in directory: Int32, depth: Int = 0) throws {
        guard depth < 64 else { throw SharedPlistError(key: "The shared plist could not be read. Share it again.") }
        for name in try names(in: directory) {
            var info = stat()
            guard fstatat(directory, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else { throw error() }
            if (info.st_mode & S_IFMT) == S_IFDIR {
                let child = openat(directory, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                guard child >= 0 else { throw error() }
                defer { close(child) }
                try removeContents(in: child, depth: depth + 1)
                guard unlinkat(directory, name, AT_REMOVEDIR) == 0 else { throw error() }
            } else if unlinkat(directory, name, 0) != 0 { throw error() }
        }
    }

    private static func error() -> NSError { NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
}

private extension Character {
    var isASCIIControl: Bool { unicodeScalars.contains { $0.value < 32 || $0.value == 127 } }
}
