import AVFoundation
import SwiftUI
import UIKit
import Vision

struct CameraScannerView: UIViewControllerRepresentable {
    @Binding var isTorchOn: Bool
    @Binding var isScanningEnabled: Bool
    var onCodeScanned: (String, String) -> Void

    func makeUIViewController(context: Context) -> ScannerViewController {
        let vc = ScannerViewController()
        vc.onCodeScanned = onCodeScanned
        return vc
    }

    func updateUIViewController(_ uiViewController: ScannerViewController, context: Context) {
        uiViewController.onCodeScanned = onCodeScanned
        uiViewController.setScanningEnabled(isScanningEnabled)
        uiViewController.setTorch(on: isTorchOn)
    }
}

final class ScannerViewController: UIViewController, AVCaptureMetadataOutputObjectsDelegate {
    var onCodeScanned: ((String, String) -> Void)?

    private let session = AVCaptureSession()
    private let sessionQueue = DispatchQueue(label: "com.xinyunhang.glassscan.camera")
    private var previewLayer: AVCaptureVideoPreviewLayer?
    private var videoDevice: AVCaptureDevice?
    private var isConfigured = false
    private var isScanningEnabled = true
    private var lastDetectedValue: String?
    private var lastDetectedDate: Date = .distantPast
    private var baseZoomFactor: CGFloat = 1.0

    private let statusLabel: UILabel = {
        let label = UILabel()
        label.textColor = .secondaryLabel
        label.font = .preferredFont(forTextStyle: .callout)
        label.textAlignment = .center
        label.numberOfLines = 0
        label.translatesAutoresizingMaskIntoConstraints = false
        label.isHidden = true
        return label
    }()

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black

        view.addSubview(statusLabel)
        NSLayoutConstraint.activate([
            statusLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            statusLabel.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            statusLabel.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 32),
            statusLabel.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -32)
        ])

        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTapToFocus(_:)))
        view.addGestureRecognizer(tap)

        let pinch = UIPinchGestureRecognizer(target: self, action: #selector(handlePinchToZoom(_:)))
        view.addGestureRecognizer(pinch)

        checkPermissionAndConfigure()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        previewLayer?.frame = view.bounds
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        sessionQueue.async { [weak self] in
            guard let self, self.isConfigured, !self.session.isRunning else { return }
            self.session.startRunning()
        }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        setTorch(on: false)
        sessionQueue.async { [weak self] in
            guard let self, self.session.isRunning else { return }
            self.session.stopRunning()
        }
    }

    func setScanningEnabled(_ enabled: Bool) {
        isScanningEnabled = enabled
        if enabled {
            lastDetectedDate = .distantPast
        }
    }

    func setTorch(on: Bool) {
        sessionQueue.async { [weak self] in
            guard let device = self?.videoDevice, device.hasTorch else { return }
            do {
                try device.lockForConfiguration()
                device.torchMode = on ? .on : .off
                device.unlockForConfiguration()
            } catch {
                // Ignore torch errors on unsupported hardware
            }
        }
    }

    private func checkPermissionAndConfigure() {
        #if targetEnvironment(simulator)
        showFallbackMessage("模拟器无物理摄像头\n可使用下方「相册识码」或「粘贴探测」")
        return
        #else
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            configureSession()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                DispatchQueue.main.async {
                    if granted {
                        self?.configureSession()
                    } else {
                        self?.showFallbackMessage("未授予相机权限\n请前往「设置 → 隐私 → 相机」开启，或使用相册识码")
                    }
                }
            }
        default:
            showFallbackMessage("未授予相机权限\n请前往「设置 → 隐私 → 相机」开启，或使用相册识码")
        }
        #endif
    }

    private func showFallbackMessage(_ text: String) {
        DispatchQueue.main.async {
            self.statusLabel.text = text
            self.statusLabel.isHidden = false
        }
    }

    private func configureSession() {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            self.session.beginConfiguration()
            self.session.sessionPreset = .high

            guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
                  let input = try? AVCaptureDeviceInput(device: device),
                  self.session.canAddInput(input) else {
                self.session.commitConfiguration()
                self.showFallbackMessage("无法初始化后置摄像头")
                return
            }

            self.videoDevice = device
            self.session.addInput(input)

            // Optimize continuous autofocus for low-light bathroom stickers
            if device.isFocusModeSupported(.continuousAutoFocus) {
                try? device.lockForConfiguration()
                device.focusMode = .continuousAutoFocus
                if device.isAutoFocusRangeRestrictionSupported {
                    device.autoFocusRangeRestriction = .near
                }
                device.unlockForConfiguration()
            }

            let output = AVCaptureMetadataOutput()
            if self.session.canAddOutput(output) {
                self.session.addOutput(output)
                output.setMetadataObjectsDelegate(self, queue: DispatchQueue.main)
                let desiredTypes: [AVMetadataObject.ObjectType] = [
                    .qr, .ean13, .ean8, .code128, .aztec, .dataMatrix, .pdf417
                ]
                output.metadataObjectTypes = desiredTypes.filter { output.availableMetadataObjectTypes.contains($0) }
            }

            self.session.commitConfiguration()
            self.isConfigured = true

            DispatchQueue.main.async {
                let layer = AVCaptureVideoPreviewLayer(session: self.session)
                layer.videoGravity = .resizeAspectFill
                layer.frame = self.view.bounds
                self.view.layer.insertSublayer(layer, at: 0)
                self.previewLayer = layer
                self.statusLabel.isHidden = true
            }

            self.session.startRunning()
        }
    }

    @objc private func handleTapToFocus(_ gesture: UITapGestureRecognizer) {
        guard let previewLayer, let device = videoDevice else { return }
        let point = previewLayer.captureDevicePointConverted(fromLayerPoint: gesture.location(in: view))
        sessionQueue.async {
            do {
                try device.lockForConfiguration()
                if device.isFocusPointOfInterestSupported {
                    device.focusPointOfInterest = point
                    device.focusMode = .autoFocus
                }
                if device.isExposurePointOfInterestSupported {
                    device.exposurePointOfInterest = point
                    device.exposureMode = .autoExpose
                }
                device.unlockForConfiguration()
            } catch {}
        }
    }

    @objc private func handlePinchToZoom(_ gesture: UIPinchGestureRecognizer) {
        guard let device = videoDevice else { return }
        if gesture.state == .began {
            baseZoomFactor = device.videoZoomFactor
        }
        let target = min(max(baseZoomFactor * gesture.scale, 1.0), min(device.activeFormat.videoMaxZoomFactor, 6.0))
        sessionQueue.async {
            do {
                try device.lockForConfiguration()
                device.videoZoomFactor = target
                device.unlockForConfiguration()
            } catch {}
        }
    }

    func metadataOutput(
        _ output: AVCaptureMetadataOutput,
        didOutput metadataObjects: [AVMetadataObject],
        from connection: AVCaptureConnection
    ) {
        guard isScanningEnabled,
              let readable = metadataObjects.first as? AVMetadataMachineReadableCodeObject,
              let value = readable.stringValue,
              !value.isEmpty else {
            return
        }

        let now = Date()
        if value == lastDetectedValue, now.timeIntervalSince(lastDetectedDate) < 3.0 {
            return
        }
        lastDetectedValue = value
        lastDetectedDate = now

        let symbology = readable.type.rawValue.replacingOccurrences(of: "org.iso.", with: "")
        let generator = UINotificationFeedbackGenerator()
        generator.notificationOccurred(.success)
        onCodeScanned?(value, symbology)
    }
}

enum PhotoQRDecoder {
    static func decode(from imageData: Data) async -> (String, String)? {
        guard let uiImage = UIImage(data: imageData),
              let cgImage = uiImage.cgImage else {
            return nil
        }
        return await withCheckedContinuation { continuation in
            let request = VNDetectBarcodesRequest { request, _ in
                let observations = request.results as? [VNBarcodeObservation] ?? []
                if let first = observations.first, let payload = first.payloadStringValue, !payload.isEmpty {
                    continuation.resume(returning: (payload, first.symbology.rawValue))
                } else {
                    continuation.resume(returning: nil)
                }
            }
            let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
            do {
                try handler.perform([request])
            } catch {
                continuation.resume(returning: nil)
            }
        }
    }
}
