//
//  PlayList.swift
//  MusicBox
//
//  Created by Elsa on 2024/4/19.
//

import Foundation
import SwiftUI

struct PlayListView: View {
    @EnvironmentObject var playController: PlayController

    var body: some View {
        List(playController.sampleBufferPlayer.items, id: \.self.url) {
            item in
            Text(item.title)
        }
    }
}
