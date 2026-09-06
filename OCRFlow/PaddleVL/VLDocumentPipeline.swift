import Foundation
import CoreGraphics

/// The result of parsing one page.
struct VLDocument {
    /// Blocks in reading order, each with the text the VLM read out of it.
    var blocks: [PPLayoutBlock] = []
    var markdown: String = ""
    var plainText: String = ""
}

/// The complete PaddleOCR-VL pipeline: layout analysis, then per-block
/// recognition, then reassembly.
///
/// Running the VLM over a whole page in one shot is much faster but quietly
/// loses content — on a Korean poster it skipped the title and the opening
/// paragraphs entirely — which is exactly why PaddleOCR ships the layout stage
/// and why its docs insist the two are used together.
struct VLDocumentPipeline {
    let layout: PPLayoutDetector?
    let vl: VLEngine

    /// Reports overall progress and a short description of the current step.
    typealias ProgressHandler = (Double, String) -> Void

    func parse(image: CGImage,
               config: VLConfig,
               progress: ProgressHandler? = nil,
               isCancelled: (() -> Bool)? = nil) throws -> VLDocument {

        guard config.useLayoutDetection, let layout else {
            return try parseWholeImage(image, config: config,
                                       progress: progress, isCancelled: isCancelled)
        }

        progress?(0.05, "版面分析中…")
        guard let buffer = PPImageBuffer(cgImage: image) else {
            throw VLError.imageDecodeFailed
        }
        var blocks = try layout.detect(buffer)
            .reclassifyingFalsePageFurniture(pageHeight: CGFloat(buffer.height))
        guard !blocks.isEmpty else {
            // A page the layout model finds nothing in is still worth reading;
            // fall back rather than returning an empty document.
            return try parseWholeImage(image, config: config,
                                       progress: progress, isCancelled: isCancelled)
        }

        // Everything readable is read, headers and page numbers included. What
        // becomes of them is a question about the document, answered later by
        // 保留页眉页脚 — and answered again the moment the user changes their
        // mind, which is only possible because the text is already there.
        let recognisable = blocks.indices.filter { blocks[$0].label.vlTask != nil }

        // Layout is a fraction of a second; the VLM calls are the whole cost,
        // so the bar tracks blocks rather than stages.
        let total = Double(max(recognisable.count, 1))
        for (position, index) in recognisable.enumerated() {
            if isCancelled?() == true { break }
            guard let task = blocks[index].label.vlTask else { continue }

            progress?(0.1 + 0.9 * Double(position) / total,
                      "识别第 \(position + 1)/\(recognisable.count) 块（\(blocks[index].label.label)）")

            blocks[index].text = try vl.recognize(image: image,
                                                  crop: blocks[index].rect,
                                                  task: task,
                                                  isCancelled: isCancelled)
        }
        progress?(1.0, "完成")

        // Assembled without dropping anything: the caller re-assembles from
        // `blocks` with the user's current preference.
        return VLDocument(
            blocks: blocks,
            markdown: PPDocumentAssembler.markdown(from: blocks, dropPageFurniture: false),
            plainText: PPDocumentAssembler.plainText(from: blocks, dropPageFurniture: false))
    }

    /// `use_layout_detection=False`: the whole page, one prompt, one pass.
    private func parseWholeImage(_ image: CGImage,
                                 config: VLConfig,
                                 progress: ProgressHandler?,
                                 isCancelled: (() -> Bool)?) throws -> VLDocument {
        progress?(0.1, "识别整页…")
        let text = try vl.recognize(image: image,
                                    task: config.wholeImageTask,
                                    isCancelled: isCancelled)
        progress?(1.0, "完成")
        return VLDocument(blocks: [], markdown: text, plainText: text)
    }
}
