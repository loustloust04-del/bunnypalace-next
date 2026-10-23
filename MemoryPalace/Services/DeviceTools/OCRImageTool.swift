import Foundation
import Vision
import ImageIO

/// ocr_image：对文件库/附件里的图片做 Vision OCR。输入是用户已给的图 → 不新增隐私域（归 toolsMaster）。
/// 修 Minis 档案里的坑：传 CGImagePropertyOrientation（EXIF 方向）；bbox 归一化且原点左下——描述里写明。
enum OCRImageTool {
    static let toolName = "ocr_image"

    static var definition: ToolDefinition {
        ToolDefinition(
            name: toolName,
            description: "识别一张图片里的文字（Vision OCR，端上运行）。path = 文件库相对路径或附件路径（clipboard_read 返回的 path 也可以）。返回全文 + 逐行块（confidence，bbox 为归一化坐标、原点左下）。",
            properties: [
                "path": ["type": "string"],
                "languages": ["type": "array", "items": ["type": "string"], "description": "识别语言优先级，默认 [\"zh-Hans\",\"en\"]"],
            ],
            required: ["path"]
        )
    }

    static func execute(args: [String: Any], profileId: String) async -> DeviceToolExec {
        guard let path = DeviceToolIO.str(args, "path") else { return DeviceToolIO.fail("missing_param", "缺 path") }
        guard let data = try? FileLibraryStore.readData(path, profileId: profileId) else {
            return DeviceToolIO.fail("not_found", "找不到文件：\(path)")
        }
        guard let src = CGImageSourceCreateWithData(data as CFData, nil),
              let cg = CGImageSourceCreateImageAtIndex(src, 0, nil) else {
            return DeviceToolIO.fail("invalid_param", "不是可解码的图片：\(path)")
        }
        let orientation = exifOrientation(src)
        let langs = (args["languages"] as? [String]).flatMap { $0.isEmpty ? nil : $0 } ?? ["zh-Hans", "en"]

        let result: [VNRecognizedTextObservation]? = await DeviceToolIO.withTimeout(seconds: 30) {
            await withCheckedContinuation { (c: CheckedContinuation<[VNRecognizedTextObservation], Never>) in
                let req = VNRecognizeTextRequest { r, _ in c.resume(returning: (r.results as? [VNRecognizedTextObservation]) ?? []) }
                req.recognitionLevel = .accurate
                req.usesLanguageCorrection = true
                req.recognitionLanguages = langs
                let handler = VNImageRequestHandler(cgImage: cg, orientation: orientation, options: [:])
                DispatchQueue.global(qos: .userInitiated).async {
                    do { try handler.perform([req]) } catch { c.resume(returning: []) }
                }
            }
        }
        guard let obs = result else { return DeviceToolIO.fail("timeout", "OCR 超时（30s）") }
        let blocks: [[String: Any]] = obs.compactMap { o in
            guard let top = o.topCandidates(1).first else { return nil }
            let b = o.boundingBox
            return ["text": top.string, "confidence": Double(round(top.confidence * 100) / 100),
                    "bbox": [b.minX, b.minY, b.width, b.height].map { Double(round($0 * 1000) / 1000) }]
        }
        let fullText = blocks.map { $0["text"] as? String ?? "" }.joined(separator: "\n")
        let preview = fullText.split(separator: "\n").prefix(2).joined(separator: " / ")
        return DeviceToolIO.ok([
            "text": fullText,
            "blocks": blocks,
            "image": ["width": cg.width, "height": cg.height],
        ], card: DeviceToolIO.card(
            type: "ocr",
            title: blocks.isEmpty ? "没识别到文字" : "识别到 \(blocks.count) 行",
            subtitle: preview.isEmpty ? nil : String(preview.prefix(60)),
            icon: "text.viewfinder",
            imagePath: path
        ))
    }

    private static func exifOrientation(_ src: CGImageSource) -> CGImagePropertyOrientation {
        guard let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
              let raw = props[kCGImagePropertyOrientation] as? UInt32,
              let o = CGImagePropertyOrientation(rawValue: raw) else { return .up }
        return o
    }
}
