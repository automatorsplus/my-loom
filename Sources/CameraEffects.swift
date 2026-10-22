import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins
import Vision

/// What's shown behind you in the camera picture: Loom's three kinds of background effect (blur,
/// an image, a colour), with MyLoom's own built-in scenes in place of Loom's bundled photos.
enum CameraBackground: Equatable {
    case none
    case blur
    case scene(Scene)
    case color(red: Double, green: Double, blue: Double)
    case image(URL)

    /// Backgrounds drawn in code, so MyLoom ships no image files.
    enum Scene: String, CaseIterable {
        case studio, ocean, sunset, bokeh

        var title: String {
            switch self {
            case .studio: return "Studio"
            case .ocean: return "Ocean"
            case .sunset: return "Sunset"
            case .bokeh: return "Evening Lights"
            }
        }
    }

    /// How it's named in messages.
    var title: String {
        switch self {
        case .none: return "Off"
        case .blur: return "Blur"
        case .scene(let scene): return scene.title
        case .color: return "Color"
        case .image(let url): return url.deletingPathExtension().lastPathComponent
        }
    }

    /// How it's remembered in Settings.
    var storageValue: String {
        switch self {
        case .none: return "none"
        case .blur: return "blur"
        case .scene(let scene): return "scene:" + scene.rawValue
        case .color(let red, let green, let blue): return "color:\(red),\(green),\(blue)"
        case .image(let url): return "image:" + url.path
        }
    }

    init(storageValue: String) {
        let parts = storageValue.split(separator: ":", maxSplits: 1).map(String.init)
        switch parts.first {
        case "blur": self = .blur
        case "scene": self = parts.count > 1 ? Scene(rawValue: parts[1]).map(CameraBackground.scene) ?? .none : .none
        case "color":
            let values = parts.count > 1 ? parts[1].split(separator: ",").compactMap { Double($0) } : []
            self = values.count == 3 ? .color(red: values[0], green: values[1], blue: values[2]) : .none
        case "image": self = parts.count > 1 ? .image(URL(fileURLWithPath: parts[1])) : .none
        default: self = .none
        }
    }
}

/// Separates you from the background in each camera frame with Vision's person segmentation and
/// blurs or replaces the background, as Loom's `VisionCameraPersonSegmenter` does with
/// `VNGeneratePersonSegmentationRequest` and a Core Image blend.
///
/// Use `process` from one queue; `background` may be changed from anywhere.
final class CameraEffects {
    /// Vision is run at most this often (Loom also has a minimum segmentation interval). Frames in
    /// between reuse the last mask, which can't be seen at this rate but keeps a slow Mac from falling behind.
    static let minimumSegmentationInterval: TimeInterval = 1.0 / 30

    /// The default Blur strength, and how much the background is blurred from lightest to heaviest:
    /// the Gaussian blur's sigma as a share of the frame's height.
    static let defaultBlurStrength = 0.5
    private static let blurRange = (light: 0.008, heavy: 0.058)

    private let lock = NSLock()
    private var _background: CameraBackground = .none
    private var _blurStrength = CameraEffects.defaultBlurStrength
    var background: CameraBackground {
        get { lock.lock(); defer { lock.unlock() }; return _background }
        set { lock.lock(); _background = newValue; lock.unlock() }
    }
    /// How strongly Blur blurs, from 0 (just softened) to 1 (nothing recognisable).
    var blurStrength: Double {
        get { lock.lock(); defer { lock.unlock() }; return _blurStrength }
        set { lock.lock(); _blurStrength = min(max(newValue, 0), 1); lock.unlock() }
    }

    // Used only from the processing queue.
    private let context = CIContext(mtlDevice: MTLCreateSystemDefaultDevice()!, options: [.cacheIntermediates: false])
    private let request: VNGeneratePersonSegmentationRequest = {
        let request = VNGeneratePersonSegmentationRequest()
        request.qualityLevel = .balanced   // .accurate is too slow for live video; .fast leaves ragged edges
        request.outputPixelFormat = kCVPixelFormatType_OneComponent8
        return request
    }()
    private let sequence = VNSequenceRequestHandler()
    private var lastMask: CIImage?
    private var lastSegmentation: TimeInterval = 0
    private var pool: CVPixelBufferPool?
    private var poolSize: CGSize = .zero
    private var backdropCache: (key: String, size: CGSize, image: CIImage)?

    /// The camera frame with its background blurred or replaced, as a new BGRA pixel buffer the same
    /// size, or nil when there's nothing to change (no effect chosen, or no person found yet).
    func process(_ frame: CVPixelBuffer) -> CVPixelBuffer? {
        lock.lock()
        let background = _background, blurStrength = _blurStrength
        lock.unlock()
        guard background != .none, let mask = personMask(for: frame) else { return nil }
        let camera = CIImage(cvPixelBuffer: frame)
        let extent = camera.extent

        // The mask is smaller than the frame: scale it up and soften its edge a little.
        let scaled = mask.transformed(by: CGAffineTransform(scaleX: extent.width / mask.extent.width,
                                                            y: extent.height / mask.extent.height))
        let edge = scaled.clampedToExtent().applyingGaussianBlur(sigma: Double(extent.height) / 400).cropped(to: extent)

        guard let backdrop = backdrop(for: background, camera: camera, blurStrength: blurStrength) else { return nil }
        let blend = CIFilter.blendWithMask()
        blend.inputImage = camera
        blend.backgroundImage = backdrop
        blend.maskImage = edge
        guard let output = blend.outputImage, let buffer = makeBuffer(size: extent.size) else { return nil }
        context.render(output, to: buffer, bounds: extent, colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
        return buffer
    }

    /// Vision's mask of where the person is: white for person, black for background.
    private func personMask(for frame: CVPixelBuffer) -> CIImage? {
        let now = ProcessInfo.processInfo.systemUptime
        if let lastMask, now - lastSegmentation < Self.minimumSegmentationInterval { return lastMask }
        do {
            try sequence.perform([request], on: frame, orientation: .up)
        } catch {
            return lastMask
        }
        guard let result = request.results?.first?.pixelBuffer else { return lastMask }
        lastMask = CIImage(cvPixelBuffer: result)
        lastSegmentation = now
        return lastMask
    }

    /// What goes behind you, the size of the camera picture.
    private func backdrop(for background: CameraBackground, camera: CIImage, blurStrength: Double) -> CIImage? {
        let extent = camera.extent
        switch background {
        case .none:
            return nil
        case .blur:
            // Scaled to the frame, so a strength looks the same at any camera resolution. The middle
            // setting hides a room the way a portrait lens would.
            let share = Self.blurRange.light + (Self.blurRange.heavy - Self.blurRange.light) * blurStrength
            return camera.clampedToExtent().applyingGaussianBlur(sigma: Double(extent.height) * share).cropped(to: extent)
        case .color(let red, let green, let blue):
            return CIImage(color: CIColor(red: red, green: green, blue: blue)).cropped(to: extent)
        case .scene, .image:
            let key = background.storageValue
            if let cache = backdropCache, cache.key == key, cache.size == extent.size { return cache.image }
            let source: CIImage?
            if case .scene(let scene) = background {
                source = Self.draw(scene, size: extent.size)
            } else if case .image(let url) = background {
                source = CIImage(contentsOf: url, options: [.applyOrientationProperty: true])
            } else {
                source = nil
            }
            guard let source else { return nil }
            // Fill the frame, cropping the middle, and render it once so later frames reuse it.
            let fill = max(extent.width / source.extent.width, extent.height / source.extent.height)
            let scaled = source.transformed(by: CGAffineTransform(scaleX: fill, y: fill))
            let centered = scaled.transformed(by: CGAffineTransform(translationX: (extent.width - scaled.extent.width) / 2 - scaled.extent.minX,
                                                                    y: (extent.height - scaled.extent.height) / 2 - scaled.extent.minY))
                .cropped(to: extent)
            guard let rendered = context.createCGImage(centered, from: extent) else { return nil }
            let image = CIImage(cgImage: rendered)
            backdropCache = (key, extent.size, image)
            return image
        }
    }

    private func makeBuffer(size: CGSize) -> CVPixelBuffer? {
        if pool == nil || poolSize != size {
            let attributes: [String: Any] = [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: Int(size.width),
                kCVPixelBufferHeightKey as String: Int(size.height),
                kCVPixelBufferIOSurfacePropertiesKey as String: [:],
                kCVPixelBufferMetalCompatibilityKey as String: true,
            ]
            var newPool: CVPixelBufferPool?
            CVPixelBufferPoolCreate(nil, nil, attributes as CFDictionary, &newPool)
            pool = newPool
            poolSize = size
        }
        guard let pool else { return nil }
        var buffer: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
        return buffer
    }

    // MARK: - Built-in scenes

    /// Soft, out-of-focus-looking backdrops drawn with Core Image, so they suit being behind a person.
    static func draw(_ scene: CameraBackground.Scene, size: CGSize) -> CIImage {
        let extent = CGRect(origin: .zero, size: size)
        func color(_ hex: UInt32) -> CIColor {
            CIColor(red: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255)
        }
        func linear(_ top: UInt32, _ bottom: UInt32) -> CIImage {
            let gradient = CIFilter.linearGradient()
            gradient.point0 = CGPoint(x: 0, y: size.height)
            gradient.point1 = CGPoint(x: size.width * 0.2, y: 0)
            gradient.color0 = color(top)
            gradient.color1 = color(bottom)
            return gradient.outputImage!.cropped(to: extent)
        }
        func glow(_ hex: UInt32, at point: CGPoint, radius: CGFloat, strength: CGFloat) -> CIImage {
            let gradient = CIFilter.radialGradient()
            gradient.center = point
            gradient.radius0 = 0
            gradient.radius1 = Float(radius)
            let tint = color(hex)
            gradient.color0 = CIColor(red: tint.red, green: tint.green, blue: tint.blue, alpha: strength)
            gradient.color1 = CIColor(red: tint.red, green: tint.green, blue: tint.blue, alpha: 0)
            return gradient.outputImage!.cropped(to: extent)
        }
        let w = size.width, h = size.height
        switch scene {
        case .studio:
            return glow(0xF2F2F4, at: CGPoint(x: w * 0.55, y: h * 0.6), radius: w * 0.7, strength: 0.9)
                .composited(over: linear(0x9A9CA3, 0x55575E))
        case .ocean:
            return glow(0xBFF3FF, at: CGPoint(x: w * 0.7, y: h * 0.8), radius: w * 0.5, strength: 0.55)
                .composited(over: linear(0x2E8FB8, 0x0B3A5C))
        case .sunset:
            return glow(0xFFE2A8, at: CGPoint(x: w * 0.3, y: h * 0.35), radius: w * 0.45, strength: 0.8)
                .composited(over: linear(0xF08A5D, 0x6A3A8C))
        case .bokeh:
            // Out-of-focus lights: soft discs in warm colours over a dark blue, then blurred together.
            var image = linear(0x1B2440, 0x0B0F1E)
            var seed: UInt64 = 0x4D59_4C4D   // fixed, so the scene looks the same every time
            func next() -> CGFloat {
                seed = seed &* 6364136223846793005 &+ 1442695040888963407
                return CGFloat(seed >> 33) / CGFloat(1 << 31)
            }
            let tints: [UInt32] = [0xFFC46B, 0xFF8F6B, 0xFFE9B0, 0x8FD3FF]
            for index in 0..<22 {
                let radius = h * (0.04 + 0.07 * next())
                image = glow(tints[index % tints.count], at: CGPoint(x: w * next(), y: h * next()), radius: radius, strength: 0.35 + 0.35 * next())
                    .composited(over: image)
            }
            return image.clampedToExtent().applyingGaussianBlur(sigma: Double(h) / 120).cropped(to: extent)
        }
    }
}
