//
//  SavedScanList.swift
//  CavernSeer
//
//  Created by Samuel Grush on 7/6/20.
//  Copyright © 2020 Samuel K. Grush. All rights reserved.
//

import SwiftUI
import UniformTypeIdentifiers

struct SavedScanListView<ListStyleT: ListStyle>: View {

    @EnvironmentObject
    var scanStore: ScanStore

    @EnvironmentObject
    var settings: SettingsStore

    @EnvironmentObject private var fileOpener: FileOpener

    var listStyle: ListStyleT

    @State
    private var searchText = ""

    @State
    private var editMode: EditMode = .inactive

    @State private var showTrash = false
    @State private var showImportPicker = false
    @State private var initialLoad = true
    @State private var operationError: String?
    @State private var showOperationError = false

    var searchResults: [ScanCacheFile] {
        let term = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !term.isEmpty else { return scanStore.caches }
        return scanStore.caches.filter {
            $0.searchableText.contains(term) || $0.id.lowercased().contains(term)
        }
    }

    var body: some View {
        List(selection: $scanStore.selection) {
            ForEach(searchResults) { cache in
                NavigationLink(
                    destination: SavedScanDetail(cache: cache),
                    tag: cache.id,
                    selection: $scanStore.visibleScan
                ) {
                    SavedScanRow(cache: cache)
                }
                .tag(cache.id)
                .accessibilityIdentifier("scan-row-\(cache.id)")
                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                    Button {
                        moveToTrash(ids: [cache.id])
                    } label: {
                        Label("Move to Trash", systemImage: "trash")
                    }
                    // Not declared .destructive: SwiftUI must not visually
                    // remove a row until the store confirms the move.
                    .tint(.red)
                    .accessibilityIdentifier("move-scan-to-trash")
                }
            }
        }
        .overlay {
            if searchResults.isEmpty && !initialLoad {
                VStack(spacing: 6) {
                    Text(searchText.isEmpty ? "No saved scans" : "No matching scans")
                        .font(.headline)
                    if searchText.isEmpty {
                        Text(ScannerModel.supportsScan
                             ? "Use the Scanner tab to capture, or import a scan from Files."
                             : "Import a .cavernseerscan from Files to view it here.")
                            .font(.subheadline)
                            .multilineTextAlignment(.center)
                            .foregroundColor(.secondary)
                    }
                }
                .padding()
                .allowsHitTesting(false)
            }
        }
        .searchable(text: $searchText, placement: .navigationBarDrawer)
        .refreshable { refresh() }
        .environment(\.editMode, self.$editMode)
        .navigationTitle(Text("Scan List"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarLeading) {
                Button {
                    showTrash = true
                } label: {
                    Label("Trash", systemImage: "trash")
                }
                .accessibilityIdentifier("scan-trash")
            }
            ToolbarItemGroup(placement: .navigationBarTrailing) {
                Button {
                    showImportPicker = true
                } label: {
                    Label("Import scan from Files", systemImage: "square.and.arrow.down")
                }
                .accessibilityIdentifier("scan-import")
                editButton
                sortMenu
            }
            ToolbarItemGroup(placement: .bottomBar) {
                if editMode == .active {
                    Button {
                        moveToTrash(ids: scanStore.selection)
                    } label: {
                        Label("Move selected to Trash", systemImage: "trash")
                    }
                    .disabled(scanStore.selection.isEmpty)
                }
            }
        }
        .fileImporter(
            isPresented: $showImportPicker,
            allowedContentTypes: [UTType(exportedAs: "org.grush.cavernseer.scan")],
            allowsMultipleSelection: true
        ) { result in
            switch result {
            case .success(let urls): fileOpener.openURLs(urls: urls)
            case .failure(let error):
                if (error as? CocoaError)?.code != .userCancelled {
                    presentError(error.localizedDescription)
                }
            }
        }
        .sheet(isPresented: $showTrash) {
            ScanTrashView()
                .environmentObject(scanStore)
        }
        .alert("Scan list", isPresented: $showOperationError) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(operationError ?? "")
        }
        .onAppear {
            if initialLoad {
                initialLoad = false
                refresh()
            }
        }
    }

    private var editButton: some View {
        let newMode: EditMode = self.editMode == .inactive ? .active : .inactive
        return Button(action: {
            self.scanStore.selection.removeAll()
            self.editMode = newMode
        }, label: {
            Text(
                newMode == .inactive
                    ? "Done"
                    : "Edit"
            )
        })
    }

    private var sortMenu: some View {
        Menu {
            Picker(
                selection: $settings.SortingMethod,
                label: Image(systemName: SettingsKey.SortingMethod.name)
            ) {
                ForEach(SortMethod.allCases) {
                    method in
                    Text(method.name).tag(method)
                }
            }
            .pickerStyle(.inline)
                Picker(
                    selection: $settings.SortingOrder,
                    label: Text(SettingsKey.SortingOrder.name)
                ) {
                    Text("Ascending").tag(SortOrder.forward)
                    Text("Descending").tag(SortOrder.reverse)
                }
                .pickerStyle(.inline)
        } label: {
            Image(systemName: "arrow.up.arrow.down")
        }
    }

    private func moveToTrash(ids: Set<String>) {
        let failures = scanStore.trashScans(ids: ids)
        if !failures.isEmpty { presentError(failures.joined(separator: "\n")) }
    }

    private func refresh() {
        scanStore.update { error in
            if let error = error { presentError(error.localizedDescription) }
        }
    }

    private func presentError(_ text: String) {
        operationError = text
        showOperationError = true
    }
}

/// The app keeps trashed scans until restored. This is intentionally not a
/// purge screen: moving to Trash should never destroy a capture.
private struct ScanTrashView: View {
    @EnvironmentObject private var scanStore: ScanStore
    @Environment(\.dismiss) private var dismiss
    @State private var scans: [ScanStore.TrashedScan] = []
    @State private var operationError: String?
    @State private var showOperationError = false

    var body: some View {
        NavigationView {
            List {
                if scans.isEmpty {
                    Text("No scans in Trash.")
                        .foregroundColor(.secondary)
                }
                ForEach(scans) { scan in
                    HStack {
                        Text(scan.name)
                        Spacer()
                        Button("Restore") { restore(scan) }
                            .accessibilityIdentifier("restore-scan-\(scan.name)")
                    }
                }
            }
            .navigationTitle("Scan Trash")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .navigationViewStyle(.stack)
        .onAppear(perform: reload)
        .alert("Scan Trash", isPresented: $showOperationError) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(operationError ?? "")
        }
    }

    private func reload() {
        do { scans = try scanStore.trashedScans() }
        catch { presentError(error) }
    }

    private func restore(_ scan: ScanStore.TrashedScan) {
        do { try scanStore.restoreScan(scan) }
        catch { presentError(error) }
        scanStore.update()
        reload()
    }

    private func presentError(_ error: Error) {
        operationError = error.localizedDescription
        showOperationError = true
    }
}
