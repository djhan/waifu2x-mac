//
//  Waifu2x.swift
//  waifu2x-mac
//
//  Created by xieyi on 2018/1/24.
//  Copyright © 2018年 xieyi. All rights reserved.
//

import Foundation
import CoreML

/// 변환 결과 튜플
public typealias WaifuResult = (bitmapData: CFData,
                                width: Int,
                                height: Int,
                                channels: Int,
                                space: CGColorSpace,
                                bitmapInfo: CGBitmapInfo)

public struct Waifu2x {
    
    /// The output block size.
    /// It is dependent on the model.
    /// Do not modify it until you are sure your model has a different number.
    static var block_size = 128
    
    /// The difference between output and input block size
    static let shrink_size = 7
    
    /// 내부 처리용 락
    static let lock = NSLock()
    
    /// Do not exactly know its function
    /// However it can on average improve PSNR by 0.09
    /// https://github.com/nagadomi/waifu2x/commit/797b45ae23665a1c5e3c481c018e48e6f0d0e383
    static let clip_eta8 = Float(0.00196)
    
    public static var interrupt = false
    
    static private var in_pipeline: BackgroundPipeline<CGRect>! = nil
    static private var model_pipeline: BackgroundPipeline<MLMultiArray>! = nil
    static private var out_pipeline: BackgroundPipeline<MLMultiArray>! = nil

    /// `NSImage`를 `WaifuResult` 튜플로 반환
    /// - Parameters:
    ///   - image: 입력 이미지. `NSImage`
    ///   - model: 실행 모델
    ///   - callback: 처리 실패/성공 결과를 반환하는 콜백
    /// - Returns: `WaifuResult` 튜플. 실패시 nil 반환
    static private func run(_ image: NSImage!, model: Model!, _ callback: @escaping (String) -> Void = { _ in }) -> WaifuResult? {
        guard image != nil else {
            return nil
        }
        guard model != nil else {
            callback("finished")
            return nil
        }
        
        guard let cgimage = image.representations[0].cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            print("Failed to get CGImage")
            return nil
        }
        return self.run(cgimage, model: model)
    }
        
    /// `CGImage`를 `WaifuResult` 튜플로 반환
    /// - Parameters:
    ///   - cgimage: 입력 이미지. `CGImage`
    ///   - model: 실행 모델
    ///   - callback: 처리 실패/성공 결과를 반환하는 콜백
    /// - Returns: `WaifuResult` 튜플. 실패시 nil 반환
    static private func run(_ cgimage: CGImage!, model: Model!, _ callback: @escaping (String) -> Void = { _ in }) -> WaifuResult? {
        print("Waifu2X>run(): Lock")
        // 락을 건다
        self.lock.lock()
        // 종료시 락 해제
        defer {
            print("Waifu2X>run(): Unlock")
            self.lock.unlock()
        }
        
        Waifu2x.interrupt = false
        var out_scale: Int
        switch model! {
        case .anime_noise0, .anime_noise1, .anime_noise2, .anime_noise3, .photo_noise0, .photo_noise1, .photo_noise2, .photo_noise3:
            self.block_size = 128
            out_scale = 1
        default:
            self.block_size = 142
            out_scale = 2
        }

        print("scale = \(out_scale), block size = \(self.block_size)")
        let width = cgimage.width
        let height = cgimage.height
        var fullWidth = width
        var fullHeight = height
        var fullCG: CGImage = cgimage

        // If image is too small, expand it
        if width < self.block_size || height < self.block_size {
            if width < self.block_size {
                fullWidth = self.block_size
            }
            if height < self.block_size {
                fullHeight = self.block_size
            }
            var bitmapInfo = cgimage.bitmapInfo.rawValue
            if bitmapInfo & CGBitmapInfo.alphaInfoMask.rawValue == CGImageAlphaInfo.first.rawValue {
                bitmapInfo = bitmapInfo & ~CGBitmapInfo.alphaInfoMask.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue
            } else if bitmapInfo & CGBitmapInfo.alphaInfoMask.rawValue == CGImageAlphaInfo.last.rawValue {
                bitmapInfo = bitmapInfo & ~CGBitmapInfo.alphaInfoMask.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue
            }
            let context = CGContext(data: nil, width: fullWidth, height: fullHeight, bitsPerComponent: cgimage.bitsPerComponent, bytesPerRow: cgimage.bytesPerRow / width * fullWidth, space: cgimage.colorSpace ?? CGColorSpaceCreateDeviceRGB(), bitmapInfo: bitmapInfo)
            var y = fullHeight - height
            if y < 0 {
                y = 0
            }
            context?.draw(cgimage, in: CGRect(x: 0, y: y, width: width, height: height))
            guard let contextCG = context?.makeImage() else {
                return nil
            }
            fullCG = contextCG
        }
        
        print("w/h = \(width)/\(height)")
        print("full w/h = \(fullWidth)/\(fullHeight)")

        var hasalpha = cgimage.alphaInfo != CGImageAlphaInfo.none
        debugPrint("With Alpha: \(hasalpha)")
        let channels = 4
        var alpha: [UInt8]! = nil
        if hasalpha {
            alpha = cgimage.alpha()
            var ralpha = false
            // Check if it really has alpha
            for a in alpha {
                if a < 255 {
                    ralpha = true
                    break
                }
            }
            if ralpha == false {
                hasalpha = false
            }
        }
        debugPrint("Really With Alpha: \(hasalpha)")
        let out_width = width * out_scale
        let out_height = height * out_scale
        let out_fullWidth = fullWidth * out_scale
        let out_fullHeight = fullHeight * out_scale
        let out_block_size = self.block_size * out_scale
        let rects = fullCG.getCropRects()
        // Prepare for output pipeline
        // Merge arrays into one array
        let normalize = { (input: Double) -> Double in
            let output = input * 255
            if output > 255 {
                return 255
            }
            if output < 0 {
                return 0
            }
            return output
        }
        let bufferSize = out_block_size * out_block_size * 3
        let imgData = UnsafeMutablePointer<UInt8>.allocate(capacity: out_width * out_height * channels)
        
        print("out w/h = \(out_width)/\(out_height) :: channels = \(channels)")
        
        defer {
            imgData.deallocate()
        }
        // Alpha channel support
        var alpha_task: BackgroundTask? = nil
        if hasalpha {
            alpha_task = BackgroundTask("alpha") {
                if out_scale > 1 {
                    var outalpha: [UInt8]? = nil
                    if let metalBicubic = try? MetalBicubic() {
                        NSLog("Maximum texture size supported: %d", metalBicubic.maxTextureSize())
                        if out_width <= metalBicubic.maxTextureSize() && out_height <= metalBicubic.maxTextureSize() {
                            outalpha = metalBicubic.resizeSingle(alpha, width, height, Float(out_scale))
                        }
                    }
                    var emptyAlpha = true
                    for item in outalpha ?? [] {
                        if item > 0 {
                            emptyAlpha = false
                            break
                        }
                    }
                    if outalpha != nil && !emptyAlpha {
                        alpha = outalpha!
                    } else {
                        // Fallback to CPU scale
                        let bicubic = Bicubic(image: alpha, channels: 1, width: width, height: height)
                        alpha = bicubic.resize(scale: Float(out_scale))
                    }
                }
                for y in 0 ..< out_height {
                    for x in 0 ..< out_width {
                        imgData[(y * out_width + x) * channels + 3] = alpha[y * out_width + x]
                    }
                }
            }
        }
        // Output
        Waifu2x.out_pipeline = BackgroundPipeline<MLMultiArray>("out_pipeline", count: rects.count) { (index, array) in
            let rect = rects[index]
            let origin_x = Int(rect.origin.x) * out_scale
            let origin_y = Int(rect.origin.y) * out_scale
            let dataPointer = UnsafeMutableBufferPointer(start: array.dataPointer.assumingMemoryBound(to: Double.self),
                                                         count: bufferSize)
            var dest_x: Int
            var dest_y: Int
            var src_index: Int
            var dest_index: Int
            
            print("imgData size =\(out_width * out_height * channels) :: dataPointer size = \(bufferSize) :: out block size = \(out_block_size)")
            
            for channel in 0..<3 {
                for src_y in 0..<out_block_size {
                    for src_x in 0..<out_block_size {
                        dest_x = origin_x + src_x
                        dest_y = origin_y + src_y
                        if dest_x >= out_fullWidth || dest_y >= out_fullHeight {
                            continue
                        }
                        src_index = src_y * out_block_size + src_x + out_block_size * out_block_size * channel
                        dest_index = (dest_y * out_width + dest_x) * channels + channel
                        
                        if src_index > bufferSize {
                            continue
                        }
                        if dest_index > out_width * out_height * channels {
                            //print("dest index = \(dest_index)")
                            continue
                        }
                        
                        imgData[dest_index] = UInt8(normalize(dataPointer[src_index]))
                    }
                }
            }
        }
        // Prepare for model pipeline
        // Run prediction on each block
        let mlmodel = model.getMLModel()
        Waifu2x.model_pipeline = BackgroundPipeline<MLMultiArray>("model_pipeline", count: rects.count) { (index, array) in
            out_pipeline.appendObject(try! mlmodel.prediction(input: array))
            callback("\((index * 100) / rects.count)")
        }
        // Start running model
        let expwidth = fullWidth + 2 * Waifu2x.shrink_size
        let expheight = fullHeight + 2 * Waifu2x.shrink_size
        let expanded = fullCG.expand(withAlpha: hasalpha)
        callback("processing")
        Waifu2x.in_pipeline = BackgroundPipeline<CGRect>("in_pipeline", count: rects.count, task: { (index, rect) in
            let x = Int(rect.origin.x)
            let y = Int(rect.origin.y)
            let multi = try! MLMultiArray(shape: [3, NSNumber(value: Waifu2x.block_size + 2 * Waifu2x.shrink_size), NSNumber(value: Waifu2x.block_size + 2 * Waifu2x.shrink_size)], dataType: .float32)
            var x_new: Int
            var y_new: Int
            print("multi count =\(multi.count) :: expanded = \(expanded.count)")
            for y_exp in y..<(y + Waifu2x.block_size + 2 * Waifu2x.shrink_size) {
                for x_exp in x..<(x + Waifu2x.block_size + 2 * Waifu2x.shrink_size) {
                    x_new = x_exp - x
                    y_new = y_exp - y
                    var dest = y_new * (Waifu2x.block_size + 2 * Waifu2x.shrink_size) + x_new
                    
                    if dest > multi.count {
                        continue
                    }
                    if y_exp * expwidth + x_exp > expanded.count {
                        continue
                    }
                    
                    multi[dest] = NSNumber(value: expanded[y_exp * expwidth + x_exp])
                    dest = y_new * (Waifu2x.block_size + 2 * Waifu2x.shrink_size) + x_new + (block_size + 2 * Waifu2x.shrink_size) * (block_size + 2 * Waifu2x.shrink_size)
                    
                    if dest > multi.count {
                        continue
                    }
                    if y_exp * expwidth + x_exp + expwidth * expheight > expanded.count {
                        continue
                    }

                    multi[dest] = NSNumber(value: expanded[y_exp * expwidth + x_exp + expwidth * expheight])
                    dest = y_new * (Waifu2x.block_size + 2 * Waifu2x.shrink_size) + x_new + (block_size + 2 * Waifu2x.shrink_size) * (block_size + 2 * Waifu2x.shrink_size) * 2
                    
                    if dest > multi.count {
                        continue
                    }
                    if y_exp * expwidth + x_exp + expwidth * expheight * 2 > expanded.count {
                        //print("value count = \(y_exp * expwidth + x_exp + expwidth * expheight * 2)")
                        continue
                    }
                    
                    multi[dest] = NSNumber(value: expanded[y_exp * expwidth + x_exp + expwidth * expheight * 2])
                }
            }
            Waifu2x.model_pipeline.appendObject(multi)
            print("in pipeline 종료")
        })
        for i in 0..<rects.count {
            Waifu2x.in_pipeline.appendObject(rects[i])
        }
        Waifu2x.in_pipeline.wait()
        Waifu2x.model_pipeline.wait()
        callback("wait_alpha")
        alpha_task?.wait()
        Waifu2x.out_pipeline.wait()
        Waifu2x.in_pipeline = nil
        Waifu2x.model_pipeline = nil
        Waifu2x.out_pipeline = nil
        if Waifu2x.interrupt {
            return nil
        }
        print("출력물 작업")
        callback("generate_output")
        guard let cfbuffer = CFDataCreate(nil, imgData, out_width * out_height * channels) else {
            return nil
        }
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        var bitmapInfo = CGBitmapInfo.byteOrder32Big.rawValue
        if hasalpha {
            bitmapInfo |= CGImageAlphaInfo.last.rawValue
        } else {
            bitmapInfo |= CGImageAlphaInfo.noneSkipLast.rawValue
        }
     
        return (bitmapData: cfbuffer,
                width: out_width, height: out_height,
                channels: channels,
                space: colorSpace,
                bitmapInfo: CGBitmapInfo.init(rawValue: bitmapInfo))
    }
    
    /// `NSImage`를 `CGImage`로 반환
    /// - Parameters:
    ///   - image: 입력 이미지. `NSImage`
    ///   - model: 실행 모델
    ///   - callback: 처리 실패/성공 결과를 반환하는 콜백
    /// - Returns: `CGImage`. 실패시 nil 반환
    static private func runImageToCGImage(_ image: NSImage!, model: Model!, _ callback: @escaping (String) -> Void = { _ in }) -> CGImage? {
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return nil
        }
        return self.runCGImageToCGImage(cgImage, model: model, callback)
    }
    /// `CGImage`를 `CGImage`로 반환
    /// - Parameters:
    ///   - cgimage: 입력 이미지. `CGImage`
    ///   - model: 실행 모델
    ///   - callback: 처리 실패/성공 결과를 반환하는 콜백
    /// - Returns: `CGImage`. 실패시 nil 반환
    static private func runCGImageToCGImage(_ cgImage: CGImage!, model: Model!, _ callback: @escaping (String) -> Void = { _ in }) -> CGImage? {
        guard let waifuResult = self.run(cgImage, model: model, callback),
                let dataProvider = CGDataProvider(data: waifuResult.bitmapData) else {
            return nil
        }

        guard let cgImage = CGImage(width: waifuResult.width,
                                    height: waifuResult.height,
                                    bitsPerComponent: 8,
                                    bitsPerPixel: 8 * waifuResult.channels,
                                    bytesPerRow: waifuResult.width * waifuResult.channels,
                                    space: waifuResult.space,
                                    bitmapInfo: waifuResult.bitmapInfo,
                                    provider: dataProvider,
                                    decode: nil,
                                    shouldInterpolate: true,
                                    intent: CGColorRenderingIntent.defaultIntent) else {
            return nil
        }
        callback("finished CGImage")
        return cgImage
    }

    /// `NSImage`를 `NSImage`로 반환하는 메쏘드
    /// - Parameters:
    ///   - image: 입력 이미지. `NSImage`
    ///   - model: 실행 모델
    ///   - callback: 처리 실패/성공 결과를 반환하는 콜백
    /// - Returns: `NSImage`. 실패시 nil 반환
    static public func runToImage(_ image: NSImage!, model: Model!, _ callback: @escaping (String) -> Void = { _ in }) -> NSImage? {
        guard let resultCGImage = self.runImageToCGImage(image, model: model, callback) else {
            return nil
        }
        let size = CGSize(width: resultCGImage.width, height: resultCGImage.height)
        let outImage = NSImage(cgImage: resultCGImage, size: size)
        callback("finished NSImage")
        return outImage
    }
    
    /// `CGImage`를 `CGImage`로 반환하는 메쏘드
    /// - Parameters:
    ///   - image: 입력 이미지. `CGImage`
    ///   - model: 실행 모델
    ///   - callback: 처리 실패/성공 결과를 반환하는 콜백
    /// - Returns: `NSImage`. 실패시 nil 반환
    static public func runToCGImage(_ cgimage: CGImage!, model: Model!, _ callback: @escaping (String) -> Void = { _ in }) -> CGImage? {
        guard let resultCGImage = self.runCGImageToCGImage(cgimage, model: model, callback) else {
            return nil
        }
        return resultCGImage
    }
    /// `CIImage`를 `CIImage`로 반환하는 메쏘드
    /// - Important: 속도면에서 상당히 느릴 수 있다. `CIContext` 는 낭비를 막기 위해 외부에서 지정해서 사용하도록 한다
    /// - Parameters:
    ///   - image: 입력 이미지. `CIImage`
    ///   - cicontext: `CIContext`
    ///   - syncLock: `NSLock`. 옵셔널
    ///   - model: 실행 모델
    ///   - callback: 처리 실패/성공 결과를 반환하는 콜백
    /// - Returns: `NSImage`. 실패시 nil 반환
    static public func runToCIImage(_ ciimage: CIImage!,
                                    cicontext: CIContext,
                                    syncLock: NSLock? = nil,
                                    model: Model!,
                                    _ callback: @escaping (String) -> Void = { _ in }) -> CIImage? {
        //---------------------------------------------------------------------------------------------//
        /// 실제 처리 메쏘드
        func _runToCIImage() -> CIImage? {
            guard let cgimage = cicontext.createCGImage(ciimage, from: ciimage.extent),
                  let resultCGImage = self.runCGImageToCGImage(cgimage, model: model, callback) else {
                return nil
            }
            return CIImage(cgImage: resultCGImage)
        }
        //---------------------------------------------------------------------------------------------//
        guard let syncLock = syncLock else {
            return _runToCIImage()
        }
        
        // 동기화 처리 필요시
        syncLock.lock()
        let ciimage = _runToCIImage()
        syncLock.unlock()
        return ciimage
    }
}

