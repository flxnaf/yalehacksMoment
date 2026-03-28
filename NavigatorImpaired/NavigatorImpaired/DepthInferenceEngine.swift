import CoreML
import Vision
import UIKit
import Accelerate

struct DepthResult {
    let colorized: UIImage
    let depthMap: [Float]   // normalized 0=far, 1=near, row-major
    let mapWidth: Int
    let mapHeight: Int
}

final class DepthInferenceEngine {
    private(set) var isLoaded = false
    private(set) var loadError: String?
    /// Human-readable label for the currently active compute backend.
    private(set) var computeLabel: String = ""

    // Thread-safe model access: inference runs on a background task;
    // upgradeToANE() swaps the model from another background task.
    private let modelLock = NSLock()
    private var _vnModel: VNCoreMLModel?
    private var safeModel: VNCoreMLModel? {
        modelLock.withLock { _vnModel }
    }

    // MARK: - Load (two-phase)

    /// Phase 1 — loads CPU+GPU model (~5 s). Returns immediately once ready so
    /// inference can start while the ANE upgrade runs concurrently.
    func loadFast() {
        guard let url = modelURL() else { loadError = "Model not found in bundle."; return }
        if let vn = tryLoad(url: url, units: .cpuAndGPU, label: "GPU") { install(vn, label: "GPU") }
        else if let vn = tryLoad(url: url, units: .cpuOnly, label: "CPU") { install(vn, label: "CPU") }
    }

    /// Phase 2 — compiles and installs the ANE model (~55 s extra, first launch only).
    /// Hot-swaps the running model; inference keeps going throughout.
    func upgradeToANE() {
        guard let url = modelURL() else { return }
        if let vn = tryLoad(url: url, units: .all, label: "ANE") { install(vn, label: "ANE") }
        else if let vn = tryLoad(url: url, units: .cpuAndNeuralEngine, label: "ANE-lite") {
            install(vn, label: "ANE-lite")
        }
    }

    // MARK: - Private helpers

    private func modelURL() -> URL? {
        // Must match the .mlpackage name in the NavigatorImpaired target (repo includes ANE variant).
        // For Float16 from Hugging Face instead, add DepthAnythingV2SmallF16.mlpackage to the target and set name to "DepthAnythingV2SmallF16".
        let name = "DepthAnythingV2SmallANE"
        return Bundle.main.url(forResource: name, withExtension: "mlmodelc")
            ?? Bundle.main.url(forResource: name, withExtension: "mlpackage")
    }

    private func tryLoad(url: URL, units: MLComputeUnits, label: String) -> VNCoreMLModel? {
        print("[DepthEngine] 🔄 Loading \(label)…")
        let config = MLModelConfiguration()
        config.computeUnits = units
        var result: MLModel?
        var err: Error?
        let sema = DispatchSemaphore(value: 0)
        let t0 = CACurrentMediaTime()
        Task {
            do { result = try await MLModel.load(contentsOf: url, configuration: config) }
            catch { err = error }
            sema.signal()
        }
        sema.wait()
        let elapsed = CACurrentMediaTime() - t0
        if let e = err {
            print("[DepthEngine] ❌ \(label) failed (\(String(format:"%.1fs",elapsed))): \(e.localizedDescription)")
            return nil
        }
        guard let m = result else { return nil }
        print("[DepthEngine] ✅ \(label) ready in \(String(format:"%.1fs",elapsed))")
        return try? VNCoreMLModel(for: m)
    }

    private func install(_ vn: VNCoreMLModel, label: String) {
        modelLock.withLock { _vnModel = vn }
        computeLabel = label
        isLoaded = true
        loadError = nil
    }

    // MARK: - Infer

    private var frameCount = 0

    func infer(image: UIImage) throws -> (DepthResult, Double) {
        guard let vnModel = safeModel else { throw InferError.notLoaded }
        frameCount += 1
        let logThis = (frameCount % 30 == 1) // log every 30th frame to avoid spam

        // T0: CGImage extraction
        let tStart = CACurrentMediaTime()
        guard let cgImage = image.cgImage else { throw InferError.badInput }
        let originalSize = CGSize(width: cgImage.width, height: cgImage.height)
        let tCG = (CACurrentMediaTime() - tStart) * 1000

        var rawVals: [Float]?
        var rawW = 0, rawH = 0
        var outputType = "none"
        var outputFmt: OSType = 0
        var extractMs = 0.0

        let request = VNCoreMLRequest(model: vnModel) { req, _ in
            let tEx = CACurrentMediaTime()
            if let obs = req.results?.first as? VNPixelBufferObservation {
                outputFmt = CVPixelBufferGetPixelFormatType(obs.pixelBuffer)
                outputType = "PixelBuffer fmt=\(outputFmt)"
                (rawVals, rawW, rawH) = Self.extractVals(obs.pixelBuffer)
            } else if let obs = req.results?.first as? VNCoreMLFeatureValueObservation,
                      let multi = obs.featureValue.multiArrayValue {
                outputType = "MLMultiArray shape=\(multi.shape) dtype=\(multi.dataType.rawValue)"
                (rawVals, rawW, rawH) = Self.extractValsArray(multi)
            } else {
                outputType = "unknown: \(String(describing: req.results?.first))"
            }
            extractMs = (CACurrentMediaTime() - tEx) * 1000
        }
        request.imageCropAndScaleOption = .scaleFill

        // T1: Vision inference
        let tInfer = CACurrentMediaTime()
        try VNImageRequestHandler(cgImage: cgImage, options: [:]).perform([request])
        let inferMs = (CACurrentMediaTime() - tInfer) * 1000

        guard let vals = rawVals, rawW > 0 else { throw InferError.noOutput }

        // T2: Normalize
        let tNorm = CACurrentMediaTime()
        var v = vals
        var mn = Float.greatestFiniteMagnitude, mx = -Float.greatestFiniteMagnitude
        vDSP_minv(v, 1, &mn, vDSP_Length(v.count))
        vDSP_maxv(v, 1, &mx, vDSP_Length(v.count))
        let range = mx - mn
        if range > 1e-6 {
            var neg = -mn; vDSP_vsadd(v, 1, &neg, &v, 1, vDSP_Length(v.count))
            var inv = 1.0 / range; vDSP_vsmul(v, 1, &inv, &v, 1, vDSP_Length(v.count))
        }
        let normMs = (CACurrentMediaTime() - tNorm) * 1000

        // T3: LUT colorize
        let tLUT = CACurrentMediaTime()
        var rgba = [UInt8](repeating: 255, count: rawW * rawH * 4)
        for i in 0..<rawW * rawH {
            let entry = Self.lut[Int(v[i] * 255.0)]
            rgba[i*4] = entry.r; rgba[i*4+1] = entry.g; rgba[i*4+2] = entry.b
        }
        let lutMs = (CACurrentMediaTime() - tLUT) * 1000

        // T4: CGContext → UIImage
        let tCGCtx = CACurrentMediaTime()
        let ctx = CGContext(data: &rgba, width: rawW, height: rawH,
                            bitsPerComponent: 8, bytesPerRow: rawW * 4,
                            space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        guard let cg = ctx?.makeImage() else { throw InferError.noOutput }
        let colorImg = UIImage(cgImage: cg)
        let cgCtxMs = (CACurrentMediaTime() - tCGCtx) * 1000

        // T5: Resize to camera resolution
        let tResize = CACurrentMediaTime()
        let colorized = Self.resize(colorImg, to: originalSize) ?? colorImg
        let resizeMs = (CACurrentMediaTime() - tResize) * 1000

        let totalMs = (CACurrentMediaTime() - tStart) * 1000

        if logThis {
            print("""
[DepthEngine] ── frame \(frameCount) breakdown ──────────────────
  input:    \(Int(originalSize.width))×\(Int(originalSize.height)) → model: \(rawW)×\(rawH)
  output:   \(outputType)
  cgImage:  \(String(format:"%.2f",tCG))ms
  inference:\(String(format:"%.2f",inferMs))ms  (extract inside: \(String(format:"%.2f",extractMs))ms)
  normalize:\(String(format:"%.2f",normMs))ms
  LUT map:  \(String(format:"%.2f",lutMs))ms  (\(rawW*rawH) pixels)
  CGCtx:    \(String(format:"%.2f",cgCtxMs))ms
  resize:   \(String(format:"%.2f",resizeMs))ms
  TOTAL:    \(String(format:"%.2f",totalMs))ms
─────────────────────────────────────────────────
""")
        }

        return (DepthResult(colorized: colorized, depthMap: v, mapWidth: rawW, mapHeight: rawH), inferMs)
    }

    // MARK: - Extract raw float values from model output

    private static func extractVals(_ pb: CVPixelBuffer) -> ([Float], Int, Int) {
        CVPixelBufferLockBaseAddress(pb, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        let w = CVPixelBufferGetWidth(pb)
        let h = CVPixelBufferGetHeight(pb)
        guard let base = CVPixelBufferGetBaseAddress(pb) else { return ([], w, h) }
        let rowBytes = CVPixelBufferGetBytesPerRow(pb)
        let fmt = CVPixelBufferGetPixelFormatType(pb)
        var vals = [Float](repeating: 0, count: w * h)

        switch fmt {
        case kCVPixelFormatType_OneComponent8:
            let ptr = base.assumingMemoryBound(to: UInt8.self)
            for y in 0..<h { for x in 0..<w { vals[y*w+x] = Float(ptr[y*rowBytes+x]) / 255.0 } }
        case kCVPixelFormatType_OneComponent32Float:
            let ptr = base.assumingMemoryBound(to: Float.self)
            let rw = rowBytes / 4
            for y in 0..<h { for x in 0..<w { vals[y*w+x] = ptr[y*rw+x] } }
        case kCVPixelFormatType_OneComponent16Half:
            var f16 = [UInt16](repeating: 0, count: w * h)
            let ptr = base.assumingMemoryBound(to: UInt16.self)
            let rw = rowBytes / 2
            for y in 0..<h { for x in 0..<w { f16[y*w+x] = ptr[y*rw+x] } }
            var src = vImage_Buffer(data: &f16, height: 1, width: UInt(w*h), rowBytes: w*h*2)
            var dst = vImage_Buffer(data: &vals, height: 1, width: UInt(w*h), rowBytes: w*h*4)
            vImageConvert_Planar16FtoPlanarF(&src, &dst, 0)
        default:
            // Fallback via CIImage grayscale
            let ci = CIImage(cvPixelBuffer: pb)
            if let cg = CIContext().createCGImage(ci, from: ci.extent) {
                vals = extractGray(from: cg, w: w, h: h)
            }
        }
        return (vals, w, h)
    }

    private static func extractValsArray(_ array: MLMultiArray) -> ([Float], Int, Int) {
        let shape = array.shape.map { $0.intValue }
        let (H, W): (Int, Int)
        switch shape.count {
        case 2: (H, W) = (shape[0], shape[1])
        case 3: (H, W) = (shape[1], shape[2])
        case 4: (H, W) = (shape[2], shape[3])
        default: return ([], 0, 0)
        }
        var vals = [Float](repeating: 0, count: H * W)
        let ptr = array.dataPointer
        if array.dataType == .float16 {
            var f16 = [UInt16](repeating: 0, count: H * W)
            memcpy(&f16, ptr, H * W * 2)
            var src = vImage_Buffer(data: &f16, height: 1, width: UInt(H*W), rowBytes: H*W*2)
            var dst = vImage_Buffer(data: &vals, height: 1, width: UInt(H*W), rowBytes: H*W*4)
            vImageConvert_Planar16FtoPlanarF(&src, &dst, 0)
        } else {
            let f32 = ptr.bindMemory(to: Float.self, capacity: H * W)
            vals = Array(UnsafeBufferPointer(start: f32, count: H * W))
        }
        return (vals, W, H)
    }

    // MARK: - Turbo colormap via precomputed LUT

    // 256-entry lookup table built once at first use — avoids 200K polynomial evaluations per frame
    private static let lut: [(r: UInt8, g: UInt8, b: UInt8)] = {
        (0..<256).map { i in
            let x = Float(i) / 255.0
            let r = 0.1357 + x*(4.5974 + x*(-42.3277 + x*(130.5816 + x*(-150.5433 + x*51.5858))))
            let g = 0.0914 + x*(2.1856 + x*(4.8052  + x*(-14.0741 + x*(14.3382  + x*(-5.3402)))))
            let b = 0.1067 + x*(7.5774 + x*(-64.4321 + x*(202.3656 + x*(-256.8508 + x*116.5837))))
            return (UInt8(max(0,min(255,r*255))), UInt8(max(0,min(255,g*255))), UInt8(max(0,min(255,b*255))))
        }
    }()


    // MARK: - Helpers

    private static func extractGray(from cgImage: CGImage, w: Int, h: Int) -> [Float] {
        guard let ctx = CGContext(data: nil, width: w, height: h,
                                  bitsPerComponent: 8, bytesPerRow: w,
                                  space: CGColorSpaceCreateDeviceGray(),
                                  bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return [] }
        ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let data = ctx.data else { return [] }
        let gray = data.bindMemory(to: UInt8.self, capacity: w * h)
        return (0..<w*h).map { Float(gray[$0]) / 255.0 }
    }

    // Shared Metal-backed CIContext — created once, reused every frame
    private static let ciCtx = CIContext(options: [
        .useSoftwareRenderer: false,
        .workingColorSpace: CGColorSpaceCreateDeviceRGB()
    ])

    private static func resize(_ image: UIImage, to size: CGSize) -> UIImage? {
        guard let cg = image.cgImage else { return nil }
        let scaleX = size.width  / CGFloat(cg.width)
        let scaleY = size.height / CGFloat(cg.height)
        let ci = CIImage(cgImage: cg)
            .transformed(by: CGAffineTransform(scaleX: scaleX, y: scaleY))
        guard let out = ciCtx.createCGImage(ci, from: ci.extent) else { return nil }
        return UIImage(cgImage: out)
    }

    enum InferError: Error { case notLoaded, badInput, noOutput }
}
