//
//  NSImage+Crop.swift
//  waifu2x-ios
//
//  Created by xieyi on 2017/9/14.
//  Copyright © 2017年 xieyi. All rights reserved.
//

import Foundation

extension NSImage {
    
    public func crop(rects: [CGRect]) -> [NSImage] {
        var result: [NSImage] = []
        for rect in rects {
            result.append(crop(rect: rect))
        }
        return result
    }
    
    public func crop(rect: CGRect) -> NSImage {
        var rect = NSRect.init(origin: .zero, size: self.size)
        let cgimg = cgImage(forProposedRect: &rect, context: nil, hints: nil)?.cropping(to: rect)
        return NSImage(cgImage: cgimg!, size: rect.size)
    }
    
    public func getCropRects() -> ([CGRect]) {
        let width = Int(self.size.width)
        let height = Int(self.size.height)
        let num_w = width / Waifu2x.block_size
        let num_h = height / Waifu2x.block_size
        let ex_w = width % Waifu2x.block_size
        let ex_h = height % Waifu2x.block_size
        var rects: [CGRect] = []
        for i in 0..<num_w {
            for j in 0..<num_h {
                let x = i * Waifu2x.block_size
                let y = j * Waifu2x.block_size
                let rect = CGRect(x: x, y: y, width: Waifu2x.block_size, height: Waifu2x.block_size)
                rects.append(rect)
            }
        }
        if ex_w > 0 {
            let x = width - Waifu2x.block_size
            for i in 0..<num_h {
                let y = i * Waifu2x.block_size
                let rect = CGRect(x: x, y: y, width: Waifu2x.block_size, height: Waifu2x.block_size)
                rects.append(rect)
            }
        }
        if ex_h > 0 {
            let y = height - Waifu2x.block_size
            for i in 0..<num_w {
                let x = i * Waifu2x.block_size
                let rect = CGRect(x: x, y: y, width: Waifu2x.block_size, height: Waifu2x.block_size)
                rects.append(rect)
            }
        }
        if ex_w > 0 && ex_h > 0 {
            let x = width - Waifu2x.block_size
            let y = height - Waifu2x.block_size
            let rect = CGRect(x: x, y: y, width: Waifu2x.block_size, height: Waifu2x.block_size)
            rects.append(rect)
        }
        return rects
    }
    
}
