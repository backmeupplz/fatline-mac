import Foundation

struct DraftStore {
    private struct Draft: Codable {
        let version: Int
        let text: String
    }

    private enum DraftError: Error {
        case unsupportedVersion(Int)
    }

    let directory: URL

    private var current: URL { directory.appending(path: "draft.json") }
    private var backup: URL { directory.appending(path: "draft.previous.json") }

    func load() throws -> String {
        if let data = try read(current) {
            do {
                return try decode(data).text
            } catch is DecodingError {
                let preserved = directory.appending(path: "draft.unreadable-\(UUID()).json")
                try FileManager.default.moveItem(at: current, to: preserved)
            }
        }
        guard let data = try read(backup) else { return "" }
        return try decode(data).text
    }

    func save(_ text: String) throws {
        let data = try JSONEncoder().encode(Draft(version: 1, text: text))
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if let previous = try read(current) {
            guard try decode(previous).text != text else { return }
            try previous.write(to: backup, options: .atomic)
        }
        try data.write(to: current, options: .atomic)
    }

    private func read(_ url: URL) throws -> Data? {
        do {
            return try Data(contentsOf: url)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return nil
        }
    }

    private func decode(_ data: Data) throws -> Draft {
        let draft = try JSONDecoder().decode(Draft.self, from: data)
        guard draft.version == 1 else { throw DraftError.unsupportedVersion(draft.version) }
        return draft
    }
}
