//
//  FileSettingsSection.swift
//  CavernSeer
//
//  Created by Samuel Grush on 5/30/21.
//  Copyright © 2021 Samuel K. Grush. All rights reserved.
//

import Foundation
import SwiftUI

struct FileSettingsSection: View {
    @EnvironmentObject
    var scanStore: ScanStore

    @State private var showTrashPrompt = false
    @State private var operationError: String?
    @State private var showOperationError = false
    @State private var rebuilding = false

    var body: some View {
        Group {
            Button {
                rebuilding = true
                scanStore.rebuildScanPreviews { error in
                    rebuilding = false
                    if let error = error { presentError(error.localizedDescription) }
                }
            } label: {
                HStack {
                    Text("Rebuild scan previews")
                    if rebuilding { ProgressView() }
                }
            }
            .disabled(rebuilding)

            Button {
                showTrashPrompt = true
            } label: {
                Text("Move all scans to Trash")
                    .foregroundColor(.red)
            }
            .confirmationDialog(
                "Move all scans to Trash?",
                isPresented: $showTrashPrompt,
                titleVisibility: .visible
            ) {
                Button("Move all to Trash", role: .destructive) {
                    do {
                        let failures = try scanStore.trashAllScans()
                        if !failures.isEmpty { presentError(failures.joined(separator: "\n")) }
                    } catch {
                        presentError(error.localizedDescription)
                    }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("You can restore them from Scan List → Trash. This does not free storage.")
            }
        }
        .alert("Scan storage", isPresented: $showOperationError) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(operationError ?? "")
        }
    }

    private func presentError(_ text: String) {
        operationError = text
        showOperationError = true
    }
}
