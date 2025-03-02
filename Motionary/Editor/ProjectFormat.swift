import SwiftUI

enum ProjectFormat: String, CaseIterable {
    case squareLandscape = "Square (Landscape)"
    case fourThree = "4:3"
    case sixteenNine = "16:9"
    case squarePortrait = "Square (Portrait)"
    case threeFour = "3:4"
    case nineSixteen = "9:16"
    
    var aspectRatio: CGFloat {
        switch self {
        case .squareLandscape, .squarePortrait:
            return 1.0
        case .fourThree:
            return 4.0 / 3.0
        case .sixteenNine:
            return 16.0 / 9.0
        case .threeFour:
            return 3.0 / 4.0
        case .nineSixteen:
            return 9.0 / 16.0
        }
    }
}