//
//  MiniPlayerView.swift
//  PodcastTranslate
//
//  Created by Sety Tekeu on 7/27/26.
//

import SwiftUI

struct MiniPlayerView: View {
    var body: some View {
        HStack(spacing: 15) {
            PlayerInfo(size: .init(width: 30, height: 30))
            
            Spacer(minLength: 0)
            
            /// Action Buttons
            Button {
                
            } label: {
                Image(systemName: "play.fill")
                    .contentShape(.rect)
                    .foregroundStyle(.black)
            }
            .padding(.trailing, 10)

            Button {
                
            } label: {
                Image(systemName: "forward.fill")
                    .contentShape(.rect)
                    .foregroundStyle(.black)
            }
        }
        .foregroundStyle(.primary)
        .padding(.horizontal, 15)
    }
}

#Preview {
    MiniPlayerView()
}
