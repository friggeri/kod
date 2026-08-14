import Foundation
import SourceModel

public struct SourceRenderingSafetyPolicy: Equatable, Sendable {
    public let fullFidelityByteLimit: Int
    public let maximumLineUTF8Length: Int

    public init(
        fullFidelityByteLimit: Int,
        maximumLineUTF8Length: Int
    ) {
        self.fullFidelityByteLimit = fullFidelityByteLimit
        self.maximumLineUTF8Length = maximumLineUTF8Length
    }

    public static let codeViewportDefault = SourceRenderingSafetyPolicy(
        fullFidelityByteLimit: 10 * 1_024 * 1_024,
        maximumLineUTF8Length: 100_000
    )

    public func reason(
        fileByteCount: Int,
        longestLineUTF8Length: Int
    ) -> SourceSafetyModeReason? {
        if fileByteCount > fullFidelityByteLimit {
            return .fileSize(fileByteCount)
        }
        if longestLineUTF8Length > maximumLineUTF8Length {
            return .lineLength(longestLineUTF8Length)
        }
        return nil
    }

    public func message(for reason: SourceSafetyModeReason) -> String {
        switch reason {
        case .fileSize(let size):
            "Safety mode: this file is \(size) bytes, above the \(limitDescription) full-fidelity limit."
        case .lineLength(let length):
            "Safety mode: this file contains a line longer than \(length) UTF-8 bytes."
        }
    }

    private var limitDescription: String {
        let mebibyte = 1_024 * 1_024
        if fullFidelityByteLimit.isMultiple(of: mebibyte) {
            return "\(fullFidelityByteLimit / mebibyte) MB"
        }
        return "\(fullFidelityByteLimit)-byte"
    }
}
