import SwiftUI
import AVFoundation
import AVKit
import AppKit

// MARK: - Extension pour fixer la taille de la fenêtre (non redimensionnable)
struct WindowAccessor: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        DispatchQueue.main.async {
            if let window = NSApplication.shared.windows.first {
                window.styleMask.remove(.resizable)
                window.minSize = NSSize(width: 1000, height: 900)
                window.maxSize = NSSize(width: 1000, height: 900)
            }
        }
        return NSView()
    }
    
    func updateNSView(_ nsView: NSView, context: Context) {}
}

extension View {
    func disableWindowResizing() -> some View {
        self.background(WindowAccessor())
    }
}

// MARK: - AVPlayerView pour la prévisualisation
struct PlayerView: NSViewRepresentable {
    let player: AVPlayer
    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = .inline
        view.showsFullScreenToggleButton = true
        return view
    }
    func updateNSView(_ nsView: AVPlayerView, context: Context) {
        nsView.player = player
    }
}

// MARK: - Vue de prévisualisation (Sheet)
// Utilisation d'un DispatchSourceTimer haute fréquence pour tenter une actualisation toutes les 1 ms (logique)
struct PreviewSheetView: View {
    let player: AVPlayer
    let segments: [CMTimeRange]
    let dismiss: () -> Void
    
    @State private var highResTimer: DispatchSourceTimer?
    
    var body: some View {
        ZStack {
            Color.black.opacity(0.4)
                .edgesIgnoringSafeArea(.all)
                .onTapGesture { cleanupAndDismiss() }
            
            PlayerView(player: player)
                .frame(width: 800, height: 450)
                .cornerRadius(10)
                .shadow(radius: 10)
                .onTapGesture { }
            
            VStack {
                HStack {
                    Spacer()
                    Button(action: { cleanupAndDismiss() }) {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(.white)
                            .font(.largeTitle)
                    }
                    .buttonStyle(PlainButtonStyle())
                    .padding()
                }
                Spacer()
            }
        }
        .onAppear {
            player.automaticallyWaitsToMinimizeStalling = false
            player.play()
            setupHighResTimer()
        }
        .onDisappear {
            highResTimer?.cancel()
            highResTimer = nil
        }
    }
    
    // Mise en place d'un timer DispatchSource déclenché toutes les 1 ms
    func setupHighResTimer() {
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.main)
        timer.schedule(deadline: .now(), repeating: .milliseconds(1), leeway: .milliseconds(0))
        timer.setEventHandler { [self] in
            let currentTime = player.currentTime()
            guard let lastSegment = segments.last else { return }
            let tolerance = CMTime(seconds: 0.001, preferredTimescale: lastSegment.end.timescale)
            let endMinusTolerance = lastSegment.end - tolerance
            
            // Si le temps courant atteint ou dépasse la fin du dernier segment (avec tolérance), on ferme la prévisualisation.
            if currentTime >= lastSegment.start && currentTime >= endMinusTolerance {
                cleanupAndDismiss()
                return
            }
            // Si le temps courant n'appartient pas à un segment, on saute vers le prochain segment.
            if !segments.contains(where: { $0.start <= currentTime && currentTime < $0.end }) {
                if let nextSegment = segments.first(where: { $0.start > currentTime }) {
                    player.seek(to: nextSegment.start, toleranceBefore: .zero, toleranceAfter: .zero) { _ in
                        player.play()
                    }
                }
            }
        }
        highResTimer = timer
        timer.resume()
    }
    
    func cleanupAndDismiss() {
        highResTimer?.cancel()
        highResTimer = nil
        dismiss()
    }
}

// MARK: - Chargement de l'audio en RAM avec progression
func loadAudioSamples(from asset: AVAsset,
                      progressUpdate: @escaping (String) -> Void)
-> (samples: [Float], sampleRate: Double, channels: UInt32, timeScale: CMTimeScale)? {
    guard let audioTrack = asset.tracks(withMediaType: .audio).first else {
        progressUpdate("Piste audio non trouvée.")
        return nil
    }
    guard let formatDescRef = audioTrack.formatDescriptions.first else {
        progressUpdate("Impossible d'obtenir le format audio.")
        return nil
    }
    let formatDesc = formatDescRef as! CMAudioFormatDescription
    guard let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(formatDesc)?.pointee else {
        progressUpdate("Impossible d'obtenir le Stream Basic Description.")
        return nil
    }
    let sampleRate = asbd.mSampleRate
    let channels = asbd.mChannelsPerFrame
    let timeScale: CMTimeScale = 1000  // 1 ms de précision
    let expectedDuration = asset.duration.seconds
    
    guard let reader = try? AVAssetReader(asset: asset) else {
        progressUpdate("Erreur lors de la création de l'AVAssetReader.")
        return nil
    }
    let readerSettings: [String: Any] = [
        AVFormatIDKey: kAudioFormatLinearPCM,
        AVLinearPCMIsBigEndianKey: false,
        AVLinearPCMIsFloatKey: true,
        AVLinearPCMBitDepthKey: 32
    ]
    let output = AVAssetReaderTrackOutput(track: audioTrack, outputSettings: readerSettings)
    reader.add(output)
    
    var samples = [Float]()
    var currentSampleCount = 0
    let totalSamplesEstimated = Int(expectedDuration * sampleRate * Double(channels))
    let startTimeLocal = Date()
    
    reader.startReading()
    while let sampleBuffer = output.copyNextSampleBuffer() {
        if let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) {
            var length = 0
            var dataPointer: UnsafeMutablePointer<Int8>?
            if CMBlockBufferGetDataPointer(blockBuffer,
                                           atOffset: 0,
                                           lengthAtOffsetOut: nil,
                                           totalLengthOut: &length,
                                           dataPointerOut: &dataPointer) == noErr,
               let dataPointer = dataPointer {
                let sampleCount = length / MemoryLayout<Float>.size
                let bufferPointer = UnsafeBufferPointer<Float>(
                    start: UnsafeRawPointer(dataPointer).assumingMemoryBound(to: Float.self),
                    count: sampleCount
                )
                samples.append(contentsOf: bufferPointer)
                currentSampleCount += sampleCount
                
                let progress = min(Double(currentSampleCount) / Double(totalSamplesEstimated) * 100, 100)
                let elapsed = Date().timeIntervalSince(startTimeLocal)
                let averageTimePerSample = (currentSampleCount > 0) ? elapsed / Double(currentSampleCount) : 0
                let samplesLeft = Double(totalSamplesEstimated - currentSampleCount)
                let remainingTime = max(samplesLeft * averageTimePerSample, 0)
                progressUpdate(String(format: "Chargement audio : %.1f%%, temps restant ≈ %.1f s", progress, remainingTime))
            }
        }
    }
    let totalFrames = Double(samples.count) / Double(channels)
    let computedDuration = totalFrames / sampleRate
    progressUpdate(String(format:
        "Audio chargé (échantillons: %d, frames: %.0f), durée calculée = %.4f s, durée asset = %.1f s",
                           samples.count, totalFrames, computedDuration, expectedDuration))
    return (samples, sampleRate, channels, timeScale)
}

// MARK: - Détection des segments non silencieux avec précision 1 ms
func computeMaxRMS(samples: [Float],
                   sampleRate: Double,
                   channels: UInt32) -> Float {
    let totalFrames = samples.count / Int(channels)
    let framesPerMs = max(Int(round(sampleRate / 1000.0)), 1)
    var maxRMS: Float = 0
    for frameIndex in stride(from: 0, to: totalFrames, by: framesPerMs) {
        let windowEnd = min(frameIndex + framesPerMs, totalFrames)
        var sumSquares: Float = 0
        let sampleCount = (windowEnd - frameIndex) * Int(channels)
        for f in frameIndex..<windowEnd {
            for c in 0..<channels {
                let idx = f * Int(channels) + Int(c)
                sumSquares += samples[idx] * samples[idx]
            }
        }
        let rms = sqrt(sumSquares / Float(sampleCount))
        if rms > maxRMS {
            maxRMS = rms
        }
    }
    return maxRMS
}

func detectNonSilentSegmentsFromSamples(samples: [Float],
                                        sampleRate: Double,
                                        channels: UInt32,
                                        thresholdPercentage: Float,
                                        minSilenceDuration: Double,
                                        progressUpdate: @escaping (String) -> Void)
-> [CMTimeRange] {
    let totalFrames = samples.count / Int(channels)
    let framesPerMs = max(Int(round(sampleRate / 1000.0)), 1)
    let timeScale: CMTimeScale = 1000  // Précision 1 ms
    
    let maxRMS = computeMaxRMS(samples: samples, sampleRate: sampleRate, channels: channels)
    let silenceThreshold = (thresholdPercentage / 100.0) * maxRMS
    
    var silenceIntervals = [(startFrame: Int, endFrame: Int)]()
    var inSilence = false
    var silenceStartFrame = 0
    let startTimeLocal = Date()
    var frameIndex = 0
    
    while frameIndex < totalFrames {
        let progress = Double(frameIndex) / Double(totalFrames) * 100
        let elapsed = Date().timeIntervalSince(startTimeLocal)
        let avgTimePerFrame = frameIndex > 0 ? elapsed / Double(frameIndex) : 0
        let framesLeft = Double(totalFrames - frameIndex)
        let remainingTime = framesLeft * avgTimePerFrame
        DispatchQueue.main.async {
            progressUpdate(String(format: "Analyse audio : %.1f%%, temps restant ≈ %.1f s", progress, remainingTime))
        }
        
        let windowEnd = min(frameIndex + framesPerMs, totalFrames)
        var sumSquares: Float = 0
        let count = (windowEnd - frameIndex) * Int(channels)
        for f in frameIndex..<windowEnd {
            for c in 0..<channels {
                let idx = f * Int(channels) + Int(c)
                sumSquares += samples[idx] * samples[idx]
            }
        }
        let rms = sqrt(sumSquares / Float(count))
        
        if rms < silenceThreshold {
            if !inSilence {
                inSilence = true
                silenceStartFrame = frameIndex
            }
        } else {
            if inSilence {
                let silenceFrames = frameIndex - silenceStartFrame
                let silenceDuration = Double(silenceFrames) / sampleRate
                if silenceDuration >= minSilenceDuration {
                    silenceIntervals.append((startFrame: silenceStartFrame, endFrame: frameIndex))
                }
                inSilence = false
            }
        }
        frameIndex += framesPerMs
    }
    
    if inSilence {
        let silenceFrames = totalFrames - silenceStartFrame
        let silenceDuration = Double(silenceFrames) / sampleRate
        if silenceDuration >= minSilenceDuration {
            silenceIntervals.append((startFrame: silenceStartFrame, endFrame: totalFrames))
        }
    }
    
    var nonSilentSegments = [CMTimeRange]()
    var lastEnd = 0
    for interval in silenceIntervals {
        if interval.startFrame > lastEnd {
            let startSec = Double(lastEnd) / sampleRate
            let endSec = Double(interval.startFrame) / sampleRate
            let startCM = CMTime(seconds: startSec, preferredTimescale: timeScale)
            let endCM   = CMTime(seconds: endSec, preferredTimescale: timeScale)
            nonSilentSegments.append(CMTimeRange(start: startCM, end: endCM))
        }
        lastEnd = interval.endFrame
    }
    if lastEnd < totalFrames {
        let startSec = Double(lastEnd) / sampleRate
        let endSec = Double(totalFrames) / sampleRate
        let startCM = CMTime(seconds: startSec, preferredTimescale: timeScale)
        let endCM = CMTime(seconds: endSec, preferredTimescale: timeScale)
        nonSilentSegments.append(CMTimeRange(start: startCM, end: endCM))
    }
    
    DispatchQueue.main.async {
        progressUpdate("Analyse audio terminée.")
    }
    return nonSilentSegments
}

// Fonction auxiliaire (non utilisée si l'audio est déjà chargé)
func detectNonSilentSegmentsInRAM(for asset: AVAsset,
                                  thresholdPercentage: Float,
                                  minSilenceDuration: Double,
                                  progressUpdate: @escaping (String) -> Void) -> [CMTimeRange] {
    guard let result = loadAudioSamples(from: asset, progressUpdate: progressUpdate) else {
        return []
    }
    return detectNonSilentSegmentsFromSamples(samples: result.samples,
                                              sampleRate: result.sampleRate,
                                              channels: result.channels,
                                              thresholdPercentage: thresholdPercentage,
                                              minSilenceDuration: minSilenceDuration,
                                              progressUpdate: progressUpdate)
}

// MARK: - Vue principale
struct ContentView: View {
    @State private var videoURL: URL? = nil
    @State private var destinationDirectory: URL? = nil
    @State private var threshold: Float = 1.0        // Seuil par défaut 1%
    @State private var minSilenceDuration: Double = 0.5
    @State private var processing: Bool = false
    @State private var log: String = ""
    @State private var progressStatus: String = ""
    
    @State private var nonSilentSegments: [CMTimeRange] = []
    @State private var processedComposition: AVMutableComposition? = nil
    
    @State private var audioSamples: [Float] = []
    @State private var sampleRate: Double = 44100.0
    @State private var audioTimeScale: CMTimeScale = 1000
    
    @State private var showPreview: Bool = false
    @State private var showAlert: Bool = false
    @State private var alertMessage: String = ""
    
    var body: some View {
        VStack(alignment: .leading) {
            Text("Video Silence Cutter")
                .font(.largeTitle)
                .padding(.bottom)
            
            if let url = videoURL {
                Text("Fichier sélectionné : \(url.lastPathComponent)")
                    .padding(.bottom, 4)
            } else {
                Text("Aucun fichier sélectionné")
                    .padding(.bottom, 4)
            }
            
            Button("Importer une vidéo") {
                importVideo()
            }
            .padding(.bottom)
            
            Rectangle()
                .fill(Color.gray.opacity(0.2))
                .frame(height: 100)
                .overlay(Text("Glisser-déposer votre vidéo ici"))
                .onDrop(of: ["public.file-url"], isTargeted: nil, perform: handleDrop(providers:))
                .padding(.bottom)
            
            HStack {
                Button("Choisir dossier de destination") {
                    selectDestinationFolder()
                }
                if let destination = destinationDirectory {
                    Text("Dossier : \(destination.lastPathComponent)")
                    Button("Ouvrir dossier") {
                        openDestinationFolder()
                    }
                }
            }
            .padding(.bottom)
            
            HStack {
                Text("Seuil (%) : \(String(format: "%.1f", threshold))")
                Slider(value: $threshold, in: 1...100, step: 0.5)
            }
            .padding(.bottom)
            
            HStack {
                Text("Durée silence (s) : \(String(format: "%.2f", minSilenceDuration))")
                Slider(value: $minSilenceDuration, in: 0.1...2.0, step: 0.1)
            }
            .padding(.bottom)
            
            if !progressStatus.isEmpty {
                Text(progressStatus)
                    .foregroundColor(.blue)
                    .padding(.bottom)
            }
            
            HStack {
                Button("Traiter la vidéo") {
                    buildComposition()
                }
                .disabled(videoURL == nil || processing)
                
                Button("Prévisualiser") {
                    if !nonSilentSegments.isEmpty {
                        showPreview = true
                    } else {
                        alertMessage = "Veuillez traiter la vidéo d'abord."
                        showAlert = true
                    }
                }
                .disabled(videoURL == nil || processing)
                
                Button("Exporter la vidéo") {
                    if processedComposition != nil {
                        exportComposition()
                    } else {
                        alertMessage = "Veuillez traiter la vidéo d'abord."
                        showAlert = true
                    }
                }
                .disabled(videoURL == nil || processing)
            }
            .padding(.bottom)
            
            if processing {
                ProgressView("Traitement en cours...")
                    .padding(.bottom)
            }
            
            ScrollView {
                Text(log)
                    .padding()
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding()
        .frame(width: 1000, height: 900)
        .disableWindowResizing()
        .alert(isPresented: $showAlert) {
            Alert(title: Text("Information"),
                  message: Text(alertMessage),
                  dismissButton: .default(Text("OK")))
        }
        .overlay(previewOverlay)
    }
    
    @ViewBuilder
    private var previewOverlay: some View {
        if showPreview, let videoURL = videoURL {
            buildPreviewOverlay(videoURL)
        }
    }
    
    private func buildPreviewOverlay(_ url: URL) -> some View {
        let asset = AVAsset(url: url)
        let playerItem = AVPlayerItem(asset: asset)
        let player = AVPlayer(playerItem: playerItem)
        player.automaticallyWaitsToMinimizeStalling = false
        player.play()
        return PreviewSheetView(player: player, segments: nonSilentSegments) {
            showPreview = false
        }
        .transition(.opacity)
    }
    
    func importVideo() {
        let panel = NSOpenPanel()
        panel.allowedFileTypes = ["mov", "mp4", "m4v"]
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK {
            videoURL = panel.url
            nonSilentSegments = []
            processedComposition = nil
            progressStatus = ""
            
            if let url = videoURL {
                let asset = AVAsset(url: url)
                DispatchQueue.global(qos: .userInitiated).async {
                    if let result = loadAudioSamples(from: asset, progressUpdate: { update in
                        DispatchQueue.main.async {
                            progressStatus = update
                        }
                    }) {
                        DispatchQueue.main.async {
                            self.audioSamples = result.samples
                            self.sampleRate = result.sampleRate
                            self.audioTimeScale = result.timeScale
                            log += "Audio chargé en RAM (\(self.audioSamples.count) échantillons, rate=\(self.sampleRate), channels=\(result.channels)).\n"
                        }
                    }
                }
            }
        }
    }
    
    func handleDrop(providers: [NSItemProvider]) -> Bool {
        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier("public.file-url") {
                provider.loadItem(forTypeIdentifier: "public.file-url", options: nil) { data, _ in
                    DispatchQueue.main.async {
                        if let data = data as? Data,
                           let url = URL(dataRepresentation: data, relativeTo: nil) {
                            videoURL = url
                            nonSilentSegments = []
                            processedComposition = nil
                            progressStatus = ""
                            
                            let asset = AVAsset(url: url)
                            DispatchQueue.global(qos: .userInitiated).async {
                                if let result = loadAudioSamples(from: asset, progressUpdate: { update in
                                    DispatchQueue.main.async {
                                        progressStatus = update
                                    }
                                }) {
                                    DispatchQueue.main.async {
                                        self.audioSamples = result.samples
                                        self.sampleRate = result.sampleRate
                                        self.audioTimeScale = result.timeScale
                                        log += "Audio chargé en RAM (\(self.audioSamples.count) échantillons, rate=\(self.sampleRate), channels=\(result.channels)).\n"
                                    }
                                }
                            }
                        }
                    }
                }
                return true
            }
        }
        return false
    }
    
    func selectDestinationFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Choisir"
        if panel.runModal() == .OK {
            destinationDirectory = panel.url
        }
    }
    
    func openDestinationFolder() {
        if let destination = destinationDirectory {
            NSWorkspace.shared.open(destination)
        }
    }
    
    func buildComposition() {
        guard let videoURL = videoURL else { return }
        guard !audioSamples.isEmpty else {
            log += "Audio non chargé. Veuillez importer la vidéo.\n"
            return
        }
        
        processing = true
        log = "Début du traitement...\n"
        progressStatus = "Début du traitement vidéo..."
        
        let asset = AVAsset(url: videoURL)
        DispatchQueue.global(qos: .userInitiated).async {
            let segments = detectNonSilentSegmentsFromSamples(
                samples: self.audioSamples,
                sampleRate: self.sampleRate,
                channels: 2,  // À ajuster selon le nombre de canaux
                thresholdPercentage: self.threshold,
                minSilenceDuration: self.minSilenceDuration,
                progressUpdate: { update in
                    DispatchQueue.main.async {
                        progressStatus = update
                    }
                }
            )
            DispatchQueue.main.async {
                self.log += "Détection via RAM : \(segments.count) segments trouvés.\n"
                for seg in segments {
                    let st = CMTimeGetSeconds(seg.start)
                    let en = CMTimeGetSeconds(seg.end)
                    self.log += String(format: "Segment: %.3f s -> %.3f s\n", st, en)
                }
                self.nonSilentSegments = segments
            }
            
            let composition = AVMutableComposition()
            guard let videoTrack = asset.tracks(withMediaType: .video).first,
                  let audioTrack = asset.tracks(withMediaType: .audio).first,
                  let compVideoTrack = composition.addMutableTrack(withMediaType: .video,
                                                                   preferredTrackID: kCMPersistentTrackID_Invalid),
                  let compAudioTrack = composition.addMutableTrack(withMediaType: .audio,
                                                                   preferredTrackID: kCMPersistentTrackID_Invalid)
            else {
                DispatchQueue.main.async {
                    self.log += "Erreur : Pistes vidéo/audio introuvables.\n"
                    self.processing = false
                }
                return
            }
            
            let startTimeLocal = Date()
            var currentTime = CMTime.zero
            let totalSegments = segments.count
            
            for (index, originalSegment) in segments.enumerated() {
                let videoRange = videoTrack.timeRange
                let audioRange = audioTrack.timeRange
                let commonStart = max(videoRange.start, audioRange.start)
                let commonEnd = min(videoRange.start + videoRange.duration,
                                    audioRange.start + audioRange.duration)
                let intersectionRange = CMTimeRange(start: commonStart, end: commonEnd)
                
                var start = originalSegment.start
                var end = originalSegment.end
                if start < intersectionRange.start { start = intersectionRange.start }
                if end > intersectionRange.end { end = intersectionRange.end }
                let finalSegment = CMTimeRange(start: start, end: end)
                
                if finalSegment.duration > .zero {
                    do {
                        try compVideoTrack.insertTimeRange(finalSegment, of: videoTrack, at: currentTime)
                        try compAudioTrack.insertTimeRange(finalSegment, of: audioTrack, at: currentTime)
                    } catch {
                        DispatchQueue.main.async {
                            self.log += "Erreur sur le segment \(index + 1): \(error.localizedDescription)\n"
                        }
                    }
                    currentTime = currentTime + finalSegment.duration
                } else {
                    DispatchQueue.main.async {
                        self.log += "Segment \(index + 1) invalide après clamp, ignoré.\n"
                    }
                }
                
                let elapsed = Date().timeIntervalSince(startTimeLocal)
                let progressPct = Double(index + 1) / Double(totalSegments) * 100.0
                let avgTimePerSegment = elapsed / Double(index + 1)
                let remainingTime = max(avgTimePerSegment * Double(totalSegments - (index + 1)), 0)
                DispatchQueue.main.async {
                    self.progressStatus = String(format: "Traitement vidéo : %.1f%%, temps restant ≈ %.1f s", progressPct, remainingTime)
                }
            }
            
            DispatchQueue.main.async {
                self.processedComposition = composition
                self.log += "Traitement terminé, composition créée.\n"
                self.processing = false
                self.progressStatus = ""
            }
        }
    }
    
    func exportComposition() {
        guard let composition = processedComposition else { return }
        processing = true
        log += "Début de l'export...\n"
        
        let outputFolder = (destinationDirectory?.resolvingSymlinksInPath()) ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        let dateString = dateFormatter.string(from: Date())
        let outputFileName = "output_\(dateString).mp4"
        let outputURL = outputFolder.appendingPathComponent(outputFileName)
        log += "Chemin d'export : \(outputURL.path)\n"
        
        guard let exportSession = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetHighestQuality) else {
            log += "Erreur : Impossible de créer l'export session.\n"
            processing = false
            return
        }
        exportSession.outputURL = outputURL
        exportSession.outputFileType = .mp4
        exportSession.exportAsynchronously {
            DispatchQueue.main.async {
                if exportSession.status == .completed {
                    self.log += "Export terminé avec succès !\nFichier exporté à : \(outputURL.path)\n"
                    if self.destinationDirectory != nil {
                        NSWorkspace.shared.open(outputFolder)
                    }
                } else if let error = exportSession.error {
                    self.log += "Erreur d'export : \(error.localizedDescription)\n"
                }
                self.processing = false
            }
        }
    }
}

struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        ContentView()
    }
}
