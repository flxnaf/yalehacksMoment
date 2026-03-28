import CoreMotion
import Foundation

@MainActor
protocol FallDetectorDelegate: AnyObject {
    func fallDetected(confidence: Float, timestamp: Date)
}

/// iPhone accelerometer fall detection: freefall then impact, with stationary rejection and cooldown.
final class FallDetector {
    weak var delegate: FallDetectorDelegate?

    private let motion = CMMotionManager()
    private let queue: OperationQueue = {
        let q = OperationQueue()
        q.name = "com.sightassist.fall"
        q.maxConcurrentOperationCount = 1
        q.qualityOfService = .userInitiated
        return q
    }()

    private enum Phase {
        case idle
        case freefall(startTime: CFTimeInterval)
        case postFreefall(endTime: CFTimeInterval)
    }

    private var phase: Phase = .idle
    private var freefallDurationAtEnd: TimeInterval = 0
    /// Sensor-time deadline after which new falls may be reported (`CMAccelerometerData.timestamp`).
    private var cooldownUntilSensorTime: TimeInterval = 0

    private var magBuffer: [Double] = []
    private let bufferCapacity = 25

    /// Below ~1g at rest; tumbling drops rarely stay under 0.4g for long — slightly relaxed for real device tests.
    private let freefallG: Double = 0.55
    private let freefallMinDuration: TimeInterval = 0.28
    private let impactG: Double = 2.2
    /// Impact can follow a brief re-orientation after release; window widened vs lab spec.
    private let impactWindow: TimeInterval = 0.85
    private let varianceThreshold: Double = 0.01
    private let cooldown: TimeInterval = 5

    func startMonitoring() {
        guard motion.isAccelerometerAvailable else { return }
        motion.accelerometerUpdateInterval = 0.02
        motion.startAccelerometerUpdates(to: queue) { [weak self] data, _ in
            self?.handleAccel(data)
        }
    }

    func stopMonitoring() {
        motion.stopAccelerometerUpdates()
        phase = .idle
        magBuffer.removeAll(keepingCapacity: true)
    }

    private func handleAccel(_ data: CMAccelerometerData?) {
        guard let sample = data else { return }
        let a = sample.acceleration
        let now = sample.timestamp
        let gMag = sqrt(a.x * a.x + a.y * a.y + a.z * a.z)

        magBuffer.append(gMag)
        if magBuffer.count > bufferCapacity {
            magBuffer.removeFirst(magBuffer.count - bufferCapacity)
        }

        switch phase {
        case .idle:
            if gMag < freefallG {
                phase = .freefall(startTime: now)
            }

        case .freefall(let start):
            if gMag < freefallG {
                break
            }
            let duration = now - start
            if duration >= freefallMinDuration {
                freefallDurationAtEnd = duration
                phase = .postFreefall(endTime: now)
            } else {
                phase = .idle
                freefallDurationAtEnd = 0
            }

        case .postFreefall(let endTime):
            if now - endTime > impactWindow {
                phase = .idle
                freefallDurationAtEnd = 0
                return
            }
            guard gMag > impactG else { return }

            if magBuffer.count == bufferCapacity {
                let variance = Self.variance(of: magBuffer)
                if variance < varianceThreshold {
                    #if DEBUG
                    print("[FallDetector] rejected: stationary variance=\(variance)")
                    #endif
                    phase = .idle
                    freefallDurationAtEnd = 0
                    return
                }
            }

            if now < cooldownUntilSensorTime {
                phase = .idle
                freefallDurationAtEnd = 0
                return
            }

            let confidence = Self.computeConfidence(impactG: gMag, freefallDuration: freefallDurationAtEnd)
            #if DEBUG
            print("[FallDetector] fall candidate: impactG=\(String(format: "%.2f", gMag)) ffDur=\(String(format: "%.2f", freefallDurationAtEnd))s confidence=\(confidence)")
            #endif
            cooldownUntilSensorTime = now + cooldown
            phase = .idle
            freefallDurationAtEnd = 0

            Task { @MainActor [weak self] in
                guard let self else { return }
                self.delegate?.fallDetected(confidence: confidence, timestamp: Date())
            }
        }
    }

    private static func variance(of values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        let mean = values.reduce(0, +) / Double(values.count)
        let sq = values.map { ($0 - mean) * ($0 - mean) }.reduce(0, +)
        return sq / Double(values.count)
    }

    private static func computeConfidence(impactG: Double, freefallDuration: TimeInterval) -> Float {
        // Spec uses 2.5g as baseline; keep formula shape but use same threshold as impactG constant family.
        let impactBaseline = 2.2
        let impactScore = min(max((impactG - impactBaseline) / 3.0, 0), 1) * 0.6
        let ffScore = min(max(freefallDuration / 0.6, 0), 1) * 0.4
        return Float(min(impactScore + ffScore, 1))
    }
}
