//
//  CheckQualityView.swift
//  RimeoAgent (macOS)
//
//  "Check quality (spec)" UI: runs SpectrumAnalyzer on an opened / dropped audio
//  file and shows a Spek-style spectrogram with real axes (frequency, time, dB
//  legend) in the Rimeo Agent design language, plus a fidelity verdict and a
//  Save-PNG action. Shared between the stand-alone window (QualityWindowManager)
//  and the in-app "Check spek" tab (CheckSpekTabView).
//

import SwiftUI
import AppKit
import Combine
import CoreImage
import UniformTypeIdentifiers

// MARK: - View model

@MainActor
final class QualityModel: ObservableObject {
    enum State {
        case idle
        case loading
        case ready(SpectrumResult)
        case failed
    }

    @Published var state: State = .idle
    @Published var fileName: String = ""

    private var token = 0

    func load(url: URL) {
        fileName = url.deletingPathExtension().lastPathComponent
        state = .loading
        token &+= 1
        let myToken = token
        Task.detached(priority: .userInitiated) {
            let res = SpectrumAnalyzer.analyze(url: url)
            await MainActor.run {
                guard myToken == self.token else { return }   // ignore stale analysis
                logger.info("Quality analysis done: \(url.lastPathComponent) → \(res == nil ? "FAILED" : "ok")")
                self.state = res.map(State.ready) ?? .failed
            }
        }
    }
}

// MARK: - Stand-alone window root

struct CheckQualityRootView: View {
    @EnvironmentObject var model: QualityModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                header
                switch model.state {
                case .idle, .loading: SpekLoadingView()
                case .failed:         SpekFailedView()
                case .ready(let r):   SpekResultView(result: r, fileName: model.fileName, titleTrailingReserve: 104)
                }
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 22)
            .frame(maxWidth: .infinity, alignment: .leading)
            // QR floats in the top-right corner (overlay) so it never adds height to
            // the header — keeps the header→track spacing compact.
            .overlay(alignment: .topTrailing) {
                SpekQRView(size: 84).padding(.top, 22).padding(.trailing, 24)
            }
        }
        .background(C.bg.ignoresSafeArea())
        .onDrop(of: [UTType.fileURL], isTargeted: nil, perform: handleDrop)
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first else { return false }
        _ = provider.loadObject(ofClass: URL.self) { url, _ in
            guard let url else { return }
            Task { @MainActor in model.load(url: url) }
        }
        return true
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("Check quality")
                .font(.system(size: 23, weight: .bold))
                .foregroundColor(C.text)
            Text("Frequency analysis · spek")
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(C.dim)
        }
        .padding(.bottom, 18)
    }
}

// MARK: - Shared state views

struct SpekLoadingView: View {
    var body: some View {
        VStack(spacing: 14) {
            ProgressView().controlSize(.large)
            Text("Analyzing audio…")
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(C.secondary)
        }
        .frame(maxWidth: .infinity).padding(.vertical, 90)
    }
}

struct SpekFailedView: View {
    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "waveform.slash").font(.system(size: 34)).foregroundColor(C.dim)
            Text("Couldn't analyze this file")
                .font(.system(size: 16, weight: .semibold)).foregroundColor(C.text)
            Text("The file couldn't be decoded. Try another audio file.")
                .font(.system(size: 13)).foregroundColor(C.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity).padding(.vertical, 70).padding(.horizontal, 20)
    }
}

// MARK: - Result body (chips + verdict + chart + how-to-read + save)

struct SpekResultView: View {
    let result: SpectrumResult
    let fileName: String
    /// Horizontal space to keep clear on the right of the title/chips row so the
    /// floating QR code (top-right overlay) never overlaps them.
    var titleTrailingReserve: CGFloat = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 11) {
                Text(fileName.isEmpty ? "Untitled" : fileName)
                    .font(.system(size: 17, weight: .semibold)).foregroundColor(C.text)
                    .lineLimit(2)
                MetaChips(result: result)
            }
            .padding(.trailing, titleTrailingReserve)
            VerdictBadge(verdict: result.verdict, cutoffHz: result.cutoffHz).padding(.top, 18)
            SpekChart(image: result.image, ceilingHz: result.ceilingHz, durationSec: result.durationSec)
                .padding(.top, 18)
            howToRead.padding(.top, 16)
        }
    }

    private var howToRead: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("HOW TO READ").font(.system(size: 12, weight: .semibold)).tracking(0.4).foregroundColor(C.text)
            Text("Top of the chart = highest frequencies. Real lossless reaches well above 16 kHz. If a file doesn't go past ~16 kHz, it's most likely a re-encoded (lossy) version.")
                .font(.system(size: 13)).foregroundColor(C.secondary).lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(C.surf)
        .overlay(RoundedRectangle(cornerRadius: 13).stroke(C.cardBrd, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
    }
}

// MARK: - Spek chart (spectrogram + frequency / time / dB axes, in our style)

struct SpekChart: View {
    let image: CGImage
    let ceilingHz: Double
    let durationSec: Double

    var chartHeight: CGFloat = 232
    private let axisW: CGFloat   = 30    // left frequency gutter
    private let legendW: CGFloat = 44    // right dB legend (bar + labels)
    private let timeH: CGFloat   = 15    // bottom time axis

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .top, spacing: 7) {
                freqAxis.frame(width: axisW, height: chartHeight)
                spectrogram.frame(height: chartHeight).frame(maxWidth: .infinity)
                dbLegend.frame(width: legendW, height: chartHeight)
            }
            HStack(spacing: 7) {
                Spacer(minLength: 0).frame(width: axisW)
                timeAxis.frame(height: timeH).frame(maxWidth: .infinity)
                Spacer(minLength: 0).frame(width: legendW)
            }
        }
    }

    // Spectrogram image + subtle gridlines aligned to the freq / time ticks.
    private var spectrogram: some View {
        Image(nsImage: NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height)))
            .resizable()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            .overlay(gridOverlay)
            .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).stroke(C.cardBrd, lineWidth: 1))
    }

    private var gridOverlay: some View {
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                ForEach(freqTicks.filter { $0.f > 1 && $0.f < ceilingHz - 1 }) { t in
                    let y = CGFloat(1 - t.f / ceilingHz) * geo.size.height
                    Rectangle()
                        .fill(Color.white.opacity(t.emph ? 0.22 : 0.1))
                        .frame(width: geo.size.width, height: t.emph ? 1 : 0.5)
                        .offset(y: y)
                }
                ForEach(timeTicks.filter { $0.t > 1 && $0.t < durationSec - 1 }) { tk in
                    let x = CGFloat(tk.t / durationSec) * geo.size.width
                    Rectangle()
                        .fill(Color.white.opacity(0.06))
                        .frame(width: 0.5, height: geo.size.height)
                        .offset(x: x)
                }
            }
        }
    }

    // Left frequency axis.
    private var freqAxis: some View {
        GeometryReader { geo in
            ForEach(freqTicks) { t in
                let y = CGFloat(1 - t.f / ceilingHz) * geo.size.height
                Text(t.label)
                    .font(.system(size: 9.5, weight: t.emph ? .semibold : .medium, design: .monospaced))
                    .foregroundColor(t.emph ? C.secondary : C.dim)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .position(x: geo.size.width / 2, y: min(max(y, 6), geo.size.height - 6))
            }
        }
    }

    // Bottom time axis.
    private var timeAxis: some View {
        GeometryReader { geo in
            ForEach(timeTicks) { tk in
                let x = CGFloat(tk.t / max(durationSec, 0.001)) * geo.size.width
                Text(tk.label)
                    .font(.system(size: 8.5, weight: .medium, design: .monospaced))
                    .foregroundColor(C.dim)
                    .fixedSize()
                    .position(x: min(max(x, 15), geo.size.width - 15), y: 7)
            }
        }
    }

    // Right dB legend (0 … −120 dB), coloured with the same SoX palette.
    private var dbLegend: some View {
        HStack(spacing: 4) {
            RoundedRectangle(cornerRadius: 3, style: .continuous)
                .fill(LinearGradient(gradient: Gradient(stops: legendStops), startPoint: .top, endPoint: .bottom))
                .frame(width: 7)
                .overlay(RoundedRectangle(cornerRadius: 3, style: .continuous).stroke(C.cardBrd, lineWidth: 0.5))
            GeometryReader { geo in
                ForEach(dbLabels, id: \.self) { db in
                    let y = CGFloat(Double(-db) / 120.0) * geo.size.height
                    Text(db == 0 ? "0" : "\(db)")
                        .font(.system(size: 8, weight: .medium, design: .monospaced))
                        .foregroundColor(C.dim)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .position(x: geo.size.width / 2, y: min(max(y, 5), geo.size.height - 5))
                }
            }
        }
    }

    // MARK: ticks

    private struct FreqTick: Identifiable { let id = UUID(); let f: Double; let label: String; let emph: Bool }
    private struct TimeTick: Identifiable { let id = UUID(); let t: Double; let label: String }

    private var freqTicks: [FreqTick] {
        var out: [FreqTick] = []
        var f = 0.0
        while f <= ceilingHz - 1500 {
            let k = Int((f / 1000).rounded())
            out.append(FreqTick(f: f, label: f < 1 ? "0" : "\(k)k", emph: abs(f - 16000) < 1))
            f += 4000
        }
        out.append(FreqTick(f: ceilingHz, label: "\(Int((ceilingHz / 1000).rounded()))k", emph: false))
        return out
    }

    private var timeTicks: [TimeTick] {
        guard durationSec > 0 else { return [] }
        // One tick per minute (0:00, 1:00, 2:00 …); widen for long files so labels
        // don't crowd (2 min up to 26 min, then 5 min).
        let step: Double = durationSec <= 780 ? 60 : (durationSec <= 1560 ? 120 : 300)
        var out: [TimeTick] = []
        var t = 0.0
        while t <= durationSec + 0.5 {
            out.append(TimeTick(t: t, label: fmt(t)))
            t += step
        }
        return out
    }

    private func fmt(_ s: Double) -> String {
        String(format: "%d:%02d", Int(s) / 60, Int(s) % 60)
    }

    private let dbLabels = [0, -20, -40, -60, -80, -100, -120]

    private var legendStops: [Gradient.Stop] {
        let n = 24
        return (0...n).map { i in
            let loc = Double(i) / Double(n)        // 0 = top (0 dB)
            let (r, g, b) = SpectrumAnalyzer.spekPaletteRGB(1 - loc)
            return Gradient.Stop(color: Color(.sRGB, red: r, green: g, blue: b, opacity: 1), location: loc)
        }
    }
}

// MARK: - Verdict badge

struct VerdictBadge: View {
    let verdict: SpectrumResult.Verdict
    let cutoffHz: Double

    private var isGenuine: Bool { verdict == .genuine }
    private var title: String { isGenuine ? "Genuine lossless" : "High frequencies limited" }
    private var subtitle: String {
        isGenuine ? "Extends well above 16 kHz"
                  : "Energy rolls off around \(Int((cutoffHz / 1000).rounded())) kHz"
    }

    var body: some View {
        HStack(spacing: 13) {
            ZStack {
                Circle().fill(isGenuine ? C.green : C.amber)
                Image(systemName: isGenuine ? "checkmark" : "exclamationmark")
                    .font(.system(size: 18, weight: .bold))
                    .foregroundColor(.white)
            }
            .frame(width: 40, height: 40)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 16, weight: .semibold)).foregroundColor(C.text)
                Text(subtitle).font(.system(size: 13, weight: .medium)).foregroundColor(C.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(15)
        .background((isGenuine ? C.green : C.amber).opacity(0.12))
        .overlay(RoundedRectangle(cornerRadius: 15).stroke((isGenuine ? C.green : C.amber).opacity(0.32), lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 15, style: .continuous))
    }
}

// MARK: - Metadata chips

private struct MetaChips: View {
    let result: SpectrumResult

    private var items: [String] {
        var out: [String] = []
        if !result.formatLabel.isEmpty { out.append(result.formatLabel) }
        out.append(String(format: "%.1f kHz", result.sampleRate / 1000))
        if let bd = result.bitDepth { out.append("\(bd)-bit") }
        if result.durationSec > 0 {
            out.append(String(format: "%d:%02d", Int(result.durationSec) / 60, Int(result.durationSec) % 60))
        }
        return out
    }

    var body: some View {
        HStack(spacing: 7) {
            ForEach(items, id: \.self) { s in
                Text(s)
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .foregroundColor(C.body)
                    .padding(.vertical, 6).padding(.horizontal, 11)
                    .background(C.chip)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            }
        }
    }
}

// MARK: - QR code (→ rimeo.app)

/// QR to rimeo.app, transparent background, modules in #1F2127. Rendered once and
/// cached per (url,color) so it isn't rebuilt on every SwiftUI layout pass.
struct SpekQRView: View {
    var url = "https://rimeo.app"
    /// #1F2127
    var moduleColor = NSColor(srgbRed: 0x1F / 255.0, green: 0x21 / 255.0, blue: 0x27 / 255.0, alpha: 1)
    var size: CGFloat = 84

    var body: some View {
        Group {
            if let img = SpekQRGen.make(url, color: moduleColor) {
                Image(nsImage: img).interpolation(.none).resizable()
            } else {
                Color.clear
            }
        }
        .frame(width: size, height: size)
        .accessibilityLabel("QR code to rimeo.app")
    }
}

enum SpekQRGen {
    nonisolated(unsafe) private static var cache: [String: NSImage] = [:]

    static func make(_ string: String, color: NSColor, scale: CGFloat = 12) -> NSImage? {
        let key = "\(string)|\(color.hashValue)"
        if let hit = cache[key] { return hit }
        guard let qr = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        qr.setValue(Data(string.utf8), forKey: "inputMessage")
        qr.setValue("M", forKey: "inputCorrectionLevel")
        guard let base = qr.outputImage else { return nil }

        // Recolour: black modules → `color`, white background → transparent.
        guard let fc = CIFilter(name: "CIFalseColor") else { return nil }
        fc.setValue(base, forKey: "inputImage")
        fc.setValue(CIColor(cgColor: color.cgColor), forKey: "inputColor0")
        fc.setValue(CIColor(red: 0, green: 0, blue: 0, alpha: 0), forKey: "inputColor1")
        guard let out = fc.outputImage?.transformed(by: CGAffineTransform(scaleX: scale, y: scale)) else { return nil }

        let ctx = CIContext()
        guard let cg = ctx.createCGImage(out, from: out.extent) else { return nil }
        let img = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
        cache[key] = img
        return img
    }
}
