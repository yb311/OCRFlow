import Foundation
import CoreGraphics

/// The complete PaddleOCR-VL pipeline: layout analysis, then per-block
/// recognition, then reassembly.
///
/// Running the VLM over a whole page in one shot is much faster but quietly
/// loses content — on a Korean poster it skipped the title and the opening
/// paragraphs entirely — which is exactly why PaddleOCR ships the layout stage
/// and why its docs insist the two are used together.
///
/// Every region of a page is handed to the engine in one go and decoded side
/// by side; see `VLEngine`.
struct VLDocumentPipeline {
    let layout: PPLayoutDetector?
    let vl: VLEngine

    func parse(image: CGImage,
               config: VLConfig,
               progress: ((Double) -> Void)? = nil,
               isCancelled: @escaping () -> Bool = { false }) throws -> PageResult {
        let size = CGSize(width: image.width, height: image.height)
        guard config.useLayoutDetection, let layout else {
            return try parseWholeImage(image, config: config, progress: progress,
                                       isCancelled: isCancelled)
        }

        progress?(0.05)
        guard let buffer = PPImageBuffer(cgImage: image) else {
            throw VLError.imageDecodeFailed
        }
        var blocks = try layout.detect(buffer)
            .reclassifyingFalsePageFurniture(pageHeight: CGFloat(buffer.height))
        guard !blocks.isEmpty else {
            // A page the layout model finds nothing in is still worth reading;
            // fall back rather than returning an empty document.
            return try parseWholeImage(image, config: config, progress: progress,
                                       isCancelled: isCancelled)
        }

        // Everything readable is read, headers and page numbers included. What
        // becomes of them is a question about the document, answered later by
        // 保留页眉页脚 — and answered again the moment the user changes their
        // mind, which is only possible because the text is already there.
        let regions = blocks.indices.compactMap { index -> RegionReader.Region? in
            task(for: blocks[index].label, config: config).map {
                RegionReader.Region(block: index, task: $0, fallback: nil, isEscalation: false)
            }
        }
        progress?(0.1)
        RegionReader.read(regions, of: image, blocks: &blocks, vl: vl, config: config,
                          progress: { progress?(0.1 + 0.9 * $0) }, isCancelled: isCancelled)
        progress?(1.0)

        return PageResult(size: size, blocks: blocks, blockSource: .visionLanguageModel)
    }

    /// The prompt for a region, or nil when the switches say to leave it alone.
    ///
    /// Mirrors PaddleOCR's own module switches: a chart is only transcribed
    /// when chart recognition is on — otherwise it is a picture, which is the
    /// reference default — and the same for seals and text inside figures.
    private func task(for label: PPLayoutLabel, config: VLConfig) -> VLTask? {
        switch label {
        case .chart:
            return config.useChartRecognition ? .chart : nil
        case .seal:
            return config.useSealRecognition ? .seal : nil
        case .image, .headerImage, .footerImage:
            return config.useImageTextRecognition ? .ocr : nil
        default:
            return label.vlTask
        }
    }

    /// `use_layout_detection=False`: the whole page, one prompt, one pass.
    private func parseWholeImage(_ image: CGImage,
                                 config: VLConfig,
                                 progress: ((Double) -> Void)?,
                                 isCancelled: @escaping () -> Bool) throws -> PageResult {
        progress?(0.1)
        let request = VLRequest(image: image, task: config.wholeImageTask)
        let output = try vl.recognize([request], isCancelled: isCancelled)[0].get()
        progress?(1.0)
        var page = PageResult(size: CGSize(width: image.width, height: image.height),
                              blockSource: .visionLanguageModel,
                              rawText: output.text, rawMarkdown: output.text)
        switch output.ending {
        case .lengthLimit:
            page.notes.append(.warning("整页输出达到 \(config.maxOutputTokens) token 上限，内容可能不完整"))
        case .repetition:
            page.notes.append(.warning("模型出现重复输出，已截断，可能漏读"))
        case .decodeFailed:
            page.notes.append(.warning("PaddleOCR-VL 推理中断，内容可能不完整"))
        case .finished, .cancelled:
            break
        }
        return page
    }
}
