//
//  SpectrumAnalyzer.swift
//  RimeoAgent (macOS)
//
//  "Check quality (spec)" — desktop spectral analysis of any audio file, a native
//  replacement for Spek (Intel-only, dies with Rosetta). Decodes via AVAudioFile
//  (WAV / AIFF / MP3 / m4a / FLAC), falling back to the bundled ffmpeg for anything
//  AVFoundation can't open. Runs an STFT (vDSP), renders a Spek-style spectrogram
//  and derives a fidelity verdict from the effective high-frequency cut-off.
//  Audio bytes are never modified — analysis only.
//
//  The DSP is a faithful port of Spek's pipeline (github.com/alexkay/spek) so a file
//  looks the same here as in Spek:
//    • the WHOLE file is mapped across the width (not a representative slice);
//    • per output column, several FFT frames are averaged in the dB domain;
//    • magnitude → dB is 10·log10((re²+im²)/nfft²), i.e. referenced to 0 dBFS
//      (absolute full scale), NOT to the loudest bin observed;
//    • colours use a fixed [−120 … 0] dB range and Spek's SoX palette.
//

import Foundation
import AVFoundation
import Accelerate
import CoreGraphics

struct SpectrumResult {
    enum Verdict { case genuine, limited, unknown }

    let image: CGImage          // spectrogram: frequency on Y (top = high), time on X
    let sampleRate: Double
    let nyquist: Double          // real Nyquist of the file (sr/2)
    let ceilingHz: Double        // display ceiling of the Y axis (≥24 kHz; black above Nyquist)
    let cutoffHz: Double         // highest frequency that still carries real energy
    let bitDepth: Int?           // PCM bit depth (WAV/AIFF); nil for lossy / transcoded
    let durationSec: Double
    let formatLabel: String      // container extension, upper-cased (e.g. "WAV")
    let verdict: Verdict
}

enum SpectrumAnalyzer {

    // Cut-off detection (calibrated on known lossless / 320 / 128 files).
    private static let floorDropDB: Float = 50      // energy below ref-50dB is treated as noise floor
    private static let genuineHz: Double  = 18_500  // cut-off at/above this ⇒ full-range

    // DSP / rendering.
    private static let fftSize   = 2048             // Spek's default window (W:2048)
    private static let maxSeconds = 1200.0          // memory cap (~211 MB mono @44.1k); whole file if shorter
    private static let imgCols   = 900              // time resolution (X)
    private static let imgRows   = 384              // frequency resolution (Y)

    // Spek colour range: values are clamped to [dbFloor … dbCeil] then mapped 0…1.
    private static let dbFloor: Float = -120        // Spek LRANGE
    private static let dbCeil:  Float = 0           // Spek URANGE (0 dBFS)

    /// Heavy — call off the main thread.
    static func analyze(url: URL) -> SpectrumResult? {
        let formatLabel = url.pathExtension.uppercased()

        // Primary: decode natively (keeps true sample rate + bit depth).
        // Fallback: transcode via bundled ffmpeg for formats AVFoundation won't open.
        var transcodedTemp: URL?
        defer { if let t = transcodedTemp { try? FileManager.default.removeItem(at: t) } }

        var file = try? AVAudioFile(forReading: url)
        if file == nil, let temp = decodeViaFFmpeg(url: url) {
            transcodedTemp = temp
            file = try? AVAudioFile(forReading: temp)
        }
        guard let file else { return nil }

        let format = file.processingFormat
        let sr = format.sampleRate
        let total = file.length
        guard sr > 0, total > 0 else { return nil }

        let durationSec = Double(total) / sr

        // Read the whole file (capped), mono-mixed. Spek maps the entire track across
        // the width, so we analyse everything rather than a representative span.
        let wantFrames = AVAudioFramePosition(min(Double(total), maxSeconds * sr))
        file.framePosition = 0
        guard let mono = readMono(file: file, format: format, frames: AVAudioFrameCount(wantFrames)),
              mono.count >= fftSize else {
            return nil
        }

        let bins  = fftSize / 2
        let binHz = sr / Double(fftSize)

        // --- vDSP setup ---
        let log2n = vDSP_Length(log2(Float(fftSize)))
        guard let setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2)) else { return nil }
        defer { vDSP_destroy_fftsetup(setup) }

        var window = [Float](repeating: 0, count: fftSize)
        vDSP_hann_window(&window, vDSP_Length(fftSize), Int32(vDSP_HANN_DENORM))   // plain 0.5(1-cos), like Spek

        var windowed = [Float](repeating: 0, count: fftSize)
        var realp    = [Float](repeating: 0, count: bins)
        var imagp    = [Float](repeating: 0, count: bins)
        var frameDB  = [Float](repeating: 0, count: bins)

        // vDSP's real forward FFT is scaled by 2 vs the textbook DFT, so |bin|² is 4×
        // the value Spek's FFTW path produces. Undo that and divide by nfft² to match
        // Spek's 10·log10((re²+im²)/nfft²) referenced to 0 dBFS.
        let normDiv: Float = 4.0 * Float(fftSize) * Float(fftSize)

        // Fill `frameDB` with the dB spectrum of the FFT frame starting at `start`.
        func computeFrameDB(at start: Int) {
            mono.withUnsafeBufferPointer { mp in
                vDSP_vmul(mp.baseAddress! + start, 1, window, 1, &windowed, 1, vDSP_Length(fftSize))
            }
            realp.withUnsafeMutableBufferPointer { rp in
                imagp.withUnsafeMutableBufferPointer { ip in
                    var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                    windowed.withUnsafeBufferPointer { wp in
                        wp.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: bins) { cp in
                            vDSP_ctoz(cp, 2, &split, 1, vDSP_Length(bins))
                        }
                    }
                    vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
                    vDSP_zvmags(&split, 1, &frameDB, 1, vDSP_Length(bins))   // re²+im²
                }
            }
            var scale = 1.0 / normDiv
            vDSP_vsmul(frameDB, 1, &scale, &frameDB, 1, vDSP_Length(bins))   // power / (4·nfft²)
            var eps: Float = 1e-13
            vDSP_vsadd(frameDB, 1, &eps, &frameDB, 1, vDSP_Length(bins))     // avoid log(0)
            var n = Int32(bins)
            vvlog10f(&frameDB, frameDB, &n)                                  // log10
            var ten: Float = 10
            vDSP_vsmul(frameDB, 1, &ten, &frameDB, 1, vDSP_Length(bins))     // → dB
        }

        // Per-column dB (averaged over the frames in that column) + per-bin peak dB
        // over the whole file (for cut-off detection).
        var colDB  = [[Float]](repeating: [Float](repeating: dbFloor, count: bins), count: imgCols)
        var peakDB = [Float](repeating: -200, count: bins)
        var accum  = [Float](repeating: 0, count: bins)

        let samplesPerCol = Double(mono.count) / Double(imgCols)
        let lastStart = mono.count - fftSize

        for col in 0..<imgCols {
            let colStart = Int(Double(col) * samplesPerCol)
            let colEnd   = Int(Double(col + 1) * samplesPerCol)
            vDSP_vclr(&accum, 1, vDSP_Length(bins))
            var n = 0
            var pos = colStart
            repeat {
                if pos >= 0 && pos + fftSize <= mono.count {
                    computeFrameDB(at: pos)
                    vDSP_vadd(accum, 1, frameDB, 1, &accum, 1, vDSP_Length(bins))
                    vDSP_vmax(peakDB, 1, frameDB, 1, &peakDB, 1, vDSP_Length(bins))
                    n += 1
                }
                pos += fftSize
            } while pos < colEnd
            // Column shorter than one FFT (short file / many columns): take a single
            // frame at the clamped start so no column is left blank.
            if n == 0 {
                let p = min(max(0, colStart), lastStart)
                if p >= 0 {
                    computeFrameDB(at: p)
                    vDSP_vadd(accum, 1, frameDB, 1, &accum, 1, vDSP_Length(bins))
                    vDSP_vmax(peakDB, 1, frameDB, 1, &peakDB, 1, vDSP_Length(bins))
                    n = 1
                }
            }
            if n > 0 {
                var inv = 1.0 / Float(n)
                vDSP_vsmul(accum, 1, &inv, &colDB[col], 1, vDSP_Length(bins))
            }
        }

        let cutoffHz = detectCutoff(peakDB: peakDB, binHz: binHz, bins: bins, sr: sr)
        let nyquist  = sr / 2
        // Fixed 24 kHz display ceiling so 44.1 kHz files aren't visually "cut" at
        // 22 kHz and all spectrograms share one scale; grows for hi-res (>48 kHz).
        let ceilingHz = max(nyquist, 24_000)
        let verdict: SpectrumResult.Verdict = cutoffHz >= min(genuineHz, nyquist - 1500) ? .genuine : .limited
        guard let image = renderImage(colDB: colDB, bins: bins, nyquist: nyquist, ceilingHz: ceilingHz) else { return nil }

        let bitDepth: Int? = transcodedTemp == nil
            ? file.fileFormat.settings[AVLinearPCMBitDepthKey] as? Int
            : nil

        return SpectrumResult(image: image, sampleRate: sr, nyquist: nyquist, ceilingHz: ceilingHz,
                              cutoffHz: cutoffHz, bitDepth: bitDepth,
                              durationSec: durationSec, formatLabel: formatLabel,
                              verdict: verdict)
    }

    // MARK: - ffmpeg fallback

    private static func decodeViaFFmpeg(url: URL) -> URL? {
        guard findBinary("ffmpeg") != nil else { return nil }
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("rimeo_spec_\(UUID().uuidString).wav")
        let r = runFFmpeg(
            ["-v", "error", "-i", url.path, "-c:a", "pcm_s16le", temp.path, "-y"],
            timeout: 180
        )
        guard r.success, FileManager.default.fileExists(atPath: temp.path) else {
            logger.warning("Spectrum ffmpeg decode failed: \(r.stderr)")
            return nil
        }
        return temp
    }

    // MARK: - Decode to mono Float

    private static func readMono(file: AVAudioFile, format: AVAudioFormat, frames: AVAudioFrameCount) -> [Float]? {
        var out = [Float]()
        out.reserveCapacity(Int(frames))
        let chunk: AVAudioFrameCount = 1 << 16
        var remaining = frames
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunk) else { return nil }

        while remaining > 0 {
            let want = min(chunk, remaining)
            buffer.frameLength = 0
            do { try file.read(into: buffer, frameCount: want) } catch { break }
            let n = Int(buffer.frameLength)
            if n == 0 { break }
            guard let ch = buffer.floatChannelData else { break }
            let chCount = Int(format.channelCount)
            if chCount <= 1 {
                let p = ch[0]
                for i in 0..<n { out.append(p[i]) }
            } else {
                for i in 0..<n {
                    var s: Float = 0
                    for c in 0..<chCount { s += ch[c][i] }
                    out.append(s / Float(chCount))
                }
            }
            remaining -= AVAudioFrameCount(n)
            if AVAudioFrameCount(n) < want { break }
        }
        return out.isEmpty ? nil : out
    }

    // MARK: - Cut-off detection (operates on per-bin peak dB)

    private static func detectCutoff(peakDB: [Float], binHz: Double, bins: Int, sr: Double) -> Double {
        // reference level: median of peak energy across a solid mid band (1–6 kHz)
        let lo = max(1, Int(1000 / binHz)), hi = min(bins - 1, Int(6000 / binHz))
        guard hi > lo else { return sr / 2 }
        let refSlice = (lo...hi).map { peakDB[$0] }.sorted()
        let refDB = refSlice[refSlice.count / 2]
        let threshold = refDB - floorDropDB

        // scan from the top down; first run of consecutive bins above threshold = real top
        let need = 3
        var run = 0
        for b in stride(from: bins - 1, through: 1, by: -1) {
            if peakDB[b] > threshold {
                run += 1
                if run >= need { return Double(b + need - 1) * binHz }
            } else {
                run = 0
            }
        }
        return 0
    }

    // MARK: - Spectrogram image

    private static func renderImage(colDB: [[Float]], bins: Int, nyquist: Double, ceilingHz: Double) -> CGImage? {
        let W = imgCols, H = imgRows
        let range = dbCeil - dbFloor
        var px = [UInt8](repeating: 0, count: W * H * 4)
        let (kr, kg, kb) = sox(0)   // level 0 = −120 dB = black, used for the "no data" cap above Nyquist

        for y in 0..<H {
            // Linear frequency axis over [0 … ceilingHz] (top = high). Rows above the
            // file's real Nyquist have no bins → paint the black "no data" cap.
            let fTopHz = (1.0 - Double(y)     / Double(H)) * ceilingHz
            let fBotHz = (1.0 - Double(y + 1) / Double(H)) * ceilingHz

            if fBotHz >= nyquist {
                for x in 0..<W {
                    let o = (y * W + x) * 4
                    px[o] = kr; px[o+1] = kg; px[o+2] = kb; px[o+3] = 255
                }
                continue
            }

            let hiHz = min(fTopHz, nyquist)
            var bLo = Int(fBotHz / nyquist * Double(bins - 1))
            var bHi = Int(hiHz   / nyquist * Double(bins - 1))
            if bLo < 0 { bLo = 0 }
            if bHi > bins - 1 { bHi = bins - 1 }
            if bHi < bLo { bHi = bLo }
            let cnt = Float(bHi - bLo + 1)

            for x in 0..<W {
                let col = colDB[x]
                var s: Float = 0
                for b in bLo...bHi { s += col[b] }
                let dB = s / cnt
                let level = min(1, max(0, (dB - dbFloor) / range))
                let (r, g, b) = sox(level)
                let o = (y * W + x) * 4
                px[o]   = r
                px[o+1] = g
                px[o+2] = b
                px[o+3] = 255
            }
        }

        let cs = CGColorSpaceCreateDeviceRGB()
        let info = CGImageAlphaInfo.premultipliedLast.rawValue
        return px.withUnsafeMutableBytes { raw -> CGImage? in
            guard let ctx = CGContext(data: raw.baseAddress, width: W, height: H, bitsPerComponent: 8,
                                      bytesPerRow: W * 4, space: cs, bitmapInfo: info) else { return nil }
            return ctx.makeImage()
        }
    }

    /// Spek's SoX palette (level 0…1 silence→loud → RGB 0…1). Shared source of truth
    /// for both the spectrogram render and the dB legend swatch in the UI.
    static func spekPaletteRGB(_ level: Double) -> (Double, Double, Double) {
        let l = min(1, max(0, level))
        var r = 0.0, g = 0.0, b = 0.0
        if l >= 0.13 && l < 0.73 {
            r = sin((l - 0.13) / 0.60 * .pi / 2.0)
        } else if l >= 0.73 {
            r = 1.0
        }
        if l >= 0.60 && l < 0.91 {
            g = sin((l - 0.60) / 0.31 * .pi / 2.0)
        } else if l >= 0.91 {
            g = 1.0
        }
        if l < 0.60 {
            b = 0.5 * sin(l / 0.6 * .pi)
        } else if l >= 0.78 {
            b = (l - 0.78) / 0.22
        }
        return (r, g, b)
    }

    private static func sox(_ level: Float) -> (UInt8, UInt8, UInt8) {
        let (r, g, b) = spekPaletteRGB(Double(level))
        return (UInt8(max(0, min(255, r * 255))),
                UInt8(max(0, min(255, g * 255))),
                UInt8(max(0, min(255, b * 255))))
    }
}
