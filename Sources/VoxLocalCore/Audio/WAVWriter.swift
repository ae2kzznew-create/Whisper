import Foundation

/// Incrementally writes a mono 16-bit PCM WAV file (RIFF little-endian).
/// The header is finalized with correct chunk sizes on `finalize()`.
public final class WAVWriter {
    public let url: URL
    public let sampleRate: UInt32
    public private(set) var samplesWritten: UInt64 = 0

    private let handle: FileHandle
    private static let headerSize = 44

    public init(url: URL, sampleRate: UInt32 = 16000) throws {
        self.url = url
        self.sampleRate = sampleRate
        FileManager.default.createFile(atPath: url.path, contents: nil)
        handle = try FileHandle(forWritingTo: url)
        // Placeholder header; sizes patched in finalize().
        try handle.write(contentsOf: Self.header(sampleRate: sampleRate, dataBytes: 0))
    }

    public func append(_ samples: UnsafePointer<Int16>, count: Int) throws {
        guard count > 0 else { return }
        let data = Data(bytes: samples, count: count * MemoryLayout<Int16>.size)
        try handle.write(contentsOf: data)
        samplesWritten += UInt64(count)
    }

    public func append(_ samples: [Int16]) throws {
        try samples.withUnsafeBufferPointer { buf in
            if let base = buf.baseAddress {
                try append(base, count: buf.count)
            }
        }
    }

    public var duration: TimeInterval {
        TimeInterval(samplesWritten) / TimeInterval(sampleRate)
    }

    /// Patches RIFF/data chunk sizes and closes the file.
    public func finalize() throws {
        let dataBytes = UInt32(clamping: samplesWritten * 2)
        try handle.seek(toOffset: 0)
        try handle.write(contentsOf: Self.header(sampleRate: sampleRate, dataBytes: dataBytes))
        try handle.close()
    }

    public func cancelAndDelete() {
        try? handle.close()
        try? FileManager.default.removeItem(at: url)
    }

    static func header(sampleRate: UInt32, dataBytes: UInt32) -> Data {
        var data = Data(capacity: headerSize)
        func le32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
        func le16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
        let channels: UInt16 = 1
        let bitsPerSample: UInt16 = 16
        let byteRate = sampleRate * UInt32(channels) * UInt32(bitsPerSample / 8)
        data.append(contentsOf: Array("RIFF".utf8))
        le32(36 + dataBytes)
        data.append(contentsOf: Array("WAVE".utf8))
        data.append(contentsOf: Array("fmt ".utf8))
        le32(16)
        le16(1) // PCM
        le16(channels)
        le32(sampleRate)
        le32(byteRate)
        le16(channels * bitsPerSample / 8) // block align
        le16(bitsPerSample)
        data.append(contentsOf: Array("data".utf8))
        le32(dataBytes)
        return data
    }
}
