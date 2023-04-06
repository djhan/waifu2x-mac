//
//  NSImage+Expand.swift
//  waifu2x-mac
//
//  Created by DJ.HAN on 2023/04/06.
//  Copyright © 2023 谢宜. All rights reserved.
//

import Foundation

extension NSImage {
    
    /// Expand the original image by shrink_size and store rgb in float array.
    /// The model will shrink the input image by 7 px.
    ///
    /// - Returns: Float array of rgb values
    public func expand(withAlpha: Bool) -> [Float] {
        guard let cgImage = self.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return []
        }
        return cgImage.expand(withAlpha: withAlpha)
    }
}
