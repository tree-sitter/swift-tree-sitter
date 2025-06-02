import Foundation
import TreeSitter

extension String.Encoding {
    var internalEncoding: TSInputEncoding? {
        switch self {
        case .utf8:
            return TSInputEncodingUTF8
        case .utf16LittleEndian:
            return TSInputEncodingUTF16LE
        case .utf16BigEndian:
            return TSInputEncodingUTF16BE
        default:
            return nil
        }
    }
}

public extension NSRange {
    var byteRange: Range<UInt32> {
        let lower = UInt32(location * 2)
        let upper = UInt32(NSMaxRange(self) * 2)

        return lower..<upper
    }
}

public extension Range where Element == UInt32 {
    var range: NSRange {
        let start = lowerBound / 2
        let end = upperBound / 2

        return NSRange(start..<end)
    }
}
