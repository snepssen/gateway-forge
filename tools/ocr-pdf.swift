// OCR a scanned PDF with the system Vision framework. No dependencies -- the
// Gateway Intermediate Workbook is 21 pages of images, and pdftotext returns
// 21 characters from it.
//
//   swiftc -O tools/ocr-pdf.swift -o /tmp/ocr-pdf && /tmp/ocr-pdf in.pdf out.txt
import Foundation
import PDFKit
import Vision
import CoreGraphics

let args = CommandLine.arguments
guard args.count >= 3, let doc = PDFDocument(url: URL(fileURLWithPath: args[1])) else {
    FileHandle.standardError.write("usage: ocr-pdf <in.pdf> <out.txt>\n".data(using: .utf8)!)
    exit(2)
}
let scale: CGFloat = 2.0          // 144 dpi: enough for body text, cheap enough for 21 pages
var out = ""

for i in 0..<doc.pageCount {
    guard let page = doc.page(at: i) else { continue }
    let bounds = page.bounds(for: .mediaBox)
    let w = Int(bounds.width * scale), h = Int(bounds.height * scale)
    guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8,
                              bytesPerRow: 0, space: CGColorSpaceCreateDeviceGray(),
                              bitmapInfo: CGImageAlphaInfo.none.rawValue) else { continue }
    ctx.setFillColor(gray: 1, alpha: 1)
    ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
    ctx.scaleBy(x: scale, y: scale)
    ctx.translateBy(x: -bounds.origin.x, y: -bounds.origin.y)
    page.draw(with: .mediaBox, to: ctx)
    guard let image = ctx.makeImage() else { continue }

    let request = VNRecognizeTextRequest()
    request.recognitionLevel = .accurate
    request.usesLanguageCorrection = true
    request.recognitionLanguages = ["en-US"]
    let handler = VNImageRequestHandler(cgImage: image, options: [:])
    do { try handler.perform([request]) } catch {
        FileHandle.standardError.write("page \(i + 1): \(error)\n".data(using: .utf8)!)
        continue
    }
    let lines = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
    out += "\n\n## Page \(i + 1)\n\n" + lines.joined(separator: "\n")
    FileHandle.standardError.write("page \(i + 1)/\(doc.pageCount): \(lines.count) lines\n"
        .data(using: .utf8)!)
}
try out.trimmingCharacters(in: .whitespacesAndNewlines)
    .write(to: URL(fileURLWithPath: args[2]), atomically: true, encoding: .utf8)
