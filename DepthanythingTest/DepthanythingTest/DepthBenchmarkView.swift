import SwiftUI

struct DepthBenchmarkView: View {
    @StateObject private var vm    = DepthBenchmarkViewModel()
    @StateObject private var cam   = PhoneCameraManager()
    @EnvironmentObject  private var appVM: AppViewModel

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

            VStack {
                topBar
                Spacer()
                sourcePicker
                if !vm.modelLoaded { modelBar }
                bottomControls
            }
        }
        .onAppear {
            vm.phoneCam.start()
            vm.startModelLoad()
        }
        .alert("Error", isPresented: $appVM.showError) {
            Button("OK") { appVM.dismissError() }
        } message: {
            Text(appVM.errorMessage)
        }
    }

    private var statusLabel: String {
        switch vm.activeSource {
        case .phone:   return vm.phoneCam.statusMessage
        case .glasses: return vm.glassesStatus
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
        }
        .padding(.horizontal, 16).padding(.top, 8)
    }

    private var statsCard: some View {
        VStack(alignment: .leading, spacing: 4) {
            if vm.totalFrames == 0 {
                HStack(spacing: 6) {
                    if !vm.modelLoaded { ProgressView().scaleEffect(0.7).tint(.white) }
                    Text(vm.modelLoaded ? "Waiting for frames…" : "Compiling model…")
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
