import SwiftUI

struct DepthBenchmarkView: View {
    @StateObject private var vm = DepthBenchmarkViewModel()
    @EnvironmentObject private var appVM: AppViewModel

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if let frame = vm.currentFrame {
                Image(uiImage: frame)
                    .resizable()
                    .scaledToFit()
                    .ignoresSafeArea()
            } else {
                VStack(spacing: 16) {
                    ProgressView().scaleEffect(1.5).tint(.white)
                    Text(statusLabel)
                        .foregroundColor(.white)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)
                }
            }

            if vm.showDepthOverlay, let depth = vm.depthFrame {
                Image(uiImage: depth)
                    .resizable()
                    .scaledToFit()
                    .ignoresSafeArea()
                    .opacity(vm.overlayOpacity)
                    .allowsHitTesting(false)
            }

            GeometryReader { geo in
                VisionOverlay(
                    persons: vm.audioEngine.detectedPersons,
                    sceneLabel: vm.audioEngine.detectedSceneLabel,
                    frameSize: geo.size
                )
            }
            .allowsHitTesting(false)
            .ignoresSafeArea()

            VStack {
                topBar
                Spacer()
                clearPathPanel
                sourcePicker
                if !vm.modelLoaded { modelBar }
                bottomControls
            }
        }
        .onAppear {
            vm.phoneCam.start()
            vm.startModelLoad()
        }
        .onChange(of: appVM.registrationState) { oldState, newState in
            guard vm.activeSource == .glasses, newState == .registered else { return }
            // `configureIfNeeded()` can jump `.unavailable → .registered` in the same turn as Ray-Ban
            // select; `beginGlassesStreaming` already starts the session. A second `startStreaming()`
            // begins with `session.stop()` and kills the feed immediately.
            guard oldState == .registering || oldState == .available else { return }
            vm.onGlassesRegistrationReady()
        }
        .alert("Error", isPresented: $appVM.showError) {
            Button("OK") { appVM.dismissError() }
        } message: {
            Text(appVM.errorMessage)
        }
    }

    private var statusLabel: String {
        switch vm.activeSource {
        case .phone: return vm.phoneCam.statusMessage
        case .glasses:
            if vm.currentFrame == nil, vm.glassesStatus == "Streaming" {
                return "Streaming — building preview…"
            }
            return vm.glassesStatus
        }
    }

    // MARK: - Source picker

    private var sourcePicker: some View {
        HStack(spacing: 0) {
            ForEach(CameraSource.allCases, id: \.self) { source in
                Button {
                    if source != vm.activeSource {
                        if source == .glasses { vm.phoneCam.stop() }
                        if source == .phone   { vm.phoneCam.start() }
                        vm.selectSource(source, appVM: appVM)
                    }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: source == .phone ? "iphone" : "eyeglasses")
                        Text(source.rawValue)
                    }
                    .font(.subheadline.weight(vm.activeSource == source ? .bold : .regular))
                    .foregroundColor(vm.activeSource == source ? .black : .white)
                    .padding(.vertical, 8).padding(.horizontal, 18)
                    .background(vm.activeSource == source ? Color.white : Color.clear)
                    .clipShape(Capsule())
                }
            }
        }
        .padding(4)
        .background(.ultraThinMaterial)
        .clipShape(Capsule())
        .padding(.bottom, 8)
    }

    // MARK: - Top bar

    private var topBar: some View {
        HStack(alignment: .top) {
            statsCard
            Spacer()
            VStack(spacing: 8) {
                Button {
                    withAnimation { vm.showDepthOverlay.toggle() }
                } label: {
                    VStack(spacing: 3) {
                        Image(systemName: vm.showDepthOverlay ? "eye" : "eye.slash")
                            .font(.system(size: 18))
                        Text("Depth").font(.system(size: 9, weight: .medium))
                    }
                    .foregroundColor(.white)
                    .padding(.horizontal, 10).padding(.vertical, 8)
                    .background(.ultraThinMaterial)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                }

                Button {
                    vm.audioEngine.isEnabled.toggle()
                } label: {
                    VStack(spacing: 3) {
                        Image(systemName: vm.audioEngine.isEnabled
                              ? "waveform.circle.fill"
                              : "waveform.circle")
                            .font(.system(size: 18))
                            .foregroundColor(vm.audioEngine.isEnabled ? .green : .white)
                        Text("Audio").font(.system(size: 9, weight: .medium))
                            .foregroundColor(.white)
                    }
                    .padding(.horizontal, 10).padding(.vertical, 8)
                    .background(.ultraThinMaterial)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                }

                Button {
                    vm.audioEngine.hapticsEnabled.toggle()
                } label: {
                    VStack(spacing: 3) {
                        Image(systemName: vm.audioEngine.hapticsEnabled
                              ? "iphone.radiowaves.left.and.right.circle.fill"
                              : "iphone.radiowaves.left.and.right.circle")
                            .font(.system(size: 18))
                            .foregroundColor(vm.audioEngine.hapticsEnabled ? .cyan : .white)
                        Text("Haptics").font(.system(size: 9, weight: .medium))
                            .foregroundColor(.white)
                    }
                    .padding(.horizontal, 10).padding(.vertical, 8)
                    .background(.ultraThinMaterial)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                }
            }
        }
        .padding(.horizontal, 16).padding(.top, 8)
    }

    private var statsCard: some View {
        VStack(alignment: .leading, spacing: 4) {
            if vm.totalFrames == 0 {
                HStack(spacing: 6) {
                    if !vm.modelLoaded { ProgressView().scaleEffect(0.7).tint(.white) }
                    Text(vm.modelLoaded ? "Waiting for frames…" : "Loading model…")
                        .foregroundColor(.white.opacity(0.7))
                }
                .font(.caption)
            } else {
                statRow("Now", vm.latestMs)
                statRow("Avg", vm.avgMs)
                statRow("Min", vm.minMs)
                statRow("Max", vm.maxMs)
                Text("Frames: \(vm.totalFrames)")
                    .foregroundColor(.white.opacity(0.6)).font(.caption2)

                // Compute backend badge
                if !vm.computeLabel.isEmpty {
                    HStack(spacing: 4) {
                        if vm.isUpgradingToANE {
                            ProgressView().scaleEffect(0.55).tint(.yellow)
                            Text("Depth: GPU → ANE…").foregroundColor(.yellow)
                        } else {
                            Image(systemName: vm.computeLabel.contains("ANE") ? "bolt.fill" : "cpu")
                                .foregroundColor(vm.computeLabel.contains("ANE") ? .green : .orange)
                            Text("Depth: \(vm.computeLabel)")
                                .foregroundColor(vm.computeLabel.contains("ANE") ? .green : .orange)
                        }
                    }
                    .font(.system(size: 9, weight: .semibold, design: .monospaced))
                }
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private func statRow(_ label: String, _ value: Double) -> some View {
        HStack(spacing: 4) {
            Text(label).foregroundColor(.white.opacity(0.6)).frame(width: 28, alignment: .leading)
            Text(String(format: "%.1f ms", value))
                .foregroundColor(value < 40 ? .green : value < 80 ? .yellow : .red)
                .fontWeight(.semibold)
        }
        .font(.system(.caption, design: .monospaced))
    }

    // MARK: - Model progress bar

    private var modelBar: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(vm.modelError == nil ? "Compiling depth model…" : "Model error")
                    .font(.caption.bold()).foregroundColor(.white)
                Spacer()
                if vm.modelError == nil {
                    Text("~60 s first launch only").font(.caption2).foregroundColor(.white.opacity(0.5))
                }
            }
            if let err = vm.modelError {
                Text(err).font(.caption2).foregroundColor(.red)
            } else {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 4).fill(Color.white.opacity(0.15)).frame(height: 6)
                        RoundedRectangle(cornerRadius: 4).fill(Color.blue)
                            .frame(width: geo.size.width * vm.modelLoadProgress, height: 6)
                            .animation(.easeInOut(duration: 0.3), value: vm.modelLoadProgress)
                    }
                }.frame(height: 6)
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .padding(.horizontal, 16).padding(.bottom, 8)
    }

    // MARK: - Clear path debug panel

    private var clearPathPanel: some View {
        let active    = vm.audioEngine.activePath
        let raw       = vm.audioEngine.rawPaths
        let progress  = vm.audioEngine.beaconSustainProgress
        let sustained = progress >= 1.0

        return VStack(spacing: 5) {

            // Status label
            HStack(spacing: 6) {
                if let p = active {
                    Image(systemName: sustained ? "arrow.forward.circle.fill" : "circle.dotted")
                        .foregroundColor(sustained ? .green : .yellow)
                    Text(sustained ? "CLEAR PATH" : "DETECTING…")
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .foregroundColor(sustained ? .green : .yellow)
                    Text(directionLabel(p.azimuthFraction))
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .foregroundColor(.white.opacity(0.8))
                    Text(String(format: "conf %.0f%%", p.confidence * 100))
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundColor(.white.opacity(0.5))
                } else if !raw.isEmpty {
                    Image(systemName: "clock.arrow.circlepath")
                        .foregroundColor(.yellow)
                    Text("BUILDING…")
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .foregroundColor(.yellow)
                } else {
                    Image(systemName: "xmark.circle")
                        .foregroundColor(.red.opacity(0.7))
                    Text("NO CLEAR PATH")
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .foregroundColor(.red.opacity(0.7))
                }
                Spacer()
                // Sustain progress dots
                HStack(spacing: 3) {
                    ForEach(0..<5, id: \.self) { i in
                        Circle()
                            .fill(Float(i) / 5.0 < progress ? Color.green : Color.white.opacity(0.2))
                            .frame(width: 5, height: 5)
                    }
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 6)
            .background(.ultraThinMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 8))

            // Azimuth bar — depth-profile heat map
            azimuthBar(active: active, sustained: sustained, geo: nil)
                .frame(height: 26)

            // Zone labels
            HStack {
                Text("LEFT").font(.system(size: 7, design: .monospaced)).foregroundColor(.white.opacity(0.35))
                Spacer()
                Text("CENTER").font(.system(size: 7, design: .monospaced)).foregroundColor(.white.opacity(0.35))
                Spacer()
                Text("RIGHT").font(.system(size: 7, design: .monospaced)).foregroundColor(.white.opacity(0.35))
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 6)
    }

    // MARK: - Azimuth bar (depth-profile heat map)

    private func azimuthBar(active: ClearPath?, sustained: Bool, geo _: GeometryProxy?) -> some View {
        let profile = vm.audioEngine.depthProfile
        let colCount = max(profile.count, 1)

        return GeometryReader { geo in
            let barH: CGFloat = 26
            let colW = geo.size.width / CGFloat(colCount)

            ZStack(alignment: .leading) {
                // Background track
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color.black.opacity(0.55))
                    .frame(height: barH)

                // Profile columns
                if !profile.isEmpty {
                    HStack(spacing: 0) {
                        ForEach(0..<colCount, id: \.self) { i in
                            profileColor(depth: profile[i])
                                .frame(width: colW, height: barH - 4)
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 3))
                    .padding(.horizontal, 1)
                }

                // Active sustained path overlay
                if let p = active {
                    let x = CGFloat(p.azimuthFraction) * geo.size.width
                    let w = max(colW, CGFloat(p.width) * geo.size.width)
                    RoundedRectangle(cornerRadius: 3)
                        .fill((sustained ? Color.green : Color.yellow).opacity(0.45))
                        .frame(width: w, height: barH - 4)
                        .position(x: x, y: barH / 2)
                    Rectangle()
                        .fill(Color.white)
                        .frame(width: 2, height: barH)
                        .position(x: x, y: barH / 2)
                }

                // Zone dividers (⅓, ⅔)
                ForEach([CGFloat(1) / 3, CGFloat(2) / 3], id: \.self) { f in
                    Rectangle()
                        .fill(Color.white.opacity(0.18))
                        .frame(width: 1, height: barH)
                        .position(x: f * geo.size.width, y: barH / 2)
                }
            }
        }
    }

    private func profileColor(depth: Float) -> Color {
        switch depth {
        case ..<PathFinder.clearThreshold:
            return .green.opacity(0.6)
        case ..<0.60:
            let t = Double((depth - PathFinder.clearThreshold) / (0.60 - PathFinder.clearThreshold))
            return Color(red: 0.9, green: 0.75 - 0.35 * t, blue: 0.1)
        default:
            let t = Double(min((depth - 0.60) / 0.30, 1.0))
            return Color(red: 0.85 + 0.15 * t, green: 0.3 - 0.25 * t, blue: 0.05)
        }
    }

    private func directionLabel(_ azimuth: Float) -> String {
        switch azimuth {
        case ..<0.33: return "← LEFT"
        case 0.67...: return "RIGHT →"
        default:      return "↑ CENTER"
        }
    }

    // MARK: - Bottom controls

    private var bottomControls: some View {
        HStack(spacing: 12) {
            Toggle(isOn: $vm.inferenceEnabled) {
                Label("Depth", systemImage: "cpu").foregroundColor(.white).font(.caption)
            }
            .toggleStyle(.button).tint(.blue)
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(.ultraThinMaterial).clipShape(RoundedRectangle(cornerRadius: 10))

            HStack(spacing: 6) {
                Image(systemName: "plusminus.circle").foregroundColor(.white.opacity(0.6)).font(.caption)
                Text("Opacity").font(.caption2).foregroundColor(.white.opacity(0.6))
                Slider(value: $vm.overlayOpacity, in: 0...1).tint(.white).frame(width: 70)
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(.ultraThinMaterial).clipShape(RoundedRectangle(cornerRadius: 10))

            Spacer()
            Button { vm.resetStats() } label: {
                Image(systemName: "arrow.counterclockwise").foregroundColor(.white)
                    .padding(10).background(.ultraThinMaterial).clipShape(Circle())
            }
        }
        .padding(.horizontal, 16).padding(.bottom, 40)
    }
}
