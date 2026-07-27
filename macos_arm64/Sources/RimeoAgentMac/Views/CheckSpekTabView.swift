//
//  CheckSpekTabView.swift
//  RimeoAgent (macOS)
//
//  "Check spek" sidebar section: drop or open any audio file and inspect its
//  Spek-style spectrogram + fidelity verdict inline, without leaving the agent.
//  Reuses SpekResultView / SpectrumAnalyzer from the Check quality feature.
//

import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct CheckSpekTabView: View {
    @StateObject private var model = QualityModel()
    @State private var dropTargeted = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                ScreenHeader(title: "Check spek",
                             subtitle: "Frequency analysis · spek — check whether a track is genuine lossless or a re-encode.")
                content
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 34)
            .padding(.top, 30)
            .padding(.bottom, 30)
        }
        .background(C.bg)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onDrop(of: [UTType.fileURL], isTargeted: $dropTargeted, perform: handleDrop)
    }

    @ViewBuilder
    private var content: some View {
        switch model.state {
        case .idle:
            dropZone
        case .loading:
            SurfaceCard { SpekLoadingView().padding(.vertical, 44) }
        case .failed:
            SurfaceCard {
                VStack(spacing: 16) { SpekFailedView(); openButton }.padding(.vertical, 30)
            }
        case .ready(let r):
            VStack(alignment: .leading, spacing: 14) {
                toolbar
                SurfaceCard {
                    SpekResultView(result: r, fileName: model.fileName, titleTrailingReserve: 90).padding(22)
                }
                // QR in the card's top-right corner, level with the title/chips row
                // (sized so it clears the verdict badge below).
                .overlay(alignment: .topTrailing) {
                    SpekQRView(size: 72).padding(.top, 20).padding(.trailing, 20)
                }
            }
            .frame(maxWidth: 760, alignment: .leading)
        }
    }

    // Fixed-height drop card (natural height, top-aligned — never stretches).
    private var dropZone: some View {
        VStack(spacing: 18) {
            Image(systemName: "waveform.badge.magnifyingglass")
                .font(.system(size: 48, weight: .light))
                .foregroundColor(dropTargeted ? C.acc : C.dim)
            VStack(spacing: 6) {
                Text("Drop an audio file here")
                    .font(.system(size: 17, weight: .semibold)).foregroundColor(C.text)
                Text("WAV · AIFF · MP3 · FLAC · M4A — or click to choose")
                    .font(.system(size: 13)).foregroundColor(C.secondary)
            }
            openButton
        }
        .frame(maxWidth: .infinity)
        .frame(height: 300)
        .background(dropTargeted ? C.accSoft : C.surf)
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [8, 6]))
                .foregroundColor(dropTargeted ? C.acc : C.cardBrd)
        )
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .animation(.easeInOut(duration: 0.15), value: dropTargeted)
    }

    // File name + change-file action above a loaded result.
    private var toolbar: some View {
        HStack(spacing: 10) {
            Image(systemName: "waveform").foregroundColor(C.accText).font(.system(size: 14, weight: .semibold))
            Text(model.fileName).font(.system(size: 13, weight: .medium)).foregroundColor(C.secondary).lineLimit(1)
            Spacer()
            SecondaryButton(title: "Open another", icon: "folder", action: openPanel)
        }
    }

    private var openButton: some View {
        RimeoButton(title: "Open audio file…", icon: "folder", color: C.acc, action: openPanel)
    }

    // MARK: actions

    private func openPanel() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.audio]
        panel.prompt = "Analyze"
        if panel.runModal() == .OK, let url = panel.url {
            model.load(url: url)
        }
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first else { return false }
        _ = provider.loadObject(ofClass: URL.self) { url, _ in
            guard let url else { return }
            Task { @MainActor in model.load(url: url) }
        }
        return true
    }
}
