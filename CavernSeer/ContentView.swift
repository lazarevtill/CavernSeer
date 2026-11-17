//
//  ContentView.swift
//  CavernSeer
//
//  Created by Samuel Grush on 6/27/20.
//  Copyright © 2021 Samuel K. Grush. All rights reserved.
//

import SwiftUI

fileprivate let supportedTabs: [TabProtocol] = [
    ProjectListTab(),
    ScanListTab(),
    ScannerTab(),
    SettingsTab(),
].filter({ $0.isSupported })

struct ContentView: View {
    @StateObject private var scannerControl = ScannerControlModel()
    @State private var importOpenError: String?
    @State private var showImportOpenError = false
    @State private var selection: Tabs = Tabs.ScanListTab
    @EnvironmentObject var scanStore: ScanStore
    @EnvironmentObject var fileOpener: FileOpener

    let tabs: [TabProtocol] = supportedTabs
 
    var body: some View {
        TabView(selection: guardedSelection){

            ForEach(tabs, id: \.tab) {
                tab in
                tab.getTabPanelView(selected: selection == tab.tab)
                    .tag(tab.tab)
                    .tabItem {
                        VStack {
                            tab.tabImage
                            Text(tab.tabName)
                        }
                    }
            }
        }
        .environmentObject(scannerControl)
        .sheet(isPresented: importSheetPresentation) {
            NavigationView {
                List {
                    if !fileOpener.openSuccesses.isEmpty {
                        Section("Imported") {
                            ForEach(sortedURLs(fileOpener.openSuccesses.keys), id: \.self) { url in
                                if fileOpener.openSuccesses[url] == .scan {
                                    Button(url.lastPathComponent) { openScan(url) }
                                } else {
                                    Text(url.lastPathComponent)
                                }
                            }
                        }
                    }
                    if !fileOpener.openFailures.isEmpty {
                        Section("Not imported") {
                            ForEach(sortedURLs(fileOpener.openFailures.keys), id: \.self) { url in
                                VStack(alignment: .leading) {
                                    Text(url.lastPathComponent)
                                    Text(fileOpener.openFailures[url] ?? "Could not open file.")
                                        .font(.footnote)
                                        .foregroundColor(.secondary)
                                }
                            }
                        }
                    }
                }
                .navigationTitle("Import results")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { fileOpener.showOpenResults = false }
                    }
                }
            }
        }
        .alert("Could not show imported scan", isPresented: $showImportOpenError) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(importOpenError ?? "Open Scan List and pull to refresh.")
        }
    }

    private func sortedURLs<S: Sequence>(_ urls: S) -> [URL] where S.Element == URL {
        urls.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }

    private var guardedSelection: Binding<Tabs> {
        Binding(
            get: { selection },
            set: { proposed in
                if scannerControl.scanEnabled && proposed != selection {
                    scannerControl.requestFinishBeforeLeaving()
                } else {
                    selection = proposed
                }
            }
        )
    }

    private var importSheetPresentation: Binding<Bool> {
        Binding(
            get: { !scannerControl.scanEnabled && fileOpener.showOpenResults },
            set: { presented in
                if !scannerControl.scanEnabled { fileOpener.showOpenResults = presented }
            }
        )
    }

    private func openScan(_ url: URL) {
        guard !scannerControl.scanEnabled else { return }
        fileOpener.showOpenResults = false
        selection = .ScanListTab
        scanStore.setVisible(visible: url, updateFirst: true) { error in
            importOpenError = error.localizedDescription
            showImportOpenError = true
        }
    }

}

struct ContentView_Previews: PreviewProvider {

    static var previews: some View {

        let settings = SettingsStore()
        let scanStore = ScanStore(settings: settings)
        let projStore = ProjectStore()
        let fileOpener = FileOpener(scanStore, projStore)

        ContentView()
            .environmentObject(scanStore)
            .environmentObject(fileOpener)
    }
}
