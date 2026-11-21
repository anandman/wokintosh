import SwiftUI
@preconcurrency import AVFoundation

struct PhoneScannerView:UIViewControllerRepresentable {
    let onCode:(String)->Void
    func makeUIViewController(context:Context)->PhoneScannerController {PhoneScannerController(onCode:onCode)}
    func updateUIViewController(_ controller:PhoneScannerController,context:Context) {}
}

final class PhoneScannerController:UIViewController,AVCaptureMetadataOutputObjectsDelegate {
    private let onCode:(String)->Void
    private let capture=AVCaptureSession()
    private let queue=DispatchQueue(label:"dev.wokintosh.phone-camera")
    private var preview:AVCaptureVideoPreviewLayer?
    private var configured=false
    private var scanned=false
    private var visible=false
    private let status=UILabel()
    init(onCode:@escaping(String)->Void) {self.onCode=onCode;super.init(nibName:nil,bundle:nil)}
    required init?(coder:NSCoder) {fatalError("init(coder:) is unavailable")}
    override func viewDidLoad() {
        super.viewDidLoad();view.backgroundColor = .black
        status.text="Scan the private pairing code on your Mac";status.textColor = .white;status.textAlignment = .center;status.numberOfLines=0
        status.translatesAutoresizingMaskIntoConstraints=false;view.addSubview(status)
        NSLayoutConstraint.activate([status.leadingAnchor.constraint(equalTo:view.leadingAnchor,constant:24),status.trailingAnchor.constraint(equalTo:view.trailingAnchor,constant:-24),status.bottomAnchor.constraint(equalTo:view.safeAreaLayoutGuide.bottomAnchor,constant:-28)])
    }
    override func viewDidAppear(_ animated:Bool) {
        super.viewDidAppear(animated);visible=true
        switch AVCaptureDevice.authorizationStatus(for:.video) {
        case .authorized:configure()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for:.video) { [weak self] allowed in Task { @MainActor in
                if allowed {self?.configure()} else {self?.status.text="Allow camera access in Settings, or use Paste pairing code."}
            }}
        default:status.text="Allow camera access in Settings, or use Paste pairing code."
        }
    }
    override func viewWillDisappear(_ animated:Bool) {
        super.viewWillDisappear(animated);visible=false
        let capture=capture;queue.async {capture.stopRunning()}
    }
    override func viewDidLayoutSubviews() {super.viewDidLayoutSubviews();preview?.frame=view.bounds}
    private func configure() {
        guard visible else {return}
        if !configured {
            guard let camera=AVCaptureDevice.default(for:.video),let input=try? AVCaptureDeviceInput(device:camera),capture.canAddInput(input) else {status.text="Camera unavailable. Use Paste pairing code instead.";return}
            capture.addInput(input)
            let output=AVCaptureMetadataOutput()
            guard capture.canAddOutput(output) else {status.text="Camera unavailable.";return}
            capture.addOutput(output);output.setMetadataObjectsDelegate(self,queue:.main);output.metadataObjectTypes=[.qr]
            let preview=AVCaptureVideoPreviewLayer(session:capture);preview.videoGravity = .resizeAspectFill
            view.layer.insertSublayer(preview,at:0);self.preview=preview;preview.frame=view.bounds;configured=true
        }
        let capture=capture;queue.async {capture.startRunning()}
    }
    func metadataOutput(_ output:AVCaptureMetadataOutput,didOutput metadataObjects:[AVMetadataObject],from connection:AVCaptureConnection) {
        guard !scanned,let code=metadataObjects.compactMap({($0 as? AVMetadataMachineReadableCodeObject)?.stringValue}).first,code.utf8.count<=4096 else {return}
        scanned=true;onCode(code)
    }
}
