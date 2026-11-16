//
//  SavedScanDetail.swift
//  CavernSeer
//
//  Created by Samuel Grush on 7/6/20.
//  Copyright © 2021 Samuel K. Grush. All rights reserved.
//

import SwiftUI /// View

struct SavedScanDetail: View {
    var cache: ScanCacheFile

    @EnvironmentObject
    var settings: SettingsStore
    @EnvironmentObject
    var scanStore: ScanStore

    @State
    var error: Error?

    @State
    private var model: SavedScanModel? = nil
    private struct ShareArtifact: Identifiable {
        let id = UUID()
        let url: URL
        let temporary: Bool

        func cleanup() {
            if temporary { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        }
    }

    @State private var artifact: ShareArtifact?
    @State private var exportTask: Task<Void, Never>?
    @State private var exportError: String?
    @State private var showExportError = false

    private func loadModel() {
        if let err = self.cache.error {
            self.error = err
            return
        }

        let url = scanStore.getNormalizedRealUrl(cache: self.cache)
        if self.model?.url != url {
            do {
                self.model = try scanStore.getModel(url: url)
            } catch {
                self.error = error
            }
        }
    }

    var body: some View {
        VStack {

            SavedScanSnapshot(scan: model?.scan)

            Spacer()

            Text(model?.id ?? error?.localizedDescription ?? "Loading...")
                .font(.title)
                .padding()

            if let model = self.model {
                SavedScanDetailLinks(model: model)
            }
        }
        .toolbar {
            ToolbarItemGroup(placement: .navigationBarTrailing) {
                if let model = model {
                    if exportTask != nil {
                        ProgressView()
                        Button("Cancel") { exportTask?.cancel() }
                    } else {
                        Menu {
                            Button("Backup ZIP (original + mesh)") {
                                startExport(.backup, model: model)
                            }
                            Button("Original scan only") {
                                artifact = ShareArtifact(url: model.url, temporary: false)
                            }
                            Button("OBJ mesh only") {
                                startExport(.mesh, model: model)
                            }
                        } label: {
                            Label("Export scan", systemImage: "square.and.arrow.up")
                        }
                    }
                }
            }
        }
        .sheet(item: $artifact) { item in
            ScanShareSheet(activityItems: [item.url]) { _, _, _, error in
                item.cleanup()
                if let error = error {
                    self.exportError = error.localizedDescription
                    self.showExportError = true
                }
            }
        }
        .alert("Couldn't export scan", isPresented: $showExportError) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(exportError ?? "The original scan has not been changed.")
        }
        .onAppear(perform: self.loadModel)
        .onDisappear { exportTask?.cancel() }
    }

    private func startExport(_ mode: ObjSerializer.Output, model: SavedScanModel) {
        guard exportTask == nil else { return }
        exportTask = Task { @MainActor in
            defer { exportTask = nil }
            do {
                let url = try await ObjSerializer.prepare(mode, model: model)
                let item = ShareArtifact(url: url, temporary: true)
                if Task.isCancelled {
                    item.cleanup()
                } else {
                    artifact = item
                }
            } catch is CancellationError {
                // The staging directory is removed by the exporter.
            } catch {
                exportError = error.localizedDescription + "\nThe original scan has not been changed."
                showExportError = true
            }
        }
    }
}

#if DEBUG
struct SavedScanDetail_Previews: PreviewProvider {
    private static let settings = SettingsStore()
    private static let scanStore = setupScanStore(settings: settings)
    private static let serializer = ObjSerializer()

    private static let cacheItem = dummyScanCaches[1]

    static var previews: some View {
        Group {
            view
                .previewDevice(PreviewDevice(rawValue: "iPhone 12 Pro"))
                .environment(\.colorScheme, .dark)

            view
                .previewDevice(PreviewDevice(rawValue: "iPad Pro (12.9-inch) (5th generation)"))
                .environment(\.colorScheme, .dark)

            view
                .previewDisplayName("iPhone 8 Landscape")
                .previewLayout(PreviewLayout.fixed(width: 667, height: 375))

//            view
//                .previewLayout(.fixed(width: 1024, height: 768))
        }
        .environmentObject(scanStore)
        .environmentObject(settings)
        .environmentObject(serializer)
    }

    private static var view: some View {
        TabView {
            NavigationView {
                List {
                    NavigationLink(
                        destination: SavedScanDetail(cache: cacheItem),
                        isActive: Binding(get: { true }, set: {_,_ in }),
                        label: { SavedScanRow(cache: cacheItem) }
                    )
                }
            }
        }
    }

    private static func setupScanStore(settings: SettingsStore) -> ScanStore {
        let store = ScanStore(settings: settings)

        store.modelDataInMemory = dummySavedScans
        store.caches = dummyScanCaches

        return store
    }
}
#endif
