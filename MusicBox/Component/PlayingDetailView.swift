//
//  PlayingDetail.swift
//  MusicBox
//
//  Created by Elsa on 2024/5/16.
//

import Foundation
import SwiftUI

struct FullScreenCoverModifier: ViewModifier {
    @Binding var isPresented: Bool
    let content: () -> AnyView

    func body(content: Content) -> some View {
        ZStack {
            content
                .zIndex(0)

            if isPresented {
                self.content()
                    .background(Color.black.opacity(0.3).edgesIgnoringSafeArea(.all))
                    .transition(.move(edge: .bottom))
                    .zIndex(1)
                .edgesIgnoringSafeArea(.all)
            }
        }
    }
}

extension View {
    func fullScreenCover<Content: View>(isPresented: Binding<Bool>, content: @escaping () -> Content) -> some View {
        self.modifier(FullScreenCoverModifier(isPresented: isPresented, content: {
            AnyView(content())
        }))
    }
}

struct PlayingDetailView: View {
//    @Environment(\.dismiss) var dismiss

    var body: some View {
        ZStack {
            Color.primary.edgesIgnoringSafeArea(.all)
            Button("Dismiss Modal") {
//                dismiss()
            }
        }
    }
}
