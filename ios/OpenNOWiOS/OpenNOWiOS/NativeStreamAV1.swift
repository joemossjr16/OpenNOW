import Foundation
import CoreMedia
import CoreVideo
import VideoToolbox

/// AV1 section 5.5 and the AV1 ISOBMFF codec configuration record.
/// Parses configuration only; compressed frames remain with VideoToolbox.
struct NativeStreamAV1Configuration: Equatable {
    let width: Int
    let height: Int
    let profile: Int
    let level: Int
    let tier: Int
    let bitDepth: Int
    let monochrome: Int
    let subsamplingX: Int
    let subsamplingY: Int
    let chromaPosition: Int
    let primaries: Int
    let transfer: Int
    let matrix: Int
    let fullRange: Bool
    let sequenceOBU: Data

    var codecConfiguration: Data {
        var bytes = Data([
            0x81, UInt8(profile << 5 | level),
            UInt8(tier << 7 | (bitDepth > 8 ? 1 : 0) << 6 | (bitDepth == 12 ? 1 : 0) << 5
                  | monochrome << 4 | subsamplingX << 3 | subsamplingY << 2 | chromaPosition), 0
        ])
        bytes.append(sequenceOBU)
        return bytes
    }

    static func parse(_ frame: Data) throws -> NativeStreamAV1Configuration? {
        // Inspect OBU headers without copying the entire compressed frame. Only
        // the small sequence header is copied when it is actually present.
        try frame.withUnsafeBytes { raw in
            try parseHeaders(raw.bindMemory(to: UInt8.self))
        }
    }

    private static func parseHeaders(_ bytes: UnsafeBufferPointer<UInt8>) throws -> NativeStreamAV1Configuration? {
        var offset = 0
        while offset < bytes.count {
            let start = offset
            let header = bytes[offset]; offset += 1
            guard header & 0x81 == 0 else { throw ParseError.malformed }
            if header & 4 != 0 {
                guard offset < bytes.count, bytes[offset] & 7 == 0 else { throw ParseError.malformed }
                offset += 1
            }
            let headerEnd = offset
            var count = bytes.count - offset
            if header & 2 != 0 {
                count = 0
                var terminated = false
                for shift in stride(from: 0, through: 49, by: 7) {
                    guard offset < bytes.count else { throw ParseError.malformed }
                    let value = bytes[offset]; offset += 1
                    count |= Int(value & 127) << shift
                    if value & 128 == 0 { terminated = true; break }
                }
                guard terminated else { throw ParseError.malformed }
            }
            guard count <= bytes.count - offset else { throw ParseError.malformed }
            if (header >> 3) & 15 == 1 {
                var obu = Data(bytes[start..<headerEnd])
                obu[0] |= 2
                var remaining = count
                repeat {
                    obu.append(UInt8(remaining & 127) | (remaining > 127 ? 128 : 0))
                    remaining >>= 7
                } while remaining > 0
                obu.append(contentsOf: bytes[offset..<(offset + count)])
                return try parseSequence(Data(bytes[offset..<(offset + count)]), obu: obu)
            }
            offset += count
        }
        return nil
    }

    enum ParseError: Error { case malformed, unsupported }

    private static func parseSequence(_ data: Data, obu: Data) throws -> Self {
        var bits = Bits(data)
        let profile = try bits.read(3)
        guard profile <= 2 else { throw ParseError.malformed }
        _ = try bits.read(1) // still_picture
        let reduced = try bits.read(1) == 1
        var level = 0, tier = 0
        if reduced {
            level = try bits.read(5)
        } else {
            var model = false, delayBits = 0
            if try bits.read(1) == 1 {
                try bits.skip(64)
                if try bits.read(1) == 1 { try bits.skipUVLC() }
                model = try bits.read(1) == 1
                if model {
                    delayBits = try bits.read(5) + 1
                    try bits.skip(42)
                }
            }
            let displayDelay = try bits.read(1) == 1
            let points = try bits.read(5) + 1
            for index in 0..<points {
                try bits.skip(12)
                let nextLevel = try bits.read(5)
                let nextTier = nextLevel > 7 ? try bits.read(1) : 0
                if index == 0 { level = nextLevel; tier = nextTier }
                if model, try bits.read(1) == 1 { try bits.skip(delayBits * 2 + 1) }
                if displayDelay, try bits.read(1) == 1 { try bits.skip(4) }
            }
        }
        let widthBits = try bits.read(4) + 1
        let heightBits = try bits.read(4) + 1
        let width = try bits.read(widthBits) + 1
        let height = try bits.read(heightBits) + 1
        if !reduced, try bits.read(1) == 1 { try bits.skip(7) }
        try bits.skip(3)
        if !reduced {
            try bits.skip(4)
            let orderHint = try bits.read(1) == 1
            if orderHint { try bits.skip(2) }
            let chooseScreen = try bits.read(1) == 1
            let screenTools = chooseScreen ? 2 : try bits.read(1)
            if screenTools > 0, try bits.read(1) == 0 { try bits.skip(1) }
            if orderHint { try bits.skip(3) }
        }
        try bits.skip(3)
        let highDepth = try bits.read(1) == 1
        let twelve = profile == 2 && highDepth ? try bits.read(1) == 1 : false
        let depth = twelve ? 12 : highDepth ? 10 : 8
        let mono = profile == 1 ? 0 : try bits.read(1)
        let hasColor = try bits.read(1) == 1
        let primaries = hasColor ? try bits.read(8) : 2
        let transfer = hasColor ? try bits.read(8) : 2
        let matrix = hasColor ? try bits.read(8) : 2
        var fullRange = false, x = 1, y = 1, chroma = 0
        if mono == 1 {
            fullRange = try bits.read(1) == 1
        } else {
            if primaries == 1 && transfer == 13 && matrix == 0 {
                fullRange = true; x = 0; y = 0
            } else {
                fullRange = try bits.read(1) == 1
                if profile == 1 { x = 0; y = 0 }
                if profile == 2 {
                    x = depth == 12 ? try bits.read(1) : 1
                    y = depth == 12 && x == 1 ? try bits.read(1) : 0
                }
                if x == 1 && y == 1 { chroma = try bits.read(2) }
            }
            try bits.skip(1)
        }
        try bits.skip(1) // film_grain_params_present
        // Validate trailing_bits rather than accepting truncated configuration.
        guard try bits.read(1) == 1 else { throw ParseError.malformed }
        while bits.remaining > 0 {
            guard try bits.read(1) == 0 else { throw ParseError.malformed }
        }
        return Self(width: width, height: height, profile: profile, level: level, tier: tier,
                    bitDepth: depth, monochrome: mono, subsamplingX: x, subsamplingY: y,
                    chromaPosition: chroma, primaries: primaries, transfer: transfer,
                    matrix: matrix, fullRange: fullRange, sequenceOBU: obu)
    }

    private struct Bits {
        let bytes: [UInt8]
        var position = 0
        init(_ data: Data) { bytes = Array(data) }
        var remaining: Int { bytes.count * 8 - position }
        mutating func read(_ count: Int) throws -> Int {
            guard count >= 0, count <= 32, count <= remaining else { throw ParseError.malformed }
            var value = 0
            for _ in 0..<count {
                value = value << 1 | Int((bytes[position / 8] >> (7 - position % 8)) & 1)
                position += 1
            }
            return value
        }
        mutating func skip(_ count: Int) throws {
            guard count >= 0, count <= remaining else { throw ParseError.malformed }
            position += count
        }
        mutating func skipUVLC() throws {
            var leading = 0
            while try read(1) == 0 {
                leading += 1
                if leading == 32 { return }
            }
            try skip(leading)
        }
    }
}

/// Shared with the macOS validation probe so real encoded samples can exercise
/// the same configuration/session creation as the iOS WebRTC adapter.
final class NativeStreamAV1HardwareDecoder {
    private let lock = NSRecursiveLock()
    private var session: VTDecompressionSession?
    private var format: CMVideoFormatDescription?
    private var configuration: NativeStreamAV1Configuration?
    private let admission = NativeStreamDecodeAdmission(maximumInFlight: 2)
    private let performance = DecodePerformance()

    private final class DecodePerformance {
        private let lock = NSLock()
        private var start: TimeInterval = 0
        private var frames = 0
        private var total: TimeInterval = 0
        private var maximum: TimeInterval = 0
        func record(started: TimeInterval, delivered: Bool) {
            let ended = ProcessInfo.processInfo.systemUptime
            lock.lock()
            if start == 0 { start = started }
            if delivered {
                frames += 1
                total += ended - started
                maximum = max(maximum, ended - started)
            }
            let elapsed = ended - start
            var message: String?
            if elapsed >= 2 && frames > 0 {
                message = String(format: "av1 decoded=%.1f fps decode-delivery=%.2f ms max-decode-delivery=%.2f ms",
                    Double(frames) / elapsed, total * 1000 / Double(frames), maximum * 1000)
                start = ended; frames = 0; total = 0; maximum = 0
            }
            lock.unlock()
            if let message { NativeStreamVideoPerformanceLog.record(message) }
        }
    }

    static var isSupported: Bool { VTIsHardwareDecodeSupported(kCMVideoCodecType_AV1) }

    deinit { release() }

    func release() {
        lock.lock(); defer { lock.unlock() }
        if let session { VTDecompressionSessionInvalidate(session) }
        session = nil; format = nil; configuration = nil
    }

    func decode(_ payload: Data, timestamp: UInt32, asynchronous: Bool = false,
                output: @escaping (OSStatus, CVPixelBuffer?) -> Void) -> OSStatus {
        lock.lock(); defer { lock.unlock() }
        do {
            if let config = try NativeStreamAV1Configuration.parse(payload), config != configuration {
                let status = configure(config)
                guard status == noErr else { return status }
            }
        } catch {
            NSLog("[OpenNOW] AV1 configuration rejected: %@", String(describing: error))
            return kVTVideoDecoderBadDataErr
        }
        guard let session, let format, !payload.isEmpty else { return kVTVideoDecoderBadDataErr }
        var block: CMBlockBuffer?
        var status = CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault,
            memoryBlock: nil, blockLength: payload.count, blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil, offsetToData: 0, dataLength: payload.count, flags: 0,
            blockBufferOut: &block)
        guard status == noErr, let block else { return status }
        status = payload.withUnsafeBytes { bytes in
            CMBlockBufferReplaceDataBytes(with: bytes.baseAddress!, blockBuffer: block,
                                          offsetIntoDestination: 0, dataLength: payload.count)
        }
        guard status == noErr else { return status }
        var timing = CMSampleTimingInfo(duration: .invalid,
            presentationTimeStamp: CMTime(value: Int64(timestamp), timescale: 90_000), decodeTimeStamp: .invalid)
        var size = payload.count
        var sample: CMSampleBuffer?
        status = CMSampleBufferCreateReady(allocator: kCFAllocatorDefault, dataBuffer: block,
            formatDescription: format, sampleCount: 1, sampleTimingEntryCount: 1,
            sampleTimingArray: &timing, sampleSizeEntryCount: 1, sampleSizeArray: &size,
            sampleBufferOut: &sample)
        guard status == noErr, let sample else { return status }
        // Bound hardware submissions without dropping compressed reference frames.
        // Async output lets WebRTC schedule the next frame while hardware decodes.
        guard let permit = admission.acquire() else { return kVTInvalidSessionErr }
        let started = ProcessInfo.processInfo.systemUptime
        let performance = self.performance
        var infoFlags = VTDecodeInfoFlags()
        let flags: VTDecodeFrameFlags = asynchronous ? ._EnableAsynchronousDecompression : []
        let result = VTDecompressionSessionDecodeFrame(session, sampleBuffer: sample, flags: flags,
            infoFlagsOut: &infoFlags) { status, _, buffer, _, _ in
                defer { permit.complete() }
                output(status, buffer)
                performance.record(started: started, delivered: status == noErr && buffer != nil)
            }
        if result != noErr || infoFlags.contains(.frameDropped) { permit.complete() }
        return result
    }

    private func configure(_ config: NativeStreamAV1Configuration) -> OSStatus {
        guard Self.isSupported, config.profile == 0, config.bitDepth <= 10,
              config.subsamplingX == 1, config.subsamplingY == 1 else {
            return kVTCouldNotFindVideoDecoderErr
        }
        var extensions: [CFString: Any] = [
            kCMFormatDescriptionExtension_FormatName: "av01",
            kCMFormatDescriptionExtension_Depth: 24,
            kCMFormatDescriptionExtension_FullRangeVideo: config.fullRange,
            kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms: ["av1C": config.codecConfiguration],
            "BitsPerComponent" as CFString: config.bitDepth
        ]
        if config.primaries == 9 {
            extensions[kCMFormatDescriptionExtension_ColorPrimaries] = kCMFormatDescriptionColorPrimaries_ITU_R_2020
        } else if config.primaries == 1 {
            extensions[kCMFormatDescriptionExtension_ColorPrimaries] = kCMFormatDescriptionColorPrimaries_ITU_R_709_2
        }
        switch config.transfer {
        case 16: extensions[kCMFormatDescriptionExtension_TransferFunction] = kCMFormatDescriptionTransferFunction_SMPTE_ST_2084_PQ
        case 18: extensions[kCMFormatDescriptionExtension_TransferFunction] = kCMFormatDescriptionTransferFunction_ITU_R_2100_HLG
        case 1, 6, 14, 15: extensions[kCMFormatDescriptionExtension_TransferFunction] = kCMFormatDescriptionTransferFunction_ITU_R_709_2
        default: break
        }
        if config.matrix == 9 {
            extensions[kCMFormatDescriptionExtension_YCbCrMatrix] = kCMFormatDescriptionYCbCrMatrix_ITU_R_2020
        } else if config.matrix == 1 {
            extensions[kCMFormatDescriptionExtension_YCbCrMatrix] = kCMFormatDescriptionYCbCrMatrix_ITU_R_709_2
        }
        var nextFormat: CMVideoFormatDescription?
        var status = CMVideoFormatDescriptionCreate(allocator: kCFAllocatorDefault,
            codecType: kCMVideoCodecType_AV1, width: Int32(config.width), height: Int32(config.height),
            extensions: extensions as CFDictionary, formatDescriptionOut: &nextFormat)
        guard status == noErr, let nextFormat else { return status }
        var specification: [CFString: Any] = [:]
        if #available(iOS 17.0, macOS 10.9, *) {
            specification[kVTVideoDecoderSpecification_RequireHardwareAcceleratedVideoDecoder] = true
        }
        let pixelFormat: OSType = config.bitDepth == 10
            ? (config.fullRange ? kCVPixelFormatType_420YpCbCr10BiPlanarFullRange : kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange)
            : (config.fullRange ? kCVPixelFormatType_420YpCbCr8BiPlanarFullRange : kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)
        let attributes: [CFString: Any] = [kCVPixelBufferPixelFormatTypeKey: pixelFormat,
            kCVPixelBufferMetalCompatibilityKey: true, kCVPixelBufferIOSurfacePropertiesKey: [:]]
        var nextSession: VTDecompressionSession?
        status = VTDecompressionSessionCreate(allocator: kCFAllocatorDefault,
            formatDescription: nextFormat, decoderSpecification: specification as CFDictionary,
            imageBufferAttributes: attributes as CFDictionary, outputCallback: nil,
            decompressionSessionOut: &nextSession)
        guard status == noErr, let nextSession else { return status }
        VTSessionSetProperty(nextSession, key: kVTDecompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        if let session { VTDecompressionSessionInvalidate(session) }
        session = nextSession; format = nextFormat; configuration = config
        NSLog("[OpenNOW] VideoToolbox AV1 ready %dx%d depth=%d primaries=%d transfer=%d matrix=%d pixelFormat=%u",
              config.width, config.height, config.bitDepth, config.primaries, config.transfer, config.matrix, pixelFormat)
        return noErr
    }
}

#if canImport(WebRTC) && os(iOS)
@preconcurrency import WebRTC

final class NativeStreamAV1VideoDecoder: NSObject, RTCVideoDecoder {
    private let hardware = NativeStreamAV1HardwareDecoder()
    private let inputCadence = NativeStreamFrameCadenceTrace(stage: "av1-input")
    private let decodeCalls = NativeStreamDecodeCallTrace(stage: "av1")
    private let lock = NSLock()
    private var callback: RTCVideoDecoderCallback?
    func setCallback(_ callback: @escaping RTCVideoDecoderCallback) {
        lock.lock(); self.callback = callback; lock.unlock()
    }
    func startDecode(withNumberOfCores numberOfCores: Int32) -> Int { 0 }
    func release() -> Int {
        hardware.release()
        lock.lock(); callback = nil; lock.unlock()
        return 0
    }
    func implementationName() -> String { "OpenNOW-VideoToolbox-AV1" }
    func decode(_ image: RTCEncodedImage, missingFrames: Bool,
                codecSpecificInfo info: RTCCodecSpecificInfo?, renderTimeMs: Int64) -> Int {
        let callStarted = ProcessInfo.processInfo.systemUptime
        defer { decodeCalls.record(started: callStarted) }
        inputCadence.record(timestamp: image.timeStamp, renderTimeMs: renderTimeMs)
        let timestamp = image.timeStamp
        let timestampNs = image.captureTimeMs > 0 ? image.captureTimeMs * 1_000_000
            : Int64(timestamp) * 1_000_000_000 / 90_000
        let rotation = image.rotation
        return Int(hardware.decode(image.buffer, timestamp: timestamp, asynchronous: true) { [weak self] status, buffer in
            guard let self else { return }
            guard status == noErr, let buffer else {
                if status != noErr { NSLog("[OpenNOW] AV1 hardware output failed status=%d", status) }
                return
            }
            self.lock.lock(); let callback = self.callback; self.lock.unlock()
            let frame = RTCVideoFrame(buffer: RTCCVPixelBuffer(pixelBuffer: buffer),
                rotation: rotation, timeStampNs: timestampNs)
            frame.timeStamp = Int32(bitPattern: timestamp)
            callback?(frame)
        })
    }
}
#endif

/// A bounded, local performance trace containing only numeric media diagnostics.
/// Disk and console work run outside the decode, display and GPU callback threads.
enum NativeStreamVideoPerformanceLog {
    private static let queue = DispatchQueue(label: "OpenNOW.VideoPerformanceLog", qos: .utility)

    static func record(_ message: String) {
        #if os(iOS)
        queue.async {
            NSLog("[OpenNOW] %@", message)
            do {
                let cache = try FileManager.default.url(for: .cachesDirectory, in: .userDomainMask,
                    appropriateFor: nil, create: true)
                let url = cache.appendingPathComponent("video-performance.log")
                let previous = cache.appendingPathComponent("video-performance.previous.log")
                let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                if size >= 65_536 {
                    try? FileManager.default.removeItem(at: previous)
                    try FileManager.default.moveItem(at: url, to: previous)
                }
                if !FileManager.default.fileExists(atPath: url.path) {
                    _ = FileManager.default.createFile(atPath: url.path, contents: nil)
                }
                let handle = try FileHandle(forWritingTo: url)
                defer { try? handle.close() }
                try handle.seekToEnd()
                let line = String(format: "%.3f %@\n", ProcessInfo.processInfo.systemUptime, message)
                try handle.write(contentsOf: Data(line.utf8))
            } catch {
                // Diagnostic failure must never interrupt playback.
            }
        }
        #endif
    }
}

/// Backpressure for asynchronous hardware work. Every admission is returned once,
/// including immediate decode errors, dropped outputs and callback cancellation.
final class NativeStreamDecodeAdmission {
    private let semaphore: DispatchSemaphore
    init(maximumInFlight: Int) {
        precondition(maximumInFlight > 0)
        semaphore = DispatchSemaphore(value: maximumInFlight)
    }
    func acquire(timeout: DispatchTime = .distantFuture) -> Permit? {
        guard semaphore.wait(timeout: timeout) == .success else { return nil }
        return Permit(semaphore: semaphore)
    }
    final class Permit {
        private let lock = NSLock()
        private let semaphore: DispatchSemaphore
        private var completed = false
        init(semaphore: DispatchSemaphore) { self.semaphore = semaphore }
        func complete() {
            lock.lock()
            let shouldSignal = !completed
            completed = true
            lock.unlock()
            if shouldSignal { semaphore.signal() }
        }
        deinit { complete() }
    }
}


/// Numeric cadence only: no payload, session identifiers or wall-clock metadata.
/// RTP uses a 90 kHz clock; subtraction must handle its 32-bit wrap correctly.
struct NativeStreamFrameCadence {
    struct Snapshot {
        let arrivalFPS: Double
        let rtpFPS: Double
        let maximumGapMs: Double
        let maximumRTPGapMs: Double
        let burstIntervals: Int
        let repeatedTimestamps: Int
        let discontinuities: Int
        let nominal120Intervals: Int
        let zeroRenderTimes: Int
        let frames: Int
    }
    private var start: TimeInterval?
    private var previousArrival: TimeInterval?
    private var previousTimestamp: UInt32?
    private var frames = 0
    private var ticks: UInt64 = 0
    private var rtpIntervals = 0
    private var maximumGap: TimeInterval = 0
    private var maximumRTPStep: UInt32 = 0
    private var bursts = 0
    private var repeats = 0
    private var discontinuities = 0
    private var nominal120 = 0
    private var zeroRenderTimes = 0

    mutating func record(timestamp: UInt32, now: TimeInterval,
                         renderTimeMs: Int64? = nil) -> Snapshot? {
        if start == nil { start = now }
        if let previousArrival {
            let gap = max(0, now - previousArrival)
            maximumGap = max(maximumGap, gap)
            if gap < 0.002 { bursts += 1 }
        }
        if let previousTimestamp {
            let delta = timestamp &- previousTimestamp
            if delta == 0 { repeats += 1 }
            else if delta < 90_000 {
                ticks += UInt64(delta); rtpIntervals += 1
                maximumRTPStep = max(maximumRTPStep, delta)
                if delta == 750 { nominal120 += 1 }
            } else { discontinuities += 1 }
        }
        frames += 1
        if renderTimeMs == 0 { zeroRenderTimes += 1 }
        previousArrival = now; previousTimestamp = timestamp
        let elapsed = now - (start ?? now)
        guard elapsed >= 2 else { return nil }
        let snapshot = Snapshot(arrivalFPS: Double(frames - 1) / elapsed,
            rtpFPS: ticks > 0 ? Double(rtpIntervals) * 90_000 / Double(ticks) : 0,
            maximumGapMs: maximumGap * 1000, maximumRTPGapMs: Double(maximumRTPStep) / 90, burstIntervals: bursts,
            repeatedTimestamps: repeats, discontinuities: discontinuities,
            nominal120Intervals: nominal120, zeroRenderTimes: zeroRenderTimes,
            frames: frames)
        // Keep the last frame as the anchor for the following window.
        start = now; frames = 1; ticks = 0; rtpIntervals = 0
        maximumGap = 0; maximumRTPStep = 0; bursts = 0; repeats = 0; discontinuities = 0
        nominal120 = 0; zeroRenderTimes = 0
        return snapshot
    }
}

final class NativeStreamFrameCadenceTrace {
    private let lock = NSLock()
    private let stage: String
    private var cadence = NativeStreamFrameCadence()
    init(stage: String) { self.stage = stage }
    func record(timestamp: UInt32, renderTimeMs: Int64? = nil) {
        let now = ProcessInfo.processInfo.systemUptime
        lock.lock()
        let snapshot = cadence.record(timestamp: timestamp, now: now, renderTimeMs: renderTimeMs)
        lock.unlock()
        guard let snapshot else { return }
        NativeStreamVideoPerformanceLog.record(String(format:
            "cadence %@ arrival=%.1f fps rtp-clock=%.1f fps max-gap=%.2f ms max-rtp-gap=%.2f ms bursts=%d repeated=%d discontinuities=%d step750=%d zero-render=%d frames=%d",
            stage, snapshot.arrivalFPS, snapshot.rtpFPS, snapshot.maximumGapMs, snapshot.maximumRTPGapMs,
            snapshot.burstIntervals, snapshot.repeatedTimestamps, snapshot.discontinuities,
            snapshot.nominal120Intervals, snapshot.zeroRenderTimes, snapshot.frames))
    }
}


/// Measures the entire decoder entry point, including parsing, configuration,
/// admission waits and VT submission. Callback latency is measured separately.
final class NativeStreamDecodeCallTrace {
    private let lock = NSLock()
    private let stage: String
    private var start: TimeInterval?
    private var calls = 0
    private var total: TimeInterval = 0
    private var maximum: TimeInterval = 0
    init(stage: String) { self.stage = stage }
    func record(started: TimeInterval) {
        let now = ProcessInfo.processInfo.systemUptime
        lock.lock()
        if start == nil { start = started }
        calls += 1
        let duration = max(0, now - started)
        total += duration; maximum = max(maximum, duration)
        var message: String?
        if now - (start ?? now) >= 2 {
            message = String(format: "decode-call %@ avg=%.2f ms max=%.2f ms calls=%d",
                stage, total * 1000 / Double(calls), maximum * 1000, calls)
            start = now; calls = 0; total = 0; maximum = 0
        }
        lock.unlock()
        if let message { NativeStreamVideoPerformanceLog.record(message) }
    }
}

/// A stats window only computes differences within the same stream. Missing or
/// reset counters invalidate that interval rather than inventing zero delays.
struct NativeStreamReceiveDelayTrace {
    private var previous: [String: Double] = [:]
    mutating func sample(_ values: [String: Double]) -> [String: Double] {
        defer { previous = values }
        func delta(_ key: String) -> Double? {
            guard let current = values[key], let old = previous[key],
                  current.isFinite, old.isFinite, current >= old else { return nil }
            return current - old
        }
        var result: [String: Double] = [:]
        func delay(_ name: String, _ total: String, _ count: String) {
            guard let sum = delta(total), let frames = delta(count), frames > 0 else { return }
            result[name] = sum * 1000 / frames
        }
        delay("buffer-ms", "jitterBufferDelay", "jitterBufferEmittedCount")
        delay("target-ms", "jitterBufferTargetDelay", "jitterBufferEmittedCount")
        delay("minimum-ms", "jitterBufferMinimumDelay", "jitterBufferEmittedCount")
        delay("assembly-ms", "totalAssemblyTime", "framesAssembledFromMultiplePackets")
        delay("processing-ms", "totalProcessingDelay", "framesDecoded")
        for key in ["framesDropped", "nackCount", "pliCount", "freezeCount"] {
            if let change = delta(key) { result[key] = change }
        }
        return result
    }
}
