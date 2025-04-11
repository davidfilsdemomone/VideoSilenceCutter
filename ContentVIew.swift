import SwiftUI
import AVFoundation
import AVKit
import AppKit
import Accelerate

// ===================================================
// MARK: - Fonction de normalisation
// ===================================================
func normalizeSamples(_ samples: [Float]) -> [Float] {
    var absSamples = [Float](repeating: 0, count: samples.count)
    vDSP_vabs(samples, 1, &absSamples, 1, vDSP_Length(samples.count))
    var maxVal: Float = 0
    vDSP_maxv(absSamples, 1, &maxVal, vDSP_Length(samples.count))
    if maxVal <= 1 { return samples }
    var normalized = [Float](repeating: 0, count: samples.count)
    var divisor = maxVal
    vDSP_vsdiv(samples, 1, &divisor, &normalized, 1, vDSP_Length(samples.count))
    return normalized
}

// ===================================================
// MARK: - Calcul du max RMS (pour affichage)
// ===================================================
func computeMaxRMS(samples: [Float],
                   sampleRate: Double,
                   channels: UInt32) -> Float {
    let totalSamples = samples.count
    let framesPerMs = max(Int(round(sampleRate / 1000.0)), 1)
    var maxRMS: Float = 0
    
    var squares = [Float](repeating: 0, count: samples.count)
    vDSP_vsq(samples, 1, &squares, 1, vDSP_Length(samples.count))
    
    let blockSize = framesPerMs * Int(channels)
    let numBlocks = Int(ceil(Double(totalSamples) / Double(blockSize)))
    for block in 0..<numBlocks {
        let start = block * blockSize
        if start >= totalSamples { break }
        let currentBlockSize = min(blockSize, totalSamples - start)
        var sum: Float = 0
        vDSP_sve(&squares[start], 1, &sum, vDSP_Length(currentBlockSize))
        let rms = sqrt(sum / Float(currentBlockSize))
        if rms > maxRMS { maxRMS = rms }
    }
    return maxRMS
}

// ===================================================
// MARK: - Calcul du max RMS avec progression
// ===================================================
func computeMaxRMSWithProgress(samples: [Float],
                               sampleRate: Double,
                               channels: UInt32,
                               progressUpdate: @escaping (String) -> Void,
                               completion: @escaping (Float) -> Void) {
    DispatchQueue.global(qos: .userInitiated).async {
        let totalSamples = samples.count
        let framesPerMs = max(Int(round(sampleRate / 1000.0)), 1)
        var maxRMS: Float = 0
        
        var squares = [Float](repeating: 0, count: samples.count)
        vDSP_vsq(samples, 1, &squares, 1, vDSP_Length(samples.count))
        
        let blockSize = framesPerMs * Int(channels)
        let numBlocks = Int(ceil(Double(totalSamples) / Double(blockSize)))
        let startTime = Date()
        
        for block in 0..<numBlocks {
            let start = block * blockSize
            if start >= totalSamples { break }
            let currentBlockSize = min(blockSize, totalSamples - start)
            var sum: Float = 0
            vDSP_sve(&squares[start], 1, &sum, vDSP_Length(currentBlockSize))
            let rms = sqrt(sum / Float(currentBlockSize))
            if rms > maxRMS { maxRMS = rms }
            
            if block % 100 == 0 {
                let progress = Double(block + 1) / Double(numBlocks) * 100
                let elapsed = Date().timeIntervalSince(startTime)
                let estimatedTotalTime = elapsed * Double(numBlocks) / Double(block + 1)
                let remainingTime = max(estimatedTotalTime - elapsed, 0)
                let progressString = String(format: "Détection max dB : %.1f%%, temps restant ≈ %.1f s", progress, remainingTime)
                DispatchQueue.main.async {
                    progressUpdate(progressString)
                }
            }
        }
        DispatchQueue.main.async {
            completion(maxRMS)
        }
    }
}

// ===================================================
// MARK: - Extension pour fixer la taille de la fenêtre
// ===================================================
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

// ===================================================
// MARK: - AVPlayerView pour la prévisualisation
// ===================================================
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

// ===================================================
// MARK: - Vue de prévisualisation (Sheet)
// ===================================================
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
    
    func setupHighResTimer() {
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.main)
        timer.schedule(deadline: .now(), repeating: .milliseconds(1), leeway: .milliseconds(0))
        timer.setEventHandler { [self] in
            let currentTime = player.currentTime()
            guard let lastSegment = segments.last else { return }
            let tolerance = CMTime(seconds: 0.001, preferredTimescale: lastSegment.end.timescale)
            let endMinusTolerance = lastSegment.end - tolerance
            
            if currentTime >= lastSegment.start && currentTime >= endMinusTolerance {
                cleanupAndDismiss()
                return
            }
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

// ===================================================
// MARK: - Chargement de l'audio avec progression
// ===================================================
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
    let timeScale: CMTimeScale = 1000  // 1 ms
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
                    count: sampleCount)
                samples.append(contentsOf: bufferPointer)
                currentSampleCount += sampleCount
                
                let progress = min(Double(currentSampleCount) / Double(totalSamplesEstimated) * 100, 100)
                let elapsed = Date().timeIntervalSince(startTimeLocal)
                let averageTimePerSample = (Double(currentSampleCount) > 0) ? elapsed / Double(currentSampleCount) : 0
                let samplesLeft = Double(totalSamplesEstimated - currentSampleCount)
                let remainingTime = max(samplesLeft * averageTimePerSample, 0)
                progressUpdate(String(format: "Chargement audio : %.1f%%, temps restant ≈ %.1f s", progress, remainingTime))
            }
        }
    }
    let totalFrames = Double(samples.count) / Double(channels)
    let computedDuration = totalFrames / sampleRate
    progressUpdate(String(format: "Audio chargé (échantillons: %d, frames: %.0f), durée calculée = %.4f s, durée asset = %.1f s", samples.count, totalFrames, computedDuration, expectedDuration))
    let normalizedSamples = normalizeSamples(samples)
    return (normalizedSamples, sampleRate, channels, timeScale)
}

// ===================================================
// MARK: - Détection des segments non silencieux par suppression stricte du silence
//
// Cette fonction découpe l’audio en fenêtres de 10 ms avec recouvrement de 5 ms.
// Pour chaque fenêtre, on calcule le niveau RMS en dB et on la marque comme silencieuse
// si le niveau est inférieur à silenceThresholddB (ici réglable via l’interface, défaut = -50 dB).
// Ensuite, les fenêtres silencieuses consécutives dont la durée totale est ≥ minSilenceDuration sont considérées comme des silences à retirer.
// Les segments non silencieux sont alors déduits comme l’ensemble des intervalles hors de ces silences.
func detectNonSilentSegmentsByRemovingSilence(samples: [Float],
                                                sampleRate: Double,
                                                channels: UInt32,
                                                silenceThresholddB: Float,
                                                minSilenceDuration: Double,
                                                progressUpdate: @escaping (String) -> Void)
-> [CMTimeRange] {
    let windowDuration: Double = 0.01  // 10 ms
    let hopDuration: Double = 0.005      // 5 ms de recouvrement
    let windowFrameCount = Int(sampleRate * windowDuration)
    let hopFrameCount = Int(sampleRate * hopDuration)
    let totalFrames = samples.count / Int(channels)
    let totalWindows = max(0, ((totalFrames - windowFrameCount) / hopFrameCount) + 1)
    
    var silenceWindowTimes = [(start: Double, end: Double)]()
    for i in 0..<totalWindows {
        let startFrame = i * hopFrameCount
        let sampleStartIndex = startFrame * Int(channels)
        let sampleEndIndex = sampleStartIndex + windowFrameCount * Int(channels)
        let endIndex = min(sampleEndIndex, samples.count)
        let windowSamples = Array(samples[sampleStartIndex..<endIndex])
        var rms: Float = 0
        vDSP_rmsqv(windowSamples, 1, &rms, vDSP_Length(windowSamples.count))
        let rmsdB = 20 * log10(rms + 1e-9)
        let windowStartTime = Double(i) * hopDuration
        let windowEndTime = windowStartTime + windowDuration
        if rmsdB < silenceThresholddB {
            silenceWindowTimes.append((start: windowStartTime, end: windowEndTime))
        }
        if i % 100 == 0 {
            let progress = Double(i) / Double(totalWindows) * 100
            DispatchQueue.main.async {
                progressUpdate(String(format: "Analyse silence : %.1f%%", progress))
            }
        }
    }
    
    var removalIntervals = [(start: Double, end: Double)]()
    if !silenceWindowTimes.isEmpty {
        var currentStart = silenceWindowTimes[0].start
        var currentEnd = silenceWindowTimes[0].end
        for entry in silenceWindowTimes.dropFirst() {
            if entry.start <= currentEnd + 0.001 {
                currentEnd = entry.end
            } else {
                if currentEnd - currentStart >= minSilenceDuration {
                    removalIntervals.append((start: currentStart, end: currentEnd))
                }
                currentStart = entry.start
                currentEnd = entry.end
            }
        }
        if currentEnd - currentStart >= minSilenceDuration {
            removalIntervals.append((start: currentStart, end: currentEnd))
        }
    }
    
    let audioDuration = Double(totalFrames) / sampleRate
    var nonSilentSegments = [CMTimeRange]()
    var previousEnd = 0.0
    for interval in removalIntervals {
        if interval.start > previousEnd {
            nonSilentSegments.append(
                CMTimeRange(start: CMTime(seconds: previousEnd, preferredTimescale: 1000),
                            end: CMTime(seconds: interval.start, preferredTimescale: 1000))
            )
        }
        previousEnd = interval.end
    }
    if previousEnd < audioDuration {
        nonSilentSegments.append(
            CMTimeRange(start: CMTime(seconds: previousEnd, preferredTimescale: 1000),
                        end: CMTime(seconds: audioDuration, preferredTimescale: 1000))
        )
    }
    
    DispatchQueue.main.async {
        progressUpdate("Analyse segments terminée.")
    }
    return nonSilentSegments
}

// ===================================================
// MARK: - Vue principale
// ===================================================
struct ContentView: View {
    @State private var videoURL: URL? = nil
    @State private var destinationDirectory: URL? = nil
    
    // Ici, silenceThresholddB représente le seuil en dB en dessous duquel une fenêtre est considérée comme silencieuse.
    // On le met par défaut à -50 dB, et le slider permet de régler entre -90 dB (silence très parfait)
    // et -20 dB (seuil très haut).
    @State private var silenceThresholddB: Float = -50.0
    @State private var minSilenceDuration: Double = 0.5
    
    @State private var processing: Bool = false
    @State private var log: String = ""
    @State private var progressStatus: String = ""
    
    @State private var precomputedMaxRMSLinear: Float?
    @State private var precomputedMaxdB: Float?
    @State private var maxRMSProgress: String = ""
    
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
            
            // Contrôle du seuil de détection du silence
            HStack {
                Text("Seuil silence (dB) : \(String(format: "%.1f", silenceThresholddB))")
                // Nouvelle plage du slider : de -90 dB à -20 dB
                Slider(value: $silenceThresholddB, in: -90 ... -20, step: 1)
            }
            .padding(.bottom)
            
            // Contrôle de la durée minimale de silence à retirer
            HStack {
                Text("Silence à retirer (s) : \(String(format: "%.2f", minSilenceDuration))")
                Slider(value: $minSilenceDuration, in: 0.1...2.0, step: 0.1)
            }
            .padding(.bottom)
            
            if let maxdB = precomputedMaxdB {
                Text("Max dB: \(String(format: "%.4f", maxdB))")
                    .foregroundColor(.blue)
            }
            Text(maxRMSProgress)
                .foregroundColor(.blue)
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
                        DispatchQueue.main.async { progressStatus = update }
                    }) {
                        DispatchQueue.main.async {
                            self.audioSamples = normalizeSamples(result.samples)
                            self.sampleRate = result.sampleRate
                            self.audioTimeScale = result.timeScale
                            log += "Audio chargé en RAM (\(self.audioSamples.count) échantillons, rate=\(self.sampleRate), channels=\(result.channels)).\n"
                        }
                        computeMaxRMSWithProgress(
                            samples: self.audioSamples,
                            sampleRate: result.sampleRate,
                            channels: result.channels,
                            progressUpdate: { progress in
                                DispatchQueue.main.async {
                                    self.maxRMSProgress = progress
                                }
                            },
                            completion: { rawMaxRMS in
                                DispatchQueue.main.async {
                                    self.precomputedMaxRMSLinear = rawMaxRMS
                                    let dBValue = 20 * log10(Double(rawMaxRMS) + 1e-9)
                                    self.precomputedMaxdB = Float(dBValue)
                                    self.maxRMSProgress = "Détection max dB terminée."
                                }
                            }
                        )
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
                                    DispatchQueue.main.async { progressStatus = update }
                                }) {
                                    DispatchQueue.main.async {
                                        self.audioSamples = normalizeSamples(result.samples)
                                        self.sampleRate = result.sampleRate
                                        self.audioTimeScale = result.timeScale
                                        log += "Audio chargé en RAM (\(self.audioSamples.count) échantillons, rate=\(self.sampleRate), channels=\(result.channels)).\n"
                                    }
                                    computeMaxRMSWithProgress(
                                        samples: self.audioSamples,
                                        sampleRate: result.sampleRate,
                                        channels: result.channels,
                                        progressUpdate: { progress in
                                            DispatchQueue.main.async {
                                                self.maxRMSProgress = progress
                                            }
                                        },
                                        completion: { rawMaxRMS in
                                            DispatchQueue.main.async {
                                                self.precomputedMaxRMSLinear = rawMaxRMS
                                                let dBValue = 20 * log10(Double(rawMaxRMS) + 1e-9)
                                                self.precomputedMaxdB = Float(dBValue)
                                                self.maxRMSProgress = "Détection max dB terminée."
                                            }
                                        }
                                    )
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
        _ = precomputedMaxRMSLinear ?? computeMaxRMS(samples: audioSamples, sampleRate: sampleRate, channels: 2)
        
        processing = true
        log = "Début du traitement...\n"
        progressStatus = "Début du traitement vidéo..."
        
        let asset = AVAsset(url: videoURL)
        DispatchQueue.global(qos: .userInitiated).async {
            let segments = detectNonSilentSegmentsByRemovingSilence(
                samples: self.audioSamples,
                sampleRate: self.sampleRate,
                channels: 2,
                silenceThresholddB: self.silenceThresholddB,
                minSilenceDuration: self.minSilenceDuration,
                progressUpdate: { update in
                    DispatchQueue.main.async {
                        self.progressStatus = update
                    }
                }
            )
            DispatchQueue.main.async {
                self.log += "Segments non silencieux détectés : \(segments.count).\n"
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
                                                                   preferredTrackID: kCMPersistentTrackID_Invalid) else {
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
                let commonEnd = min(videoTrack.timeRange.start + videoTrack.timeRange.duration,
                                    audioTrack.timeRange.start + audioTrack.timeRange.duration)
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
                    self.progressStatus = String(format: "Traitement vidéo : %.1f%%, temps restant ≈ %.1f s",
                                                 progressPct, remainingTime)
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
