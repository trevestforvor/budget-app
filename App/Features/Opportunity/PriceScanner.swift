import AVFoundation
import BudgetKit
import SwiftUI
import Vision
import VisionKit

/// The live camera, highlighting only prices (VisionKit's currency mode); tapping one picks it. Everything is read on
/// the phone.
struct PriceScanner: UIViewControllerRepresentable {
    var isScanning: Bool
    let onPick: (Decimal) -> Void

    /// Whether this phone can scan at all, camera permission aside (the simulator can't).
    static var isSupported: Bool { DataScannerViewController.isSupported }

    /// Asks for the camera the first time, then says whether scanning can start.
    static func requestAccess() async -> Access {
        guard isSupported else { return .unsupported }
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .notDetermined:
            return await AVCaptureDevice.requestAccess(for: .video) ? (DataScannerViewController.isAvailable ? .ready : .denied) : .denied
        case .authorized:
            return DataScannerViewController.isAvailable ? .ready : .denied
        default:
            return .denied
        }
    }

    enum Access { case unknown, ready, denied, unsupported }

    func makeUIViewController(context: Context) -> DataScannerViewController {
        let scanner = DataScannerViewController(recognizedDataTypes: [.text(textContentType: .currency)], qualityLevel: .balanced,
                                                recognizesMultipleItems: true, isHighFrameRateTrackingEnabled: false,
                                                isPinchToZoomEnabled: true, isGuidanceEnabled: false, isHighlightingEnabled: true)
        scanner.delegate = context.coordinator
        return scanner
    }

    func updateUIViewController(_ scanner: DataScannerViewController, context: Context) {
        context.coordinator.onPick = onPick
        if isScanning, !scanner.isScanning {
            try? scanner.startScanning()
        } else if !isScanning, scanner.isScanning {
            scanner.stopScanning()
        }
    }

    static func dismantleUIViewController(_ scanner: DataScannerViewController, coordinator: Coordinator) {
        scanner.stopScanning()
    }

    func makeCoordinator() -> Coordinator { Coordinator(onPick: onPick) }

    @MainActor
    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        var onPick: (Decimal) -> Void

        init(onPick: @escaping (Decimal) -> Void) { self.onPick = onPick }

        func dataScanner(_ dataScanner: DataScannerViewController, didTapOn item: RecognizedItem) {
            guard case let .text(text) = item, let amount = PriceText.amounts(in: text.transcript).first else { return }
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            onPick(amount)
        }
    }
}

/// Prices in a still image — a screenshot of a store page or a photo of a tag — most likely first (see
/// `PriceText.ranked`). Read on the phone with Vision.
enum PhotoPrices {
    static func read(_ image: Data) async throws -> [Decimal] {
        var request = RecognizeTextRequest()
        request.recognitionLevel = .accurate
        // Correction "fixes" digits into words; prices read better without it.
        request.usesLanguageCorrection = false
        let observations = try await request.perform(on: image)
        let lines = observations.compactMap { observation -> (text: String, height: Double)? in
            guard let text = observation.topCandidates(1).first?.string else { return nil }
            return (text, Double(observation.boundingBox.height))
        }
        return PriceText.ranked(lines)
    }
}
