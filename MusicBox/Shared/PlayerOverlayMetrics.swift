import SwiftUI

enum PlayerOverlayMetrics {
    static let height: CGFloat = 52
    static let trackVisualPadding: CGFloat = 6
    static let trackInfoHeight: CGFloat = 32
    static let trackSliderHeight: CGFloat = 10
    static let trackSliderLineHeight: CGFloat = 2
    static let trackLayoutPadding = trackVisualPadding
        - (trackSliderHeight - trackSliderLineHeight) / 2
    static let horizontalInset: CGFloat = 16
    static let bottomInset: CGFloat = 20
    static let contentClearance: CGFloat = 92
}
