import Foundation

struct DirectoryMetadataScanBudget {
    private var remainingEntryCount: Int
    let maxDepth: Int
    private let deadline: Date
    private let didVisitEntry: (@Sendable () -> Void)?

    init(
        maxEntryCount: Int,
        maxDepth: Int,
        timeLimit: TimeInterval,
        startedAt: Date = Date(),
        didVisitEntry: (@Sendable () -> Void)? = nil)
    {
        self.remainingEntryCount = max(0, maxEntryCount)
        self.maxDepth = max(0, maxDepth)
        self.deadline = startedAt.addingTimeInterval(max(0, timeLimit))
        self.didVisitEntry = didVisitEntry
    }

    mutating func files(
        in directory: URL,
        fileManager: FileManager = .default,
        clock: () -> Date = Date.init) -> [URL]
    {
        self.entries(in: directory, fileManager: fileManager, clock: clock)
            .compactMap { entry in entry.isDirectory ? nil : entry.url }
    }

    mutating func childDirectories(
        in directory: URL,
        fileManager: FileManager = .default,
        clock: () -> Date = Date.init) -> [URL]
    {
        self.entries(in: directory, fileManager: fileManager, clock: clock)
            .compactMap { entry in entry.isDirectory ? entry.url : nil }
    }

    func hasTimeRemaining(clock: () -> Date = Date.init) -> Bool {
        clock() < self.deadline
    }

    private mutating func entries(
        in directory: URL,
        fileManager: FileManager,
        clock: () -> Date) -> [(url: URL, isDirectory: Bool)]
    {
        guard self.maxDepth > 0,
              self.remainingEntryCount > 0,
              clock() < self.deadline,
              let enumerator = fileManager.enumerator(
                  at: directory,
                  includingPropertiesForKeys: [.isDirectoryKey],
                  options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants])
        else { return [] }

        var entries: [(url: URL, isDirectory: Bool)] = []
        while self.remainingEntryCount > 0, clock() < self.deadline {
            guard let url = enumerator.nextObject() as? URL else { break }
            self.remainingEntryCount -= 1
            self.didVisitEntry?()
            let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
            entries.append((url, isDirectory))
        }
        return entries
    }
}
