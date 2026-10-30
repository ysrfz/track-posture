import AppKit
import AVFoundation
import ServiceManagement
import Vision

// Tolerances are relative to your calibrated baseline; run with --debug to see live values while tuning.
let slouchTolerance = 0.10
let leanInTolerance = 0.15
let maxTiltDegrees = 8.0
let sinkTolerance = 0.05  // fraction of frame height
let recoveryFraction = 0.5  // once flagged, tolerances shrink so borderline frames can't reset the grace timer
let graceSeconds = 10.0
let rampSeconds = 30.0
let minGlow = 0.15
let maxGlow = 0.4
let awaySeconds = 2.0
let debug = CommandLine.arguments.contains("--debug")

struct Posture: Codable {
    var height, width, tilt, shoulderY: Double

    func blended(with p: Posture, _ k: Double = 0.2) -> Posture {
        func mix(_ a: Double, _ b: Double) -> Double { a + (b - a) * k }
        return Posture(height: mix(height, p.height), width: mix(width, p.width), tilt: mix(tilt, p.tilt), shoulderY: mix(shoulderY, p.shoulderY))
    }
}

struct Day: Codable {
    static var today: String { Date().formatted(Date.ISO8601FormatStyle(timeZone: .current).year().month().day()) }
    var date = Day.today
    var tracked = 0.0, upright = 0.0, alerts = 0
    var percent: Int { tracked > 0 ? Int(upright / tracked * 100) : 0 }
}

func restored<T: Decodable>(_ key: String) -> T? {
    UserDefaults.standard.data(forKey: key).flatMap { try? JSONDecoder().decode(T.self, from: $0) }
}

func persist(_ value: some Encodable, _ key: String) {
    UserDefaults.standard.set(try? JSONEncoder().encode(value), forKey: key)
}

final class Camera: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    private let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "camera")
    private let request = VNDetectHumanBodyPoseRequest()
    private let onPosture: @MainActor (Posture?) -> Void
    private var lastFrame = Date.distantPast

    init(onPosture: @escaping @MainActor (Posture?) -> Void) {
        self.onPosture = onPosture
        super.init()
        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .unspecified),
              let input = try? AVCaptureDeviceInput(device: device) else { return }
        let output = AVCaptureVideoDataOutput()
        output.alwaysDiscardsLateVideoFrames = true
        output.setSampleBufferDelegate(self, queue: queue)
        session.sessionPreset = .vga640x480
        session.addInput(input)
        session.addOutput(output)
    }

    func run(_ on: Bool) {
        queue.async { on ? self.session.startRunning() : self.session.stopRunning() }
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput buffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard Date().timeIntervalSince(lastFrame) >= 0.2 else { return }
        lastFrame = Date()
        let posture = detect(buffer)
        Task { @MainActor [onPosture] in onPosture(posture) }
    }

    private func detect(_ buffer: CMSampleBuffer) -> Posture? {
        guard let image = CMSampleBufferGetImageBuffer(buffer) else { return nil }
        try? VNImageRequestHandler(cvPixelBuffer: image).perform([request])
        guard let joints = try? request.results?.first?.recognizedPoints(.all),
              let nose = joints[.nose], let left = joints[.leftShoulder], let right = joints[.rightShoulder],
              [nose, left, right].allSatisfy({ $0.confidence > 0.3 }) else { return nil }
        let (w, h) = (CVPixelBufferGetWidth(image), CVPixelBufferGetHeight(image))
        let n = VNImagePointForNormalizedPoint(nose.location, w, h)
        let l = VNImagePointForNormalizedPoint(left.location, w, h)
        let r = VNImagePointForNormalizedPoint(right.location, w, h)
        let width = hypot(l.x - r.x, l.y - r.y)
        return Posture(height: (n.y - (l.y + r.y) / 2) / width,
                       width: width,
                       tilt: atan2(l.y - r.y, abs(l.x - r.x)) * 180 / .pi,
                       shoulderY: (left.location.y + right.location.y) / 2)
    }
}

final class GlowView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        let gradient = NSGradient(starting: .systemOrange, ending: .systemOrange.withAlphaComponent(0))!
        let (d, w, h) = (160.0, bounds.width, bounds.height)
        gradient.draw(in: NSRect(x: 0, y: 0, width: w, height: d), angle: 90)
        gradient.draw(in: NSRect(x: 0, y: h - d, width: w, height: d), angle: 270)
        gradient.draw(in: NSRect(x: 0, y: 0, width: d, height: h), angle: 0)
        gradient.draw(in: NSRect(x: w - d, y: 0, width: d, height: h), angle: 180)
    }
}

final class App: NSObject, NSApplicationDelegate, NSMenuDelegate {
    var baseline: Posture? = restored("baseline") { didSet { persist(baseline, "baseline") } }
    var day: Day = restored("day") ?? Day() { didSet { persist(day, "day") } }
    var smoothed: Posture?
    var lastSeen = Date.distantPast
    var lastUpdate = Date()
    var badSince: Date?
    var glowLevel = 0.0
    var glows: [NSWindow] = []
    var locked = false
    var resumeTimer: Timer?
    lazy var camera = Camera { [weak self] in self?.update($0) }
    let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    let statsItem = NSMenuItem()
    lazy var pauseItem = menuItem("Pause 1 Hour", #selector(togglePause))

    func applicationDidFinishLaunching(_ notification: Notification) {
        setlinebuf(stdout)
        if SMAppService.mainApp.status == .notRegistered { try? SMAppService.mainApp.register() }
        statusItem.button?.image = NSImage(systemSymbolName: "figure.stand", accessibilityDescription: "TrackPosture")
        let menu = NSMenu()
        menu.delegate = self
        menu.items = [statsItem, .separator(), menuItem("Recalibrate", #selector(calibrate)), pauseItem,
                      NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate), keyEquivalent: "q")]
        statusItem.menu = menu
        makeGlowWindows()
        NotificationCenter.default.addObserver(self, selector: #selector(makeGlowWindows), name: NSApplication.didChangeScreenParametersNotification, object: nil)
        for name in ["com.apple.screenIsLocked", "com.apple.screenIsUnlocked"] {
            DistributedNotificationCenter.default().addObserver(self, selector: #selector(screenLockChanged), name: .init(name), object: nil)
        }
        Task {
            guard await AVCaptureDevice.requestAccess(for: .video) else {
                alert("Camera access needed", "Enable TrackPosture in System Settings → Privacy & Security → Camera.", "OK")
                return
            }
            refreshCamera()
            if baseline == nil { calibrate() }
        }
    }

    func update(_ posture: Posture?) {
        let now = Date(), dt = min(now.timeIntervalSince(lastUpdate), 1)
        lastUpdate = now
        if day.date != Day.today { appendHistory(day); day = Day() }
        if let posture {
            smoothed = smoothed?.blended(with: posture) ?? posture
            lastSeen = now
        } else if now.timeIntervalSince(lastSeen) > awaySeconds {
            smoothed = nil
        }
        guard let s = smoothed, let base = baseline else { badSince = nil; return setGlow(0) }
        let k = badSince == nil ? 1 : recoveryFraction
        let bad = s.height < base.height * (1 - slouchTolerance * k)
            || s.width > base.width * (1 + leanInTolerance * k)
            || abs(s.tilt - base.tilt) > maxTiltDegrees * k
            || s.shoulderY < base.shoulderY - sinkTolerance * k
        day.tracked += dt
        if !bad { day.upright += dt }
        badSince = bad ? (badSince ?? now) : nil
        let over = now.timeIntervalSince(badSince ?? now) - graceSeconds
        let level = over < 0 ? 0 : minGlow + (maxGlow - minGlow) * min(over / rampSeconds, 1)
        if level > 0, glowLevel == 0 { day.alerts += 1 }
        setGlow(level)
        if debug {
            print(String(format: "height %.2f/%.2f  width %.0f/%.0f  tilt %+.1f/%+.1f  shoulderY %.2f/%.2f  %@  glow %.2f",
                         s.height, base.height, s.width, base.width, s.tilt, base.tilt, s.shoulderY, base.shoulderY, bad ? "BAD" : "ok ", level))
        }
    }

    func setGlow(_ level: Double) {
        guard level != glowLevel else { return }
        glowLevel = level
        glows.forEach { $0.animator().alphaValue = level }
    }

    @objc func makeGlowWindows() {
        glows.forEach { $0.close() }
        glows = NSScreen.screens.map { screen in
            let window = NSWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
            window.level = .screenSaver
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
            window.ignoresMouseEvents = true
            window.isOpaque = false
            window.backgroundColor = .clear
            window.hasShadow = false
            window.sharingType = .none
            window.isReleasedWhenClosed = false
            window.contentView = GlowView()
            window.alphaValue = glowLevel
            window.orderFrontRegardless()
            return window
        }
    }

    @objc func calibrate() {
        guard alert("Sit up straight", "Face the screen in your best posture with head and shoulders in view, click Calibrate, then hold still for 3 seconds.", "Calibrate", "Cancel") else { return }
        Task {
            try? await Task.sleep(for: .seconds(3))
            if let smoothed { baseline = smoothed } else { calibrate() }
        }
    }

    @objc func togglePause() {
        if let timer = resumeTimer {
            timer.invalidate()
            resumeTimer = nil
        } else {
            resumeTimer = .scheduledTimer(timeInterval: 3600, target: self, selector: #selector(togglePause), userInfo: nil, repeats: false)
        }
        pauseItem.title = resumeTimer == nil ? "Pause 1 Hour" : "Resume"
        refreshCamera()
    }

    @objc func screenLockChanged(_ notification: Notification) {
        locked = notification.name.rawValue == "com.apple.screenIsLocked"
        refreshCamera()
    }

    func refreshCamera() {
        let running = !locked && resumeTimer == nil
        camera.run(running)
        if !running { smoothed = nil; badSince = nil; setGlow(0) }
    }

    func menuWillOpen(_ menu: NSMenu) {
        statsItem.title = baseline == nil ? "Not calibrated" : "Today: \(day.percent)% upright · \(day.alerts) alerts"
    }

    func appendHistory(_ d: Day) {
        guard d.tracked > 0 else { return }
        let url = URL.applicationSupportDirectory.appending(path: "TrackPosture/history.csv")
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let csv = (try? String(contentsOf: url, encoding: .utf8)) ?? "date,upright_percent,alerts,tracked_minutes\n"
        try? (csv + "\(d.date),\(d.percent),\(d.alerts),\(Int(d.tracked / 60))\n").write(to: url, atomically: true, encoding: .utf8)
    }

    func menuItem(_ title: String, _ action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        return item
    }

    @discardableResult
    func alert(_ title: String, _ text: String, _ buttons: String...) -> Bool {
        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = text
        buttons.forEach { alert.addButton(withTitle: $0) }
        return alert.runModal() == .alertFirstButtonReturn
    }
}

let app = App()
NSApplication.shared.delegate = app
NSApplication.shared.run()
