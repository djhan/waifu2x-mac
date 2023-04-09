//
//  CGImage+Alpha.swift
//  waifu2x-mac
//
//  Created by DJ.HAN on 2023/04/10.
//  Copyright © 2023 谢宜. All rights reserved.
//

import Foundation

extension CGImage {
    // For images with more than 8 bits per component, extracting alpha only produces incomplete image
    func alphaTyped<T>(bits: Int, zero: T) -> UnsafeMutablePointer<T> {
        let data = UnsafeMutablePointer<T>.allocate(capacity: width * height * 4)
        data.initialize(repeating: zero, count: width * height)
        let alphaOnly = CGContext(data: data, width: width, height: height, bitsPerComponent: bits, bytesPerRow: width * 4 * bits / 8, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        alphaOnly?.draw(self, in: CGRect(x: 0, y: 0, width: width, height: height))
        return data
    }
    
    func alphaNonTyped(_ datap: UnsafeMutableRawPointer) {
        let alphaOnly = CGContext(data: datap, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.alphaOnly.rawValue)
        alphaOnly?.draw(self, in: CGRect(x: 0, y: 0, width: width, height: height))
    }
    
    func alpha() -> [UInt8] {
        let width = self.width
        let height = self.height
        let bits = self.bitsPerComponent
        NSLog("Bits per component: %d", bits)
        var data = [UInt8].init(repeating: 0, count: width * height)
        if bits == 8 {
            alphaNonTyped(&data)
        } else if bits == 16 {
            let typed: UnsafeMutablePointer<UInt16> = alphaTyped(bits: 16, zero: 0)
            for i in 0 ..< data.count {
                data[i] = UInt8(typed[i * 4 + 3] >> 8)
            }
            typed.deallocate()
        } else if bits == 32 {
            let typed: UnsafeMutablePointer<UInt32> = alphaTyped(bits: 32, zero: 0)
            for i in 0 ..< data.count {
                data[i] = UInt8(typed[i * 4 + 3] >> 24)
            }
            typed.deallocate()
        }
        return data
    }
}
