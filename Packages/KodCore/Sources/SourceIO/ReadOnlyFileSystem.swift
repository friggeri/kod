import Foundation
import SourceModel

public struct ReadOnlyFilePayload: Sendable {
    public let data: Data
    public let modificationDate: Date?

    public init(data: Data, modificationDate: Date?) {
        self.data = data
        self.modificationDate = modificationDate
    }
}

public protocol ReadOnlyFileSystem: Sendable {
    func readFile(at url: URL) throws -> ReadOnlyFilePayload
}

public enum SourceIOError: Error, Equatable, Sendable {
    case fileAbsent(URL)
    case permissionDenied(URL)
    case notRegularFile(URL)
    case metadataUnavailable(URL)
    case unreadableFile(URL)
    case unsupportedEncoding(URL)
    case fallbackEncodingFailed(UInt)
}

public struct LocalReadOnlyFileSystem: ReadOnlyFileSystem {
    public init() {}

    public func readFile(at url: URL) throws -> ReadOnlyFilePayload {
        let values: URLResourceValues
        do {
            values = try url.resourceValues(forKeys: [
                .contentModificationDateKey,
                .isRegularFileKey
            ])
        } catch {
            throw Self.mappedReadError(error, url: url, metadata: true)
        }

        guard values.isRegularFile == true else {
            throw SourceIOError.notRegularFile(url)
        }

        do {
            return ReadOnlyFilePayload(
                data: try Data(contentsOf: url, options: .mappedIfSafe),
                modificationDate: values.contentModificationDate
            )
        } catch {
            throw Self.mappedReadError(error, url: url, metadata: false)
        }
    }

    private static func mappedReadError(
        _ error: Error,
        url: URL,
        metadata: Bool
    ) -> SourceIOError {
        let cocoaError = error as NSError
        switch cocoaError.code {
        case NSFileNoSuchFileError, NSFileReadNoSuchFileError:
            return .fileAbsent(url)
        case NSFileReadNoPermissionError:
            return .permissionDenied(url)
        default:
            return metadata ? .metadataUnavailable(url) : .unreadableFile(url)
        }
    }
}
