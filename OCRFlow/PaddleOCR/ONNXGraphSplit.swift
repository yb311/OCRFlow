import Foundation

/// Just enough of the ONNX file format to cut a graph in two.
///
/// An ONNX model is a protocol buffer. Splitting one needs no schema
/// compiler: the fields involved — nodes, initialisers, inputs, outputs,
/// value infos — are length-delimited records that can be read, filtered
/// and copied as bytes, and nothing inside a node, a weight or a type is
/// re-encoded. The one exception is `MaxPool.ceil_mode`, rewritten where
/// it provably has no effect (see `split`).
enum ONNXGraphSplit {

    struct Halves {
        /// Everything before the cut: the part that runs on the GPU.
        var head: Data
        /// The rest, fed by the head's outputs and the graph's own inputs.
        var tail: Data
        /// The head's inputs, and for each the symbolic dimension names in
        /// declaration order (nil for a fixed dimension).
        var headInputDimensions: [String: [String?]]
    }

    enum Failure: Error {
        case malformed
        case anchorMissing(String)
        /// A node carries a subgraph (If, Loop, Scan), which a byte-level
        /// cut cannot follow.
        case subgraph
        /// A tensor crossing the cut has no recorded type, so it cannot be
        /// declared as an output of the head.
        case untypedBoundary(String)
        /// A `MaxPool` whose `ceil_mode` would matter: Core ML cannot build
        /// it, and rewriting it would change the arithmetic.
        case unsafePooling(String)
    }

    /// Cuts `model` just before the node named `anchor`.
    static func split(_ model: Data, before anchor: String) throws -> Halves {
        try model.withUnsafeBytes { raw -> Halves in
            let bytes = raw.bindMemory(to: UInt8.self)
            return try split(bytes, before: anchor)
        }
    }

    // MARK: - Splitting

    /// A piece of an output file: bytes copied from the source, or new ones.
    private enum Piece {
        case source(Range<Int>)
        case new([UInt8])
    }

    private struct Node {
        var piece: Piece
        var payload: Range<Int>
        var name: String
        var opType: String
        var inputs: [String]
        var outputs: [String]
    }

    private static func split(_ bytes: UnsafeBufferPointer<UInt8>, before anchor: String) throws -> Halves {
        let all = 0..<bytes.count
        var modelFields: [Range<Int>] = []
        var graphPayload: Range<Int>?
        for field in try Proto.fields(bytes, in: all) {
            if field.number == 7, field.wire == 2 { graphPayload = field.payload }
            else { modelFields.append(field.whole) }
        }
        guard let graphPayload else { throw Failure.malformed }

        var nodes: [Node] = []
        var initializers: [(name: String, whole: Range<Int>)] = []
        var inputs: [(name: String, whole: Range<Int>, payload: Range<Int>)] = []
        var outputs: [(name: String, whole: Range<Int>)] = []
        var valueInfos: [String: Range<Int>] = [:]
        var valueInfoPayloads: [String: Range<Int>] = [:]
        var otherGraphFields: [Range<Int>] = []

        for field in try Proto.fields(bytes, in: graphPayload) {
            let whole = field.whole
            switch (field.number, field.wire) {
            case (1, 2):
                nodes.append(try node(bytes, field.payload, whole: whole))
            case (5, 2):
                initializers.append((try Proto.string(bytes, field: 8, in: field.payload) ?? "", whole))
            case (11, 2):
                let name = try Proto.string(bytes, field: 1, in: field.payload) ?? ""
                inputs.append((name, whole, field.payload))
            case (12, 2):
                outputs.append((try Proto.string(bytes, field: 1, in: field.payload) ?? "", whole))
            case (13, 2):
                let name = try Proto.string(bytes, field: 1, in: field.payload) ?? ""
                valueInfos[name] = whole
                valueInfoPayloads[name] = field.payload
            default:
                otherGraphFields.append(whole)
            }
        }

        guard let cut = nodes.firstIndex(where: { $0.name == anchor }) else {
            throw Failure.anchorMissing(anchor)
        }
        var head = Array(nodes[..<cut])
        let tail = Array(nodes[cut...])
        for index in head.indices where head[index].opType == "MaxPool" {
            head[index].piece = try neutralisingCeilMode(bytes, node: head[index])
        }

        let producedByHead = Set(head.flatMap(\.outputs))
        let consumedByHead = Set(head.flatMap(\.inputs))
        let producedByTail = Set(tail.flatMap(\.outputs))
        let consumedByTail = Set(tail.flatMap(\.inputs))
        let boundary = producedByHead.intersection(consumedByTail).sorted()
        for name in boundary where valueInfos[name] == nil { throw Failure.untypedBoundary(name) }

        func graph(nodes: [Node], inputs: [Piece], outputs: [Piece],
                   consumed: Set<String>, produced: Set<String>, excludingInfo: Set<String>) -> [Piece] {
            var out: [Piece] = otherGraphFields.map(Piece.source)
            out += nodes.map(\.piece)
            out += initializers.filter { consumed.contains($0.name) }.map { .source($0.whole) }
            out += inputs + outputs
            for (name, info) in valueInfos.sorted(by: { $0.value.lowerBound < $1.value.lowerBound })
            where produced.contains(name) && !excludingInfo.contains(name) {
                out.append(.source(info))
            }
            return out
        }

        // Value-info records become the declarations of the tensors crossing
        // the cut: outputs on the head's side, inputs on the tail's.
        func retagged(_ name: String, as number: Int) -> Piece {
            .new(Proto.lengthDelimited(number, Array(Proto.slice(bytes, valueInfoPayloads[name]!))))
        }
        let headInputs = inputs.filter { consumedByHead.contains($0.name) }
        let headGraph = graph(nodes: head,
                              inputs: headInputs.map { .source($0.whole) },
                              outputs: boundary.map { retagged($0, as: 12) },
                              consumed: consumedByHead, produced: producedByHead,
                              excludingInfo: Set(boundary))
        let tailGraph = graph(nodes: tail,
                              inputs: boundary.map { retagged($0, as: 11) }
                                + inputs.filter { consumedByTail.contains($0.name) }.map { .source($0.whole) },
                              outputs: outputs.filter { producedByTail.contains($0.name) }.map { .source($0.whole) },
                              consumed: consumedByTail, produced: producedByTail,
                              excludingInfo: [])

        func size(_ piece: Piece) -> Int {
            switch piece {
            case let .source(range): return range.count
            case let .new(bytes): return bytes.count
            }
        }
        func append(_ piece: Piece, to out: inout Data) {
            switch piece {
            case let .source(range): out.append(UnsafeBufferPointer(rebasing: bytes[range]))
            case let .new(new): out.append(contentsOf: new)
            }
        }
        func model(_ graph: [Piece]) -> Data {
            let graphSize = graph.reduce(0) { $0 + size($1) }
            var out = Data()
            out.reserveCapacity(graphSize + modelFields.reduce(0) { $0 + $1.count } + 16)
            for field in modelFields { append(.source(field), to: &out) }
            out.append(contentsOf: Proto.tag(7, wire: 2) + Proto.varint(UInt64(graphSize)))
            for piece in graph { append(piece, to: &out) }
            return out
        }

        var dimensions: [String: [String?]] = [:]
        for input in headInputs {
            dimensions[input.name] = try symbolicDimensions(bytes, valueInfo: input.payload)
        }
        return Halves(head: model(headGraph), tail: model(tailGraph), headInputDimensions: dimensions)
    }

    private static func node(_ bytes: UnsafeBufferPointer<UInt8>, _ payload: Range<Int>,
                             whole: Range<Int>) throws -> Node {
        var node = Node(piece: .source(whole), payload: payload, name: "", opType: "", inputs: [], outputs: [])
        for field in try Proto.fields(bytes, in: payload) where field.wire == 2 {
            switch field.number {
            case 1:
                let name = Proto.text(bytes, field.payload)
                if !name.isEmpty { node.inputs.append(name) }
            case 2:
                let name = Proto.text(bytes, field.payload)
                if !name.isEmpty { node.outputs.append(name) }
            case 3: node.name = Proto.text(bytes, field.payload)
            case 4: node.opType = Proto.text(bytes, field.payload)
            case 5:
                // AttributeProto: g = 6, graphs = 11.
                for attribute in try Proto.fields(bytes, in: field.payload)
                where attribute.number == 6 || attribute.number == 11 {
                    throw Failure.subgraph
                }
            default: break
            }
        }
        return node
    }

    /// Core ML refuses a `MaxPool` with `ceil_mode` set and `SAME` padding.
    /// With a stride of one in every axis the output size is the input size
    /// whichever way it is rounded, so clearing the flag leaves the result
    /// untouched; any other stride is left alone and the split refused.
    private static func neutralisingCeilMode(_ bytes: UnsafeBufferPointer<UInt8>,
                                             node: Node) throws -> Piece {
        let nodeFields = try Proto.fields(bytes, in: node.payload)
        var ceilMode: UInt64 = 0
        var strides: [UInt64] = []
        for field in nodeFields where field.number == 5 && field.wire == 2 {
            let name = try Proto.string(bytes, field: 1, in: field.payload)
            if name == "ceil_mode" {
                ceilMode = try Proto.fields(bytes, in: field.payload)
                    .first { $0.number == 3 && $0.wire == 0 }?.varint ?? 0
            } else if name == "strides" {
                for value in try Proto.fields(bytes, in: field.payload) where value.number == 8 {
                    if value.wire == 0 { strides.append(value.varint) }
                    else if value.wire == 2 { strides += try Proto.packedVarints(bytes, value.payload) }
                }
            }
        }
        guard ceilMode != 0 else { return node.piece }
        guard !strides.isEmpty, strides.allSatisfy({ $0 == 1 }) else { throw Failure.unsafePooling(node.name) }

        var payload: [UInt8] = []
        for field in nodeFields {
            if field.number == 5, field.wire == 2,
               try Proto.string(bytes, field: 1, in: field.payload) == "ceil_mode" {
                var attribute: [UInt8] = []
                for part in try Proto.fields(bytes, in: field.payload) where !(part.number == 3 && part.wire == 0) {
                    attribute += Proto.slice(bytes, part.whole)
                }
                attribute += Proto.tag(3, wire: 0) + Proto.varint(0)
                payload += Proto.lengthDelimited(5, attribute)
            } else {
                payload += Proto.slice(bytes, field.whole)
            }
        }
        return .new(Proto.lengthDelimited(1, payload))
    }

    /// ValueInfoProto → type (2) → tensor_type (1) → shape (2) → dim (1)
    /// → dim_value (1) or dim_param (2).
    private static func symbolicDimensions(_ bytes: UnsafeBufferPointer<UInt8>,
                                           valueInfo: Range<Int>) throws -> [String?] {
        func child(_ number: Int, of range: Range<Int>) throws -> Range<Int>? {
            try Proto.fields(bytes, in: range).first { $0.number == number && $0.wire == 2 }?.payload
        }
        guard let type = try child(2, of: valueInfo),
              let tensor = try child(1, of: type),
              let shape = try child(2, of: tensor) else { return [] }
        return try Proto.fields(bytes, in: shape).filter { $0.number == 1 && $0.wire == 2 }.map { dim in
            try Proto.string(bytes, field: 2, in: dim.payload)
        }
    }
}

// MARK: - Protocol buffer wire format

private enum Proto {
    struct Field {
        var number: Int
        var wire: Int
        /// Tag and payload together.
        var whole: Range<Int>
        /// The bytes of a length-delimited field.
        var payload: Range<Int>
        var varint: UInt64
    }

    static func fields(_ bytes: UnsafeBufferPointer<UInt8>, in range: Range<Int>) throws -> [Field] {
        var fields: [Field] = []
        var position = range.lowerBound
        while position < range.upperBound {
            let start = position
            let key = try readVarint(bytes, &position, limit: range.upperBound)
            let number = Int(key >> 3), wire = Int(key & 7)
            var payload = position..<position
            var value: UInt64 = 0
            switch wire {
            case 0: value = try readVarint(bytes, &position, limit: range.upperBound)
            case 1: position += 8
            case 2:
                // Checked before any arithmetic: a corrupt length would
                // otherwise trap converting to `Int` or overflow the sum.
                let length = try readVarint(bytes, &position, limit: range.upperBound)
                guard length <= UInt64(range.upperBound - position) else {
                    throw ONNXGraphSplit.Failure.malformed
                }
                payload = position..<(position + Int(length))
                position = payload.upperBound
            case 5: position += 4
            default: throw ONNXGraphSplit.Failure.malformed
            }
            guard position <= range.upperBound else { throw ONNXGraphSplit.Failure.malformed }
            fields.append(Field(number: number, wire: wire, whole: start..<position,
                                payload: payload, varint: value))
        }
        return fields
    }

    static func readVarint(_ bytes: UnsafeBufferPointer<UInt8>, _ position: inout Int, limit: Int) throws -> UInt64 {
        var result: UInt64 = 0
        var shift: UInt64 = 0
        while position < limit, shift < 64 {
            let byte = bytes[position]
            position += 1
            result |= UInt64(byte & 0x7F) << shift
            if byte & 0x80 == 0 { return result }
            shift += 7
        }
        throw ONNXGraphSplit.Failure.malformed
    }

    static func packedVarints(_ bytes: UnsafeBufferPointer<UInt8>, _ range: Range<Int>) throws -> [UInt64] {
        var position = range.lowerBound
        var values: [UInt64] = []
        while position < range.upperBound {
            values.append(try readVarint(bytes, &position, limit: range.upperBound))
        }
        return values
    }

    static func slice(_ bytes: UnsafeBufferPointer<UInt8>, _ range: Range<Int>) -> ArraySlice<UInt8> {
        ArraySlice(UnsafeBufferPointer(rebasing: bytes[range]))
    }

    static func text(_ bytes: UnsafeBufferPointer<UInt8>, _ range: Range<Int>) -> String {
        String(decoding: UnsafeBufferPointer(rebasing: bytes[range]), as: UTF8.self)
    }

    static func string(_ bytes: UnsafeBufferPointer<UInt8>, field number: Int, in range: Range<Int>) throws -> String? {
        try fields(bytes, in: range).first { $0.number == number && $0.wire == 2 }.map { text(bytes, $0.payload) }
    }

    static func varint(_ value: UInt64) -> [UInt8] {
        var value = value
        var out: [UInt8] = []
        repeat {
            var byte = UInt8(value & 0x7F)
            value >>= 7
            if value != 0 { byte |= 0x80 }
            out.append(byte)
        } while value != 0
        return out
    }

    static func tag(_ number: Int, wire: Int) -> [UInt8] {
        varint(UInt64(number << 3 | wire))
    }

    static func lengthDelimited(_ number: Int, _ payload: [UInt8]) -> [UInt8] {
        tag(number, wire: 2) + varint(UInt64(payload.count)) + payload
    }
}
