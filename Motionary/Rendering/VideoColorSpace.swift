// Matches the RGB encoding to the Rec.709 tags consumed by AVFoundation.

import CoreGraphics
import CoreVideo

enum VideoColorSpace {
    // The named Core Graphics ITU-R 709 profile and the color space derived
    // from Core Video's 709 transfer tags have different transfer curves.
    // Encoding in the former and attaching the latter changes displayed color.
    static let rec709: CGColorSpace? = CVImageBufferCreateColorSpaceFromAttachments(
        [
            kCVImageBufferColorPrimariesKey: kCVImageBufferColorPrimaries_ITU_R_709_2,
            kCVImageBufferTransferFunctionKey: kCVImageBufferTransferFunction_ITU_R_709_2,
            kCVImageBufferYCbCrMatrixKey: kCVImageBufferYCbCrMatrix_ITU_R_709_2
        ] as CFDictionary)?.takeRetainedValue()
}
