import CoreML
import Vision
import UIKit
import Accelerate

final class DepthInferenceEngine {
    private(set) var isLoaded = false
    private(set) var loadError: String?
    private var vnModel: VNCoreMLModel?

    func load() {
        let name = "DepthAnythingV2SmallF16"
        guard let url = Bundle.main.url(forResource: name, withExtension: "mlmodelc")
                     ?? Bundle.main.url(forResource: name, withExtension: "mlpackage") else {
            loadError = "Model '\(name)' not found in bundle."
            return
        }

        for units in [MLComputeUnits.all, .cpuAndGPU, .cpuOnly] {
            let config = MLModelConfiguration()
            config.computeUnits = units
            do {
                let t0 = CACurrentMediaTime()
                let model = try MLModel(contentsOf: url, configuration: config)
                print("[DepthEngine] ✅ Loaded in \(String(format:"%.1fs", CACurrentMediaTime()-t0))")
                vnModel = try VNCoreMLModel(for: model)
                isLoaded = true
                return
            } catch {
                loadError = error.localizedDescription
            }
        }
    }

    func infer(image: UIImage) throws -> (UIImage, Double) {
        guard let vnModel else { throw InferError.notLoaded }
        guard let cgImage = image.cgImage else { throw InferError.badInput }

        var depthImage: UIImage?

        let request = VNCoreMLRequest(model: vnModel) { req, _ in
            if let obs = req.results?.first as? VNPixelBufferObservation {
                depthImage = Self.colorize(obs.pixelBuffer)
            } else if let obs = req.results?.first as? VNCoreMLFeatureValueObservation,
                      let multi = obs.featureValue.multiArrayValue {
                depthImage = Self.colorizeArray(multi)
            }
        }
        request.imageCropAndScaleOption = .scaleFill

        let t0 = CACurrentMediaTime()
        try VNImageRequestHandler(cgImage: cgImage, options: [:]).perform([request])
        let elapsed = (CACurrentMediaTime() - t0) * 1000

        guard var result = depthImage else { throw InferError.noOutput }

        // Resize depth to match input dimensions so the overlay aligns perfectly
        let targetSize = CGSize(width: cgImage.width, height: cgImage.height)
        if result.size != targetSize, let resized = Self.resize(result, to: targetSize) {
            result = resized
        }

        return (result, elapsed)
    }

    // MARK: - Colorize from pixel buffer (grayscale float or uint8)

    private static func colorize(_ pixelBuffer: CVPixelBuffer) -> UIImage? {
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }

        let w = CVPixelBufferGetWidth(pixelBuffer)
        let h = CVPixelBufferGetHeight(pixelBuffer)
        let fmt = CVPixelBufferGetPixelFormatType(pixelBuffer)
        guard let base = CVPixelBufferGetBaseAddress(pixelBuffer) else { return nil }
        let rowBytes = CVPixelBufferGetBytesPerRow(pixelBuffer)

        var vals = [Float](repeating: 0, count: w * h)

        if fmt == kCVPixelFormatType_OneComponent8 {
            let ptr = base.assumingMemoryBound(to: UInt8.self)
            for y in 0..<h {
                for x in 0..<w {
                    vals[y * w + x] = Float(ptr[y * rowBytes + x]) / 255.0
                }
            }
        } else if fmt == kCVPixelFormatType_OneComponent32Float {
            let ptr = base.assumingMemoryBound(to: Float.self)
            for y in 0..<h {
                let rowFloats = rowBytes / 4
                for x in 0..<w {
                    vals[y * w + x] = ptr[y * rowFloats + x]
                }
            }
        } else {
            // Fallback: treat as grayscale via CIImage
            let ci = CIImage(cvPixelBuffer: pixelBuffer)
            let ctx = CIContext()
            guard let cg = ctx.createCGImage(ci, from: ci.extent) else { return nil }
            return applyTurbo(to: cg, w: w, h: h)
        }

        return renderTurbo(vals, w: w, h: h)
    }

    private static func colorizeArray(_ array: MLMultiArray) -> UIImage? {
        let shape = array.shape.map { $0.intValue }
        let (H, W): (Int, Int)
        switch shape.count {
        case 2: (H, W) = (shape[0], shape[1])
        case 3: (H, W) = (shape[1], shape[2])
        default: return nil
        }

        var vals = [Float](repeating: 0, count: H * W)
        let ptr = array.dataPointer
        if array.dataType == .float16 {
            var f16 = [UInt16](repeating: 0, count: H * W)
            memcpy(&f16, ptr, H * W * 2)
            var src = vImage_Buffer(data: &f16, height: 1, width: UInt(H * W), rowBytes: H * W * 2)
            var dst = vImage_Buffer(data: &vals, height: 1, width: UInt(H * W), rowBytes: H * W * 4)
            vImageConvert_Planar16FtoPlanarF(&src, &dst, 0)
        } else {
            let f32 = ptr.bindMemory(to: Float.self, capacity: H * W)
            vals = Array(UnsafeBufferPointer(start: f32, count: H * W))
        }
        return renderTurbo(vals, w: W, h: H)
    }

    // MARK: - Turbo rendering

    private static func renderTurbo(_ vals: [Float], w: Int, h: Int) -> UIImage? {
        var v = vals
        var mn = Float.greatestFiniteMagnitude, mx = -Float.greatestFiniteMagnitude
        vDSP_minv(v, 1, &mn, vDSP_Length(v.count))
        vDSP_maxv(v, 1, &mx, vDSP_Length(v.count))
        let range = mx - mn
        if range > 1e-6 {
            var neg = -mn
            vDSP_vsadd(v, 1, &neg, &v, 1, vDSP_Length(v.count))
            var inv = 1.0 / range
            vDSP_vsmul(v, 1, &inv, &v, 1, vDSP_Length(v.count))
        }

        var rgba = [UInt8](repeating: 255, count: w * h * 4)
        for i in 0..<w * h {
            let (r, g, b) = turbo(v[i])
            rgba[i*4] = r; rgba[i*4+1] = g; rgba[i*4+2] = b
        }
        let ctx = CGContext(data: &rgba, width: w, height: h,
                            bitsPerComponent: 8, bytesPerRow: w * 4,
                            space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        guard let cg = ctx?.makeImage() else { return nil }
        return UIImage(cgImage: cg)
    }

    private static func applyTurbo(to cgImage: CGImage, w: Int, h: Int) -> UIImage? {
        guard let ctx = CGContext(data: nil, width: w, height: h,
                                  bitsPerComponent: 8, bytesPerRow: w,
                                  space: CGColorSpaceCreateDeviceGray(),
                                  bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return nil }
        ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let data = ctx.data else { return nil }
        let gray = data.bindMemory(to: UInt8.self, capacity: w * h)
        let vals = (0..<w*h).map { Float(gray[$0]) / 255.0 }
        return renderTurbo(vals, w: w, h: h)
    }

    private static func turbo(_ t: Float) -> (UInt8, UInt8, UInt8) {
        let x = max(0, min(1, t))
        let r = 0.1357 + x*(4.5974 + x*(-42.3277 + x*(130.5816 + x*(-150.5433 + x*51.5858))))
        let g = 0.0914 + x*(2.1856 + x*(4.8052  + x*(-14.0741 + x*(14.3382  + x*(-5.3402)))))
        let b = 0.1067 + x*(7.5774 + x*(-64.4321 + x*(202.3656 + x*(-256.8508 + x*116.5837))))
        return (UInt8(max(0,min(255,r*255))), UInt8(max(0,min(255,g*255))), UInt8(max(0,min(255,b*255))))
    }

    private static func resize(_ image: UIImage, to size: CGSize) -> UIImage? {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: size, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
        }
    }

    enum InferError: Error { case notLoaded, badInput, noOutput }
}
