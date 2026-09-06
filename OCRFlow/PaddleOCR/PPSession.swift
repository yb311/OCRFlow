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

/// Thin wrapper over an ONNX Runtime session.
///
/// PP-OCR's detection, recognition and orientation graphs are all single-input
/// and single-output, which `run(input:shape:)` covers; the layout model takes
/// three inputs and returns three outputs, which is what `run(inputs:outputNames:)`
/// is for.
final class PPSession {
    private let session: ORTSession
    private let inputName: String
    private let outputName: String

    /// Every input and output the graph declares, in the order it declares them.
    let inputNames: [String]
    let outputNames: [String]

    init(modelPath: URL, env: ORTEnv, config: PPOCRConfig) throws {
        do {
            let options = try ORTSessionOptions()
            try options.setLogSeverityLevel(.error)
            try options.setGraphOptimizationLevel(.all)
            if config.threadCount > 0 {
                try options.setIntraOpNumThreads(Int32(config.threadCount))
            }
            if config.computeUnit == .coreML, ORTIsCoreMLExecutionProviderAvailable() {
                let coreML = ORTCoreMLExecutionProviderOptions()
                coreML.createMLProgram = true
                // The det and rec graphs have dynamic spatial dimensions; letting
                // Core ML claim only the static subgraphs and leaving the rest on
                // CPU is faster than forcing everything through one backend.
                coreML.enableOnSubgraphs = true
                try options.appendCoreMLExecutionProvider(with: coreML)
            }
            session = try ORTSession(env: env, modelPath: modelPath.path, sessionOptions: options)
            inputNames = try session.inputNames()
            outputNames = try session.outputNames()
            guard let input = inputNames.first, let output = outputNames.first else {
                throw PPOCRError.sessionFailed("模型 \(modelPath.lastPathComponent) 没有可用的输入/输出")
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
                throw PPOCRError.inferenceFailed("模型未返回输出 \(outputName)")
            }
            let info = try result.tensorTypeAndShapeInfo()
            let outShape = info.shape.map(\.intValue)
            let raw = try result.tensorData() as Data
            let count = outShape.reduce(1, *)
            guard raw.count >= count * MemoryLayout<Float>.size else {
                throw PPOCRError.unexpectedOutputShape("期望 \(count) 个浮点数，实际 \(raw.count) 字节")
            }
            var values = [Float](repeating: 0, count: count)
            _ = values.withUnsafeMutableBytes { dst in
                raw.copyBytes(to: dst, count: count * MemoryLayout<Float>.size)
            }
            // `data` backs the input tensor for the whole call; ONNX Runtime does
            // not copy it, so keep it alive until after `run` returns.
            withExtendedLifetime(data) {}
            return (values, outShape)
        } catch let error as PPOCRError {
            throw error
        } catch {
            throw PPOCRError.inferenceFailed(error.localizedDescription)
        }
    }

    /// Runs a graph with any number of named inputs and outputs.
    func run(inputs: [String: PPTensor], outputNames wanted: [String]) throws -> [String: PPTensor] {
        do {
            // ONNX Runtime does not copy the input buffers, so every one of them
            // has to stay alive until `run` returns.
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

            let outputs = try session.run(withInputs: values,
                                          outputNames: Set(wanted),
                                          runOptions: nil)
            withExtendedLifetime(backing) {}

            var result: [String: PPTensor] = [:]
            for name in wanted {
                guard let value = outputs[name] else {
                    throw PPOCRError.inferenceFailed("模型未返回输出 \(name)")
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

    private static func read(_ value: ORTValue, name: String) throws -> PPTensor {
        let info = try value.tensorTypeAndShapeInfo()
        let shape = info.shape.map(\.intValue)
        let count = shape.reduce(1, *)
        let raw = try value.tensorData() as Data

        switch info.elementType {
        case .float:
            guard raw.count >= count * MemoryLayout<Float>.size else {
                throw PPOCRError.unexpectedOutputShape("\(name)：期望 \(count) 个浮点数，实际 \(raw.count) 字节")
            }
            var elements = [Float](repeating: 0, count: count)
            _ = elements.withUnsafeMutableBytes { raw.copyBytes(to: $0, count: count * MemoryLayout<Float>.size) }
            return .float(elements, shape: shape)
        case .int32:
            guard raw.count >= count * MemoryLayout<Int32>.size else {
                throw PPOCRError.unexpectedOutputShape("\(name)：期望 \(count) 个 int32，实际 \(raw.count) 字节")
            }
            var elements = [Int32](repeating: 0, count: count)
            _ = elements.withUnsafeMutableBytes { raw.copyBytes(to: $0, count: count * MemoryLayout<Int32>.size) }
            return .int32(elements, shape: shape)
        case .int64:
            // Paddle exports sometimes widen indices to int64; narrow them so
            // callers only ever deal with one integer type.
            guard raw.count >= count * MemoryLayout<Int64>.size else {
                throw PPOCRError.unexpectedOutputShape("\(name)：期望 \(count) 个 int64，实际 \(raw.count) 字节")
            }
            var wide = [Int64](repeating: 0, count: count)
            _ = wide.withUnsafeMutableBytes { raw.copyBytes(to: $0, count: count * MemoryLayout<Int64>.size) }
            return .int32(wide.map { Int32(truncatingIfNeeded: $0) }, shape: shape)
        default:
            throw PPOCRError.unexpectedOutputShape("\(name)：不支持的输出元素类型 \(info.elementType.rawValue)")
        }
    }
}
