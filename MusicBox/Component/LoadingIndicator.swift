//
//  LoadingIndicator.swift
//  MusicBox
//
//  Created by Elsa on 2024/5/19.
//

import Foundation
import SwiftUI

struct LoadingIndicatorView: View {
    var body: some View {
        ProgressView()
            .colorInvert()
            .progressViewStyle(CircularProgressViewStyle())
            .controlSize(.small)
            .frame(width: 48, height: 48)
            .background(Color.black.opacity(0.75))
            .clipShape(RoundedRectangle(cornerRadius: 10))
    }
}
