import Foundation
import OnnxRuntimeBindings

/// A typed tensor crossing the ONNX Runtime boundary.
///
/// The PP-OCR graphs are all float in, float out, but the layout model returns
/// int32 alongside its float detections, so the multi-tensor path has to carry
/// the element type with the data.
enum PPTensor {
    case float([Float], shape: [Int])
    case int32([Int32], shape: [Int])

    var shape: [Int] {
        switch self {
        case let .float(_, shape), let .int32(_, shape): return shape
        }
    }

    var floats: [Float]? {
        if case let .float(values, _) = self { return values }
        return nil
    }

    var int32s: [Int32]? {
        if case let .int32(values, _) = self { return values }
        return nil
    }
}

/// ONNX Runtime documents its environment as safe to share across threads;
/// the Objective-C binding just does not say so.
extension ORTEnv: @unchecked @retroactive Sendable {}

/// Thin wrapper over an ONNX Runtime session.
///
/// PP-OCR's detection, recognition and orientation graphs are all single-input
/// and single-output, which `run(input:shape:)` covers; the layout model takes
/// three inputs and returns three outputs, which is what `run(inputs:outputNames:)`
/// is for.
///
/// Sendable because an ONNX Runtime session may run from several threads at
/// once, and nothing here changes after `init`.
final class PPSession: @unchecked Sendable {
    private let session: ORTSession
    private let inputName: String
    private let outputName: String

    /// Every input and output the graph declares, in the order it declares them.
    let inputNames: [String]
    let outputNames: [String]

    /// The file the session was built from.
    let modelPath: URL

    /// Running a graph on the GPU through Core ML.
    struct GPUPlacement {
        /// A size for every symbolic input dimension: Core ML only keeps a
        /// graph on the GPU when its shapes are known in advance.
        var fixedDimensions: [String: Int64]
        /// Where Core ML keeps the compiled model, so it is built once rather
        /// than on every launch. One directory per graph and shape: Core ML's
        /// cache key does not see the fixed dimensions, and a compiled model
        /// read back for the wrong shapes crashes the process.
        var cacheDirectory: URL
    }

    /// `intraOpThreads` overrides the thread count for a graph that is run
    /// from several threads at once, where each call should keep to one core.
    init(modelPath: URL, env: ORTEnv, config: PPOCRConfig, intraOpThreads: Int? = nil,
         gpu: GPUPlacement? = nil) throws {
        self.modelPath = modelPath
        do {
            let options = try ORTSessionOptions()
            try options.setLogSeverityLevel(.error)
            try options.setGraphOptimizationLevel(.all)
            if let intraOpThreads {
                try options.setIntraOpNumThreads(Int32(intraOpThreads))
            } else if config.threadCount > 0 {
                try options.setIntraOpNumThreads(Int32(config.threadCount))
            }
            if let gpu {
                for (name, value) in gpu.fixedDimensions {
                    var failure: NSError?
                    guard OCRFlowFixInputDimension(options, name, value, &failure) else {
                        throw failure ?? PPOCRError.sessionFailed(name)
                    }
                }
                // GPU only, never the Neural Engine: the GPU computes in
                // 32-bit floats and matches the CPU to about 1e-6, while the
                // Neural Engine's 16-bit arithmetic moves results visibly.
                try options.appendCoreMLExecutionProvider(withOptionsV2: [
                    "ModelFormat": "MLProgram",
                    "MLComputeUnits": "CPUAndGPU",
                    "ModelCacheDirectory": gpu.cacheDirectory.path(percentEncoded: false),
                ])
            }
            session = try ORTSession(env: env, modelPath: modelPath.path(percentEncoded: false), sessionOptions: options)
            inputNames = try session.inputNames()
            outputNames = try session.outputNames()
            guard let input = inputNames.first, let output = outputNames.first else {
                throw PPOCRError.sessionFailed(String(localized: "Model \(modelPath.lastPathComponent) has no usable inputs/outputs"))
            }
            inputName = input
            outputName = output
        } catch let error as PPOCRError {
            throw error
        } catch {
            throw PPOCRError.sessionFailed("\(modelPath.lastPathComponent): \(error.localizedDescription)")
        }
    }

    /// Runs the graph on a float tensor and returns the output values with the
    /// shape the model reported.
    func run(input: [Float], shape: [Int]) throws -> (values: [Float], shape: [Int]) {
        do {
            let data = input.withUnsafeBufferPointer { buf in
                NSMutableData(bytes: buf.baseAddress, length: buf.count * MemoryLayout<Float>.size)
            }
            let value = try ORTValue(tensorData: data,
                                     elementType: .float,
                                     shape: shape.map { NSNumber(value: $0) })
            let outputs = try session.run(withInputs: [inputName: value],
                                          outputNames: [outputName],
                                          runOptions: nil)
            guard let result = outputs[outputName] else {
                throw PPOCRError.inferenceFailed(String(localized: "The model returned no output \(outputName)"))
            }
            // `data` backs the input tensor for the whole call; ONNX Runtime does
            // not copy it, so keep it alive until after `run` returns.
            withExtendedLifetime(data) {}
            // The tensor's bytes belong to `result` and are not retained by
            // the data object that points at them, so `result` has to outlive
            // the copy.
            return try withExtendedLifetime(result) {
                let info = try result.tensorTypeAndShapeInfo()
                let outShape = info.shape.map(\.intValue)
                let raw = try result.tensorData()
                let count = outShape.reduce(1, *)
                guard raw.length >= count * MemoryLayout<Float>.size else {
                    throw PPOCRError.unexpectedOutputShape(String(localized: "Expected \(count) floats, got \(raw.length) bytes"))
                }
                return (Self.elements(raw, count: count, of: Float.self), outShape)
            }
        } catch let error as PPOCRError {
            throw error
        } catch {
            throw PPOCRError.inferenceFailed(error.localizedDescription)
        }
    }

    /// Runs the graph on values that are already ONNX Runtime tensors and
    /// hands its outputs back the same way, so one graph's outputs can feed
    /// another's inputs without a copy or a change of element type.
    func run(values: [String: ORTValue], outputNames wanted: [String]) throws -> [String: ORTValue] {
        do {
            return try session.run(withInputs: values, outputNames: Set(wanted), runOptions: nil)
        } catch {
            throw PPOCRError.inferenceFailed(error.localizedDescription)
        }
    }

    /// Wraps tensors for `run(values:outputNames:)`. The returned buffers
    /// back the values and have to outlive the call.
    static func values(_ inputs: [String: PPTensor]) throws -> (values: [String: ORTValue], backing: [NSMutableData]) {
        var backing: [NSMutableData] = []
        var values: [String: ORTValue] = [:]
        for (name, tensor) in inputs {
            let data: NSMutableData
            let type: ORTTensorElementDataType
            switch tensor {
            case let .float(elements, _):
                data = elements.withUnsafeBufferPointer {
                    NSMutableData(bytes: $0.baseAddress, length: $0.count * MemoryLayout<Float>.size)
                }
                type = .float
            case let .int32(elements, _):
                data = elements.withUnsafeBufferPointer {
                    NSMutableData(bytes: $0.baseAddress, length: $0.count * MemoryLayout<Int32>.size)
                }
                type = .int32
            }
            backing.append(data)
            values[name] = try ORTValue(tensorData: data, elementType: type,
                                        shape: tensor.shape.map { NSNumber(value: $0) })
        }
        return (values, backing)
    }

    /// Runs a graph with any number of named inputs and outputs.
    func run(inputs: [String: PPTensor], outputNames wanted: [String]) throws -> [String: PPTensor] {
        do {
            // ONNX Runtime does not copy the input buffers, so every one of them
            // has to stay alive until `run` returns.
            let (values, backing) = try Self.values(inputs)

            let outputs = try session.run(withInputs: values,
                                          outputNames: Set(wanted),
                                          runOptions: nil)
            withExtendedLifetime(backing) {}

            var result: [String: PPTensor] = [:]
            for name in wanted {
                guard let value = outputs[name] else {
                    throw PPOCRError.inferenceFailed(String(localized: "The model returned no output \(name)"))
                }
                result[name] = try Self.read(value, name: name)
            }
            return result
        } catch let error as PPOCRError {
            throw error
        } catch {
            throw PPOCRError.inferenceFailed(error.localizedDescription)
        }
    }

    /// `value` is borrowed for the whole call, which keeps the tensor bytes
    /// `tensorData()` points at alive while they are copied out.
    static func read(_ value: ORTValue, name: String) throws -> PPTensor {
        let info = try value.tensorTypeAndShapeInfo()
        let shape = info.shape.map(\.intValue)
        let count = shape.reduce(1, *)
        let raw = try value.tensorData()

        switch info.elementType {
        case .float:
            guard raw.length >= count * MemoryLayout<Float>.size else {
                throw PPOCRError.unexpectedOutputShape(String(localized: "\(name): expected \(count) floats, got \(raw.length) bytes"))
            }
            return .float(elements(raw, count: count, of: Float.self), shape: shape)
        case .int32:
            guard raw.length >= count * MemoryLayout<Int32>.size else {
                throw PPOCRError.unexpectedOutputShape(String(localized: "\(name): expected \(count) int32 values, got \(raw.length) bytes"))
            }
            return .int32(elements(raw, count: count, of: Int32.self), shape: shape)
        case .int64:
            // Paddle exports sometimes widen indices to int64; narrow them so
            // callers only ever deal with one integer type.
            guard raw.length >= count * MemoryLayout<Int64>.size else {
                throw PPOCRError.unexpectedOutputShape(String(localized: "\(name): expected \(count) int64 values, got \(raw.length) bytes"))
            }
            let wide = elements(raw, count: count, of: Int64.self)
            return .int32(wide.map { Int32(truncatingIfNeeded: $0) }, shape: shape)
        default:
            throw PPOCRError.unexpectedOutputShape(String(localized: "\(name): unsupported output element type \(info.elementType.rawValue)"))
        }
    }

    /// Copies `count` elements straight out of a tensor's bytes. Reading the
    /// `NSMutableData` in place, rather than bridging it to `Data` first,
    /// saves a second copy of every output.
    private static func elements<T: BitwiseCopyable>(_ data: NSData, count: Int, of _: T.Type) -> [T] {
        [T](unsafeUninitializedCapacity: count) { buffer, initialized in
            if count > 0 {
                UnsafeMutableRawPointer(buffer.baseAddress!)
                    .copyMemory(from: data.bytes, byteCount: count * MemoryLayout<T>.stride)
            }
            initialized = count
        }
    }
}
