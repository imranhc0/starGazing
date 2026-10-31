//
//  StarGazingApp.swift
//  StarGazing
//
//  Created by IMRAN on 31/10/26.
//

import SwiftUI

@main
struct StarGazingApp: App {
    @State private var model: StackViewModel

    init() {
        let background = BackgroundRunner()
        background.register()
        AppFiles.purgeOldResults()
        _model = State(initialValue: StackViewModel(
            runner: AppStackRunner(background: background),
            photos: SystemPhotosWriter(),
            pendingStore: PendingJobStore(directory: AppFiles.pending),
            checkpoints: CheckpointStore(directory: AppFiles.checkpoints)
        ))
    }

    var body: some Scene {
        WindowGroup {
            root
        }
    }

    @ViewBuilder
    private var root: some View {
        #if DEBUG
        if let demo = DemoScreen.requested {
            demo.view
        } else {
            ContentView(model: model)
        }
        #else
        ContentView(model: model)
        #endif
    }
}
