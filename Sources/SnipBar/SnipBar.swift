import AppKit
import Carbon.HIToolbox
import ScreenCaptureKit
import ServiceManagement
import os

// NSLog output is redacted as <private> in the system log, so log explicitly as public.
private let logger = Logger(subsystem: "local.snipbar", category: "capture")
private func NSLog(_ format: String, _ args: CVarArg...) {
    let text = String(format: format, arguments: args)
    logger.notice("\(text, privacy: .public)")
}

/// Set by the app delegate; invoked on the main thread when Control+Option+S is pressed.
private var hotKeyAction: (() -> Void)?

private func frontAppName() -> String { NSWorkspace.shared.frontmostApplication?.localizedName ?? "?" }

@main
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private let menu = NSMenu()
    private var captureItem: NSMenuItem!
    private var loginItem: NSMenuItem!
    private var hotKeyRef: EventHotKeyRef?
    private var hotKeyRegistered = false
    private var capturing = false  // main-thread only
    private let freezer = ScreenFreezer()
    private var selection: SelectionController?
    private var freezePending = false
    #if SNIPBAR_TEST
    private var testInvisibleOverlay = false
    #endif
    private var invisibleOverlay: Bool {
        #if SNIPBAR_TEST
        return testInvisibleOverlay
        #else
        return false
        #endif
    }
    private var permissionRequested = false
    private var editor: EditorController?
    private var rightClickMonitor: Any?
    // Right-button selection (see pollMouseButtons). All main-thread only.
    private var nativeTask: Process?
    private var buttonPoll: DispatchSourceTimer?   // only exists while the selection UI is up
    private var lastButtonMask = -1
    private var rightDown = false
    private var rightStart = CGPoint.zero
    private var rightDragRect: CGRect?
    private var band: RubberBand?

    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        registerHotKey()

        captureItem = NSMenuItem(title: "Alan Seç", action: #selector(captureFromMenu), keyEquivalent: "s")
        captureItem.keyEquivalentModifierMask = [.control, .option]
        captureItem.target = self
        if !hotKeyRegistered { captureItem.title = "Alan Seç (kısayol kullanılamıyor)" }
        loginItem = NSMenuItem(title: "Mac açılışında başlat", action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
        loginItem.target = self
        let quit = NSMenuItem(title: "Çıkış", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "")
        quit.target = NSApp
        menu.addItem(captureItem)
        menu.addItem(loginItem)
        menu.addItem(.separator())
        menu.addItem(quit)
        menu.delegate = self

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        #if SNIPBAR_TEST
        // A test copy shares this app's preferences, and the system stores a status item's visibility there
        // under its autosave name: a test copy must use its own name before it hides its icon.
        let isTestRun = CommandLine.arguments.contains(where: { $0.hasPrefix("--test-") })
        statusItem.autosaveName = isTestRun ? "SnipBarTestStatusItem" : "SnipBarStatusItem"
        if isTestRun { statusItem.isVisible = false }
        #else
        statusItem.autosaveName = "SnipBarStatusItem"  // remembers a position chosen by Command-dragging
        #endif
        if let button = statusItem.button {
            let image = NSImage(systemSymbolName: "scissors", accessibilityDescription: "SnipBar")
            image?.isTemplate = true
            button.image = image
            button.toolTip = "Sol tık veya ⌃⌥S: alan seç, panoya kopyala • Alanı sağ tuşla seçersen düzenleme penceresi açılır, Bitti deyince kopyalanır • Sağ tık: menü"
            button.target = self
            button.action = #selector(clicked(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            // Event-driven diagnostics: does macOS hide the icon when the menu bar overflows?
            NotificationCenter.default.addObserver(self, selector: #selector(statusItemOcclusionChanged),
                                                   name: NSWindow.didChangeOcclusionStateNotification,
                                                   object: button.window)
        }
        // This macOS version does not deliver a right click to the status item's action, so catch it
        // directly on the status item's own window and show the menu (verified in the log that
        // the event arrives here).
        rightClickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.rightMouseDown]) { [weak self] event in
            guard let self, let window = self.statusItem.button?.window, event.window === window else { return event }
            NSLog("SnipBar right click on icon -> menu")
            DispatchQueue.main.async { self.showMenu() }
            return nil
        }
        freezer.prepare()
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                               object: nil, queue: .main) { [weak self] _ in self?.freezer.prepare() }
        NSLog("SnipBar launched, screenRecordingPermission=%d", CGPreflightScreenCaptureAccess() ? 1 : 0)
        DispatchQueue.main.async { [weak self] in self?.logStatusItem() }  // once the window has settled

        // Test hook: open the editor on an image file without capturing, to check the window lifecycle.
        if let path = ProcessInfo.processInfo.environment["SNIPBAR_EDITOR_TEST_IMAGE"],
           let data = FileManager.default.contents(atPath: path),
           let cg = NSBitmapImageRep(data: data)?.cgImage {
            openEditor(image: cg, originalPNG: data, clipboardHasImage: true)
        }
        #if SNIPBAR_TEST
        runTestHooks()
        #endif
    }

    #if SNIPBAR_TEST
    /// Test-only (built with -D SNIPBAR_TEST): checks the region maths and the rubber band without a mouse.
    private var testWindow: NSWindow?
    private func runTestHooks() {
        let args = CommandLine.arguments
        func parse(_ s: String) -> CGRect? {
            let v = s.split(separator: ",").compactMap { Double($0) }
            return v.count == 4 ? CGRect(x: v[0], y: v[1], width: v[2], height: v[3]) : nil
        }
        if let i = args.firstIndex(of: "--test-region"), args.count > i + 2, let r = parse(args[i + 1]) {
            // A magenta window exactly at `r`, then capture that region to a file.
            let w = NSWindow(contentRect: r, styleMask: .borderless, backing: .buffered, defer: false)
            w.isOpaque = true
            w.backgroundColor = NSColor(srgbRed: 1, green: 0, blue: 1, alpha: 1)
            w.level = .floating
            w.ignoresMouseEvents = true
            w.hasShadow = false
            w.orderFrontRegardless()
            testWindow = w
            let out = args[i + 2]
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                let task = Process()
                task.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
                task.arguments = ["-R", regionArgument(for: r), out]
                let err = Pipe()
                task.standardError = err
                try? task.run()
                task.waitUntilExit()
                let text = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                NSLog("SnipBar TEST region=%@ exit=%d stderr=\"%@\"", regionArgument(for: r), task.terminationStatus, text)
                NSApp.terminate(nil)
            }
        }
        if let i = args.firstIndex(of: "--test-editor"), args.count > i + 1,
           let data = FileManager.default.contents(atPath: args[i + 1]),
           let cg = NSBitmapImageRep(data: data)?.cgImage {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in self?.runEditorTest(original: data, image: cg) }
        }
        if let i = args.firstIndex(of: "--test-memory"), args.count > i + 1, let r = parse(args[i + 1]) {
            // A magenta window at `r`, captured through the path used for right-button selections.
            let w = NSWindow(contentRect: r, styleMask: .borderless, backing: .buffered, defer: false)
            w.isOpaque = true
            w.backgroundColor = NSColor(srgbRed: 1, green: 0, blue: 1, alpha: 1)
            w.level = .floating
            w.ignoresMouseEvents = true
            w.hasShadow = false
            w.orderFrontRegardless()
            testWindow = w
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                let before = NSPasteboard.general.changeCount
                captureRegionToMemory(regionArgument(for: r)) { png, err, status in
                    var line = "exit=\(status) bytes=\(png?.count ?? 0) err=\"\(err)\""
                    if let png, let rep = NSBitmapImageRep(data: png) {
                        var v = [Int](repeating: 0, count: 5)
                        rep.getPixel(&v, atX: rep.pixelsWide / 2, y: rep.pixelsHigh / 2)
                        let magenta = v[0] > 180 && v[2] > 180 && v[1] < 110
                        line += " size=\(rep.pixelsWide)x\(rep.pixelsHigh) centre=(\(v[0]),\(v[1]),\(v[2])) magenta=\(magenta)"
                    }
                    let leftovers = ((try? FileManager.default.contentsOfDirectory(atPath: NSTemporaryDirectory())) ?? [])
                        .filter { $0.hasPrefix("snipbar-") }.count
                    NSLog("SnipBar TEST memory %@ clipboardUntouched=%d leftoverTempFiles=%d", line,
                          NSPasteboard.general.changeCount == before ? 1 : 0, leftovers)
                    NSApp.terminate(nil)
                }
            }
        }
        if let i = args.firstIndex(of: "--test-capture-ui"), args.count > i + 2,
           let delay = Double(args[i + 1]), let hold = Double(args[i + 2]) {
            // Starts the system selection UI like the hotkey does, holds it open, then ends it.
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                NSLog("SnipBar TEST capture-ui start")
                self?.capture()
                DispatchQueue.main.asyncAfter(deadline: .now() + hold) { [weak self] in
                    NSLog("SnipBar TEST capture-ui end")
                    if let t = self?.nativeTask, t.isRunning { t.terminate() }
                    NSApp.terminate(nil)
                }
            }
        }
        if args.contains("--test-select") { runSelectTest() }
        if args.contains("--test-freeze") { runFreezeTest() }
        if args.contains("--test-flow") { runFlowTest() }
        if let i = args.firstIndex(of: "--test-band"), args.count > i + 1, let r = parse(args[i + 1]) {
            band = RubberBand()
            band?.show(r)
            NSLog("SnipBar TEST band shown at %@", NSStringFromRect(r))
            DispatchQueue.main.asyncAfter(deadline: .now() + 8) { NSApp.terminate(nil) }
        }
    }

    /// Drives shapes through the editor's canvas (a 600x300 white test image shown at 2x, i.e. 300x150 points)
    /// and checks when the clipboard is, and is not, written.
    private func runEditorTest(original: Data, image cg: CGImage) {
        let pb = NSPasteboard.general
        var failures = 0
        func check(_ name: String, _ ok: Bool, _ detail: String = "") {
            NSLog("SnipBar TEST editor %@ %@ %@", ok ? "PASS" : "FAIL", name, detail)
            if !ok { failures += 1 }
        }
        func clipboardImage() -> NSBitmapImageRep? { pb.data(forType: .png).flatMap { NSBitmapImageRep(data: $0) } }
        func px(_ r: NSBitmapImageRep, _ x: Int, _ y: Int) -> (Int, Int, Int) {
            var v = [Int](repeating: 0, count: 5)
            r.getPixel(&v, atX: x, y: y)
            return (v[0], v[1], v[2])
        }
        let previous = "previous clipboard content"
        pb.clearContents()
        pb.setString(previous, forType: .string)
        let seeded = pb.changeCount

        // 1. Editing writes nothing.
        openEditor(image: cg, originalPNG: original, clipboardHasImage: false)
        guard let canvas = editor?.testCanvas else { NSLog("SnipBar TEST editor FAIL no editor"); NSApp.terminate(nil); return }
        let scale = CGFloat(600) / canvas.bounds.width
        canvas.shapes.append(AnnotShape(kind: .outline, rect: CGRect(x: 40, y: 40, width: 100, height: 60)))
        canvas.shapes.append(AnnotShape(kind: .box, rect: CGRect(x: 100, y: 100, width: 20, height: 20)))
        canvas.undo()
        canvas.shapes.append(AnnotShape(kind: .box, rect: CGRect(x: 200, y: 50, width: 60, height: 40)))
        check("editing (outline, box, undo, box) never touches the clipboard", pb.changeCount == seeded, "changeCount \(seeded) -> \(pb.changeCount)")
        check("the previous clipboard content is still there", pb.string(forType: .string) == previous)
        if let f = editor?.testFrame { NSLog("SnipBar TEST placement frame=%@", NSStringFromRect(f)) }

        // 2. Bitti / Enter copies exactly once.
        editor?.testFinish()
        check("Bitti: exactly one clipboard write", pb.changeCount == seeded + 1, "changeCount \(seeded) -> \(pb.changeCount)")
        if let r = clipboardImage() {
            let edge = px(r, Int(40 * scale), 300 - Int(70 * scale))
            let inBox = px(r, Int(230 * scale), 300 - Int(70 * scale))
            let hidden = px(r, Int(110 * scale), 300 - Int(110 * scale))  // the undone box
            check("Bitti: size unchanged", r.pixelsWide == 600 && r.pixelsHigh == 300, "\(r.pixelsWide)x\(r.pixelsHigh)")
            check("Bitti: outline edge is red", edge.0 > 200 && edge.1 < 110 && edge.2 < 110, "\(edge)")
            check("Bitti: box is black", inBox.0 < 5 && inBox.1 < 5 && inBox.2 < 5, "\(inBox)")
            check("Bitti: the undone box is not there", hidden.0 > 240 && hidden.1 > 240, "\(hidden)")
        } else { check("Bitti: clipboard has an image", false) }
        check("Bitti: editor closed", editor == nil)
        let afterDone = pb.changeCount

        // 3. Esc / close button: nothing is copied.
        openEditor(image: cg, originalPNG: original, clipboardHasImage: false)
        editor?.testCanvas?.shapes.append(AnnotShape(kind: .box, rect: CGRect(x: 10, y: 10, width: 50, height: 50)))
        editor?.close(reason: "escape")
        check("Esc: clipboard untouched", pb.changeCount == afterDone, "changeCount \(afterDone) -> \(pb.changeCount)")

        // 4. Bitti with nothing drawn, capture not on the clipboard yet (right-button selection): the capture is copied.
        openEditor(image: cg, originalPNG: original, clipboardHasImage: false)
        editor?.testFinish()
        check("Bitti, nothing drawn: one write", pb.changeCount == afterDone + 1, "changeCount \(afterDone) -> \(pb.changeCount)")
        check("Bitti, nothing drawn: it is the original capture", pb.data(forType: .png) == original)
        let c4 = pb.changeCount

        // 5. Bitti with nothing drawn, capture already on the clipboard (left-button flow): nothing to do.
        openEditor(image: cg, originalPNG: original, clipboardHasImage: true)
        editor?.testFinish()
        check("Bitti, nothing drawn, capture already copied: no write", pb.changeCount == c4, "changeCount \(c4) -> \(pb.changeCount)")

        NSLog("SnipBar TEST editor DONE failures=%ld", failures)
        NSApp.terminate(nil)
    }

    private func waitUntil(_ timeout: Double, _ cond: @escaping () -> Bool, _ then: @escaping (Bool) -> Void) {
        let end = Date().addingTimeInterval(timeout)
        func tick() {
            if cond() { then(true) } else if Date() > end { then(false) } else {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05, execute: tick)
            }
        }
        tick()
    }

    /// Selection logic on a synthetic picture (four coloured quadrants), with invisible panels.
    private func runSelectTest() {
        var failures = 0
        func check(_ name: String, _ ok: Bool, _ detail: String = "") {
            NSLog("SnipBar TEST select %@ %@ %@", ok ? "PASS" : "FAIL", name, detail)
            if !ok { failures += 1 }
        }
        let w = 600, h = 300
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue), let screen = NSScreen.main else { return }
        func fill(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ rect: CGRect) {
            ctx.setFillColor(CGColor(srgbRed: r, green: g, blue: b, alpha: 1))
            ctx.fill(rect)
        }
        // CGContext origin is bottom-left; the finished image's first row is the top.
        fill(1, 0, 0, CGRect(x: 0, y: h / 2, width: w / 2, height: h / 2))      // top-left red
        fill(0, 1, 0, CGRect(x: w / 2, y: h / 2, width: w / 2, height: h / 2))  // top-right green
        fill(0, 0, 1, CGRect(x: 0, y: 0, width: w / 2, height: h / 2))          // bottom-left blue
        fill(1, 1, 0, CGRect(x: w / 2, y: 0, width: w / 2, height: h / 2))      // bottom-right yellow
        guard let image = ctx.makeImage() else { return }
        let view = screen.frame.size
        let sx = CGFloat(w) / view.width, sy = CGFloat(h) / view.height
        func px(_ rep: NSBitmapImageRep, _ x: Int, _ y: Int) -> (Int, Int, Int) {
            var v = [Int](repeating: 0, count: 5)
            rep.getPixel(&v, atX: x, y: y)
            return (v[0], v[1], v[2])
        }
        func run(_ body: (SelectionController) -> Void) -> (result: (CGImage, Bool)?, cancelled: Bool) {
            let c = SelectionController(frames: [ScreenFreezer.Frame(screen: screen, image: image)], invisible: true)
            var res: (CGImage, Bool)?
            var cancelled = false
            c.onSelect = { res = ($0, $1) }
            c.onCancel = { cancelled = true }
            body(c)
            return (res, cancelled)
        }

        // 1. left drag inside the top-left quadrant
        var r = run { $0.testView?.testDrag(from: CGPoint(x: 100, y: 600), to: CGPoint(x: 700, y: 900), right: false) }
        if let (img, right) = r.result {
            let rep = NSBitmapImageRep(cgImage: img)
            let c = px(rep, rep.pixelsWide / 2, rep.pixelsHigh / 2)
            check("left drag: not the editor", !right)
            check("left drag: crop size follows the drag", abs(img.width - Int(600 * sx)) <= 2 && abs(img.height - Int(300 * sy)) <= 2, "\(img.width)x\(img.height) expected ~\(Int(600 * sx))x\(Int(300 * sy))")
            check("left drag: crop is from the top-left quadrant (red)", c.0 > 240 && c.1 < 15 && c.2 < 15, "\(c)")
        } else { check("left drag: a result", false) }

        // 2. right drag across the centre: all four colours, in the right places
        r = run { $0.testView?.testDrag(from: CGPoint(x: 500, y: 300), to: CGPoint(x: 1000, y: 700), right: true) }
        if let (img, right) = r.result {
            let rep = NSBitmapImageRep(cgImage: img)
            let tl = px(rep, 2, 2), tr = px(rep, img.width - 3, 2), bl = px(rep, 2, img.height - 3), br = px(rep, img.width - 3, img.height - 3)
            check("right drag: opens the editor", right)
            check("right drag: top-left red", tl.0 > 240 && tl.1 < 15 && tl.2 < 15, "\(tl)")
            check("right drag: top-right green", tr.1 > 240 && tr.0 < 15 && tr.2 < 15, "\(tr)")
            check("right drag: bottom-left blue", bl.2 > 240 && bl.0 < 15 && bl.1 < 15, "\(bl)")
            check("right drag: bottom-right yellow", br.0 > 240 && br.1 > 240 && br.2 < 15, "\(br)")
        } else { check("right drag: a result", false) }

        // 3. things that must select nothing
        r = run { $0.testView?.testDrag(from: CGPoint(x: 300, y: 300), to: CGPoint(x: 303, y: 303), right: false) }
        check("a 3 pt drag selects nothing", r.result == nil && !r.cancelled)
        r = run { $0.testView?.testDrag(from: CGPoint(x: 300, y: 300), to: CGPoint(x: 300, y: 300), right: true) }
        check("a plain click selects nothing", r.result == nil && !r.cancelled)
        r = run { c in
            c.testView?.begin(at: CGPoint(x: 100, y: 100), right: false)
            c.testView?.move(to: CGPoint(x: 400, y: 400))
            c.testView?.end(at: CGPoint(x: 400, y: 400), right: true)  // the other button went up: ignored
        }
        check("releasing the other button does not finish the selection", r.result == nil)
        r = run { c in
            c.testView?.begin(at: CGPoint(x: 100, y: 100), right: false)
            c.testView?.begin(at: CGPoint(x: 900, y: 900), right: true)  // a second button during the drag: ignored
            c.testView?.end(at: CGPoint(x: 400, y: 400), right: false)
        }
        if let (img, right) = r.result {
            check("a second button during the drag is ignored", !right && abs(img.width - Int(300 * sx)) <= 2, "\(img.width)x\(img.height)")
        } else { check("a second button during the drag is ignored", false, "no result") }

        // 4. Esc
        r = run { $0.testEscape() }
        check("Esc cancels", r.result == nil && r.cancelled)

        // 5. a selection at the far edge stays inside the picture
        r = run { $0.testView?.testDrag(from: CGPoint(x: view.width - 100, y: 10), to: CGPoint(x: view.width, y: 100), right: false) }
        if let (img, _) = r.result {
            let rep = NSBitmapImageRep(cgImage: img)
            let c = px(rep, rep.pixelsWide / 2, rep.pixelsHigh / 2)
            check("edge selection: yellow corner, inside the picture", c.0 > 240 && c.1 > 240 && c.2 < 15 && img.width <= Int(100 * sx) + 2, "\(img.width)x\(img.height) \(c)")
        } else { check("edge selection: a result", false) }

        NSLog("SnipBar TEST select DONE failures=%ld", failures)
        NSApp.terminate(nil)
    }

    /// How fast the freeze is, warm and after a pause.
    private func runFreezeTest() {
        freezer.prepare()
        waitUntil(3, { self.freezer.isReady }) { ready in
            guard ready else { NSLog("SnipBar TEST freeze FAIL not prepared"); NSApp.terminate(nil); return }
            var times: [String] = []
            func one(_ label: String, _ next: @escaping () -> Void) {
                let t = DispatchTime.now()
                self.freezer.freeze { frames in
                    if let f = frames?.first {
                        times.append(String(format: "%@=%.0fms(%dx%d)", label, msSince(t), f.image.width, f.image.height))
                    } else { times.append("\(label)=FAILED") }
                    next()
                }
            }
            func warm(_ i: Int) {
                guard i < 6 else {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 12) {
                        one("after12sIdle") {
                            NSLog("SnipBar TEST freeze latency: %@", times.joined(separator: " "))
                            NSApp.terminate(nil)
                        }
                    }
                    return
                }
                one("run\(i)") { DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { warm(i + 1) } }
            }
            warm(0)
        }
    }

    /// The real freeze (ScreenCaptureKit) with invisible panels, driven by simulated drags: left copies,
    /// right opens the editor and copies nothing, Esc leaves the clipboard alone.
    private func runFlowTest() {
        let pb = NSPasteboard.general
        var failures = 0
        func check(_ name: String, _ ok: Bool, _ detail: String = "") {
            NSLog("SnipBar TEST flow %@ %@ %@", ok ? "PASS" : "FAIL", name, detail)
            if !ok { failures += 1 }
        }
        func spread(_ rep: NSBitmapImageRep) -> Double {  // standard deviation over a sample: a real picture is not flat
            var sum = 0.0, sumSq = 0.0, n = 0.0
            for yy in stride(from: 0, to: rep.pixelsHigh, by: max(rep.pixelsHigh / 20, 1)) {
                for xx in stride(from: 0, to: rep.pixelsWide, by: max(rep.pixelsWide / 20, 1)) {
                    var v = [Int](repeating: 0, count: 5)
                    rep.getPixel(&v, atX: xx, y: yy)
                    let g = Double(v[0] + v[1] + v[2]) / 3
                    sum += g; sumSq += g * g; n += 1
                }
            }
            let mean = sum / n
            return max(sumSq / n - mean * mean, 0).squareRoot()
        }
        testInvisibleOverlay = true
        freezer.prepare()
        waitUntil(3, { self.freezer.isReady }) { ready in
            check("the freezer is prepared", ready)
            guard ready else { NSApp.terminate(nil); return }
            pb.clearContents()
            pb.setString("previous clipboard content", forType: .string)
            let seeded = pb.changeCount
            let scale = NSScreen.main?.backingScaleFactor ?? 2

            // 1. left drag copies
            let t0 = DispatchTime.now()
            self.capture()
            self.waitUntil(3, { self.selection != nil }) { shown in
                check("the selection is shown after the freeze", shown, String(format: "%.0f ms after the trigger", msSince(t0)))
                guard shown, let view = self.selection?.testView else { NSApp.terminate(nil); return }
                view.testDrag(from: CGPoint(x: 300, y: 300), to: CGPoint(x: 700, y: 600), right: false)
                check("left drag: clipboard written exactly once", pb.changeCount == seeded + 1, "changeCount \(seeded) -> \(pb.changeCount)")
                if let rep = pb.data(forType: .png).flatMap({ NSBitmapImageRep(data: $0) }) {
                    check("left drag: size is the dragged area times the scale",
                          abs(rep.pixelsWide - Int(400 * scale)) <= 2 && abs(rep.pixelsHigh - Int(300 * scale)) <= 2,
                          "\(rep.pixelsWide)x\(rep.pixelsHigh) expected \(Int(400 * scale))x\(Int(300 * scale))")
                    let sd = spread(rep)
                    check("left drag: the picture is real screen content, not blank", sd > 5, String(format: "spread %.1f", sd))
                } else { check("left drag: clipboard has an image", false) }
                check("left drag: capture is finished", !self.capturing && self.selection == nil)
                let afterLeft = pb.changeCount

                // 2. right drag opens the editor and copies nothing
                self.capture()
                self.waitUntil(3, { self.selection != nil }) { shown2 in
                    guard shown2, let view2 = self.selection?.testView else { check("second selection shown", false); NSApp.terminate(nil); return }
                    view2.testDrag(from: CGPoint(x: 300, y: 300), to: CGPoint(x: 700, y: 600), right: true)
                    check("right drag: nothing copied", pb.changeCount == afterLeft, "changeCount \(afterLeft) -> \(pb.changeCount)")
                    check("right drag: editor opened", self.editor != nil)
                    self.editor?.close(reason: "test")

                    // 3. Esc leaves the clipboard alone
                    self.capture()
                    self.waitUntil(3, { self.selection != nil }) { shown3 in
                        guard shown3 else { check("third selection shown", false); NSApp.terminate(nil); return }
                        self.selection?.testEscape()
                        check("Esc: capture ended", !self.capturing && self.selection == nil)
                        check("Esc: clipboard untouched", pb.changeCount == afterLeft, "changeCount \(afterLeft) -> \(pb.changeCount)")
                        NSLog("SnipBar TEST flow DONE failures=%ld", failures)
                        NSApp.terminate(nil)
                    }
                }
            }
        }
    }
    #endif

    // MARK: Hotkey, menu, login item, diagnostics

    /// Control+Option+S via Carbon: needs no Accessibility / Input Monitoring permission.
    private func registerHotKey() {
        hotKeyAction = { [weak self] in
            self?.capture()  // first: the picture must not wait for anything
            NSLog("SnipBar hotkey pressed front=%@", frontAppName())
        }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let installStatus = InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
            DispatchQueue.main.async { hotKeyAction?() }
            return noErr
        }, 1, &spec, nil, nil)
        var status = installStatus
        if installStatus == noErr {
            let id = EventHotKeyID(signature: OSType(0x534E5042), id: 1)  // 'SNPB'
            status = RegisterEventHotKey(UInt32(kVK_ANSI_S), UInt32(controlKey | optionKey), id,
                                         GetApplicationEventTarget(), 0, &hotKeyRef)
        }
        hotKeyRegistered = status == noErr
        NSLog("SnipBar hotkey ctrl+opt+S registered=%d status=%d", hotKeyRegistered ? 1 : 0, Int32(status))
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        loginItem.state = SMAppService.mainApp.status == .enabled ? .on : .off
    }

    @objc private func captureFromMenu() { capture() }

    @objc private func toggleLaunchAtLogin() {
        let service = SMAppService.mainApp
        do {
            if service.status == .enabled {
                try service.unregister()
            } else {
                try service.register()
            }
            NSLog("SnipBar launch at login now status=%ld", service.status.rawValue)
            if service.status == .requiresApproval {
                showError("Mac açılışında başlatma için onay gerekiyor: Sistem Ayarları > Genel > Açılış Öğeleri bölümünden SnipBar'a izin verin.",
                          offerSettings: false)
            }
        } catch {
            NSLog("SnipBar launch at login change failed: %@", error.localizedDescription)
            showError("Mac açılışında başlatma ayarı değiştirilemedi: \(error.localizedDescription)", offerSettings: false)
        }
    }

    @objc private func statusItemOcclusionChanged(_ note: Notification) { logStatusItem() }

    private func logStatusItem() {
        let window = statusItem.button?.window
        NSLog("SnipBar status item visible=%d x=%.0f front=%@",
              (window?.occlusionState.contains(.visible) ?? false) ? 1 : 0, window?.frame.minX ?? -1,
              NSWorkspace.shared.frontmostApplication?.localizedName ?? "?")
    }

    private func showMenu() {
        guard let button = statusItem.button else { return }
        statusItem.menu = menu
        button.performClick(nil)
        statusItem.menu = nil
    }

    /// Plain left click: start the area selection (the selection button decides what happens next,
    /// see `finished`). Option or Control click: the menu. A right click is handled by the monitor above.
    @objc private func clicked(_ sender: NSStatusBarButton) {
        guard let event = NSApp.currentEvent else { return }
        if event.modifierFlags.contains(.option) || event.modifierFlags.contains(.control)
            || event.type == .rightMouseUp {
            showMenu()
        } else {
            capture()  // first: the picture must not wait for anything
            NSLog("SnipBar icon click front=%@", frontAppName())
        }
    }

    /// Start of every capture (icon, hotkey, menu). The picture is taken FIRST and nothing may delay it:
    /// an app that hides its window when the menu bar icon takes its focus (it fades out over some tens of
    /// milliseconds) is still on screen right after the click. The selection then happens on that frozen picture.
    private func capture() {
        guard !capturing else { return }
        guard freezer.isReady, CGPreflightScreenCaptureAccess() else {
            captureWithSystemSelector()  // not prepared yet, or no permission: the old path handles both
            return
        }
        editor?.close(reason: "new capture")  // only one editor at a time; closing also clears it
        capturing = true
        freezePending = true
        let started = DispatchTime.now()
        freezer.freeze { [weak self] frames in
            guard let self, self.freezePending else { return }  // the watchdog below may have taken over
            self.freezePending = false
            guard let frames else {
                NSLog("SnipBar freeze failed, using the system selector")
                self.capturing = false
                self.captureWithSystemSelector()
                return
            }
            NSLog("SnipBar freeze: %ld frame(s) in %.0f ms", frames.count, msSince(started))
            self.beginSelection(frames)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            guard let self, self.freezePending else { return }
            self.freezePending = false
            NSLog("SnipBar freeze timed out, using the system selector")
            self.capturing = false
            self.captureWithSystemSelector()
        }
    }

    private func beginSelection(_ frames: [ScreenFreezer.Frame]) {
        let controller = SelectionController(frames: frames, invisible: invisibleOverlay)
        controller.onSelect = { [weak self] image, edit in self?.selectionFinished(image: image, edit: edit) }
        controller.onCancel = { [weak self] in self?.selectionEnded(reason: "cancelled") }
        selection = controller
        controller.show()
    }

    private func selectionEnded(reason: String) {
        selection = nil
        capturing = false
        freezer.prepare()  // keeps the prepared displays and filters fresh
        NSLog("SnipBar selection ended (%@)", reason)
    }

    /// Left button: copy to the clipboard. Right button: open the editor (nothing is copied until Bitti).
    private func selectionFinished(image: CGImage, edit: Bool) {
        selectionEnded(reason: edit ? "right button, editor" : "left button, copy")
        let rep = NSBitmapImageRep(cgImage: image)
        guard let png = rep.representation(using: .png, properties: [:]) else {
            showError("Seçilen alan PNG'ye çevrilemedi.", offerSettings: false)
            return
        }
        if edit {
            openEditor(image: image, originalPNG: png, clipboardHasImage: false)
        } else {
            let pb = NSPasteboard.general
            pb.clearContents()
            pb.setData(png, forType: .png)
            if let tiff = rep.tiffRepresentation { pb.setData(tiff, forType: .tiff) }
            NSLog("SnipBar copied selection %dx%d bytes=%ld changeCount=%ld", image.width, image.height, png.count, pb.changeCount)
        }
    }

    /// The previous way, kept as the fallback: the system's own selection UI (`screencapture -i`).
    private func captureWithSystemSelector() {
        guard !capturing else { return }
        editor?.close(reason: "new capture")  // only one editor at a time; closing also clears it
        // Without Screen Recording permission screencapture shows the selection UI
        // but fails to produce an image, so ask for it up front.
        guard CGPreflightScreenCaptureAccess() else {
            NSLog("SnipBar capture blocked: no Screen Recording permission")
            if permissionRequested {
                // The system prompt is shown only once; afterwards send the user to Settings.
                openScreenRecordingSettings()
            } else {
                permissionRequested = true
                CGRequestScreenCaptureAccess()
            }
            return
        }
        capturing = true
        rightDown = false
        rightDragRect = nil
        let countBefore = NSPasteboard.general.changeCount
        let started = Date()
        let stderrPipe = Pipe()
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        task.arguments = ["-i", "-c"]  // interactive selection, result to clipboard
        task.standardError = stderrPipe
        task.terminationHandler = { [weak self] finished in
            let errData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
            let errText = (String(data: errData, encoding: .utf8) ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let status = finished.terminationStatus
            DispatchQueue.main.async {
                self?.finished(status: status, stderr: errText, countBefore: countBefore, started: started)
            }
        }
        do {
            try task.run()
            nativeTask = task
            NSLog("SnipBar capture start front=%@", frontAppName())
            startWatchingMouseButtons()
        } catch {
            capturing = false
            NSLog("SnipBar could not start screencapture: %@", error.localizedDescription)
            showError("Ekran yakalama başlatılamadı: \(error.localizedDescription)", offerSettings: false)
        }
    }

    // MARK: Right-button selection
    //
    // Left-drag selection is the system's own (`screencapture -i`), and the image is simply copied.
    // Selecting with the RIGHT button additionally keeps the image open in the editor. The system
    // selection UI takes mouse events for itself (a global event monitor saw nothing, verified in
    // the log), so the button state is polled instead, every 20 ms and only while a selection is open.
    // If the system UI ignores the right-button drag, the dragged rectangle is captured here with
    // `screencapture -R`; if it handles it, its result is used and only the editor is added.

    private func startWatchingMouseButtons() {
        stopWatchingMouseButtons()
        lastButtonMask = -1
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now(), repeating: .milliseconds(20), leeway: .milliseconds(5))
        timer.setEventHandler { [weak self] in self?.pollMouseButtons() }
        timer.resume()
        buttonPoll = timer
    }

    private func stopWatchingMouseButtons() {
        buttonPoll?.cancel()
        buttonPoll = nil
        band?.hide()
        rightDown = false
    }

    private func pollMouseButtons() {
        let mask = Int(NSEvent.pressedMouseButtons)
        let p = NSEvent.mouseLocation
        if mask != lastButtonMask {
            lastButtonMask = mask
            NSLog("SnipBar selection buttons mask=%ld x=%.0f y=%.0f", mask, p.x, p.y)
        }
        if mask & 0b10 != 0 {  // right button down
            if !rightDown { rightDown = true; rightStart = p }
            let r = rectBetween(rightStart, p)
            if r.width >= 4 || r.height >= 4 {
                if band == nil { band = RubberBand() }
                band?.show(r)
            }
        } else if rightDown {  // right button released
            let r = rectBetween(rightStart, p)
            rightDown = false
            band?.hide()
            guard r.width >= 4, r.height >= 4 else { return }  // a plain right click: ignore
            rightDragRect = r
            stopWatchingMouseButtons()
            if let task = nativeTask, task.isRunning { task.terminate() }  // `finished` carries on from here
        }
    }

    private func finished(status: Int32, stderr: String, countBefore: Int, started: Date) {
        let rightHeld = rightDown  // the system UI finished while the right button still reads as down
        let rect = rightDragRect
        stopWatchingMouseButtons()
        nativeTask = nil
        let pasteboard = NSPasteboard.general
        let countAfter = pasteboard.changeCount
        let hasImage = pasteboard.availableType(from: [.png, .tiff]) != nil
        let copied = countAfter != countBefore && hasImage
        NSLog("SnipBar capture done: exit=%d duration=%.2fs changeCount %ld->%ld image=%d rightDrag=%d front=%@ stderr=\"%@\"",
              status, Date().timeIntervalSince(started), countBefore, countAfter, hasImage ? 1 : 0,
              (rect != nil || rightHeld) ? 1 : 0, frontAppName(), stderr)

        if copied {
            capturing = false
            if rect != nil || rightHeld { showEditor() }
            return
        }
        if let rect {
            captureRegion(rect)  // `capturing` stays set until this finishes
            return
        }
        capturing = false
        // Escape exits cleanly with no output; anything else is a real failure.
        if status != 0 || !stderr.isEmpty {
            let denied = !CGPreflightScreenCaptureAccess() || stderr.contains("could not create image")
            showError(denied
                ? "Görüntü alınamadı: SnipBar'ın Ekran Kaydı izni yok ya da geçersiz.\n\n\(stderr)"
                : "Görüntü panoya kopyalanamadı (çıkış kodu \(status)).\n\n\(stderr)",
                offerSettings: denied)
        }
    }

    /// Captures `cocoaRect` (AppKit screen coordinates) into memory and opens the editor on it. Nothing
    /// is put on the clipboard here: the editor copies once, when the user presses Bitti.
    private func captureRegion(_ cocoaRect: CGRect) {
        let region = regionArgument(for: cocoaRect)
        let started = Date()
        // The system selection UI and the rubber band were closed a moment ago; give the compositor
        // a beat so neither ends up in the picture.
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(60)) { [weak self] in
            captureRegionToMemory(region) { png, errText, status in
                guard let self else { return }
                self.capturing = false
                let image = png.flatMap { NSBitmapImageRep(data: $0)?.cgImage }
                NSLog("SnipBar region capture done: region=%@ exit=%d duration=%.2fs bytes=%ld ok=%d stderr=\"%@\"",
                      region, status, Date().timeIntervalSince(started), png?.count ?? 0, image == nil ? 0 : 1, errText)
                if let png, let image {
                    self.openEditor(image: image, originalPNG: png, clipboardHasImage: false)
                } else {
                    self.showError("Seçilen alan yakalanamadı (çıkış kodu \(status)).\n\n\(errText)", offerSettings: false)
                }
            }
        }
    }

    /// Opens the editor on the capture that `screencapture -c` just put on the clipboard.
    private func showEditor() {
        let pb = NSPasteboard.general
        let png = pb.data(forType: .png)
        guard let data = png ?? pb.data(forType: .tiff), let cg = NSBitmapImageRep(data: data)?.cgImage else {
            NSLog("SnipBar editor: could not read image back from clipboard")
            return
        }
        openEditor(image: cg, originalPNG: png, clipboardHasImage: true)
    }

    /// `originalPNG` is the capture as taken; `clipboardHasImage` says whether it is already on the clipboard.
    private func openEditor(image: CGImage, originalPNG: Data?, clipboardHasImage: Bool) {
        editor?.close(reason: "replaced")
        let controller = EditorController(image: image, originalPNG: originalPNG, clipboardHasImage: clipboardHasImage)
        controller.onClosed = { [weak self, weak controller] in
            if let self, self.editor === controller { self.editor = nil }
        }
        editor = controller
        controller.show()
    }

    private func openScreenRecordingSettings() {
        NSWorkspace.shared.open(URL(string:
            "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
    }

    private func showError(_ text: String, offerSettings: Bool) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "SnipBar"
        alert.informativeText = text
        alert.addButton(withTitle: "Tamam")
        if offerSettings { alert.addButton(withTitle: "Sistem Ayarları'nı Aç") }
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertSecondButtonReturn { openScreenRecordingSettings() }
    }
}

// MARK: - Freeze the screen, select on the frozen picture

private func msSince(_ t: DispatchTime) -> Double { Double(DispatchTime.now().uptimeNanoseconds - t.uptimeNanoseconds) / 1e6 }

/// Takes the picture the selection works on as soon as possible after the trigger. The displays and the
/// capture filters are prepared in advance, so a trigger only has to call captureImage (about 20-40 ms).
private final class ScreenFreezer {
    struct Frame {
        let screen: NSScreen
        let image: CGImage  // pixels, origin top-left
    }
    private struct Prepared {
        let displayID: CGDirectDisplayID
        let filter: SCContentFilter
        let config: SCStreamConfiguration
    }
    private var prepared: [Prepared] = []  // main thread only
    var isReady: Bool { !prepared.isEmpty }

    private static func displayID(of screen: NSScreen) -> CGDirectDisplayID? {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }

    func prepare() {
        SCShareableContent.getExcludingDesktopWindows(false, onScreenWindowsOnly: true) { [weak self] content, error in
            DispatchQueue.main.async {
                guard let self else { return }
                guard let content else {
                    NSLog("SnipBar freeze: could not prepare: %@", error.map { String(describing: $0) } ?? "no content")
                    return
                }
                var list: [Prepared] = []
                for display in content.displays {
                    guard let screen = NSScreen.screens.first(where: { Self.displayID(of: $0) == display.displayID }) else { continue }
                    let config = SCStreamConfiguration()
                    config.width = Int((screen.frame.width * screen.backingScaleFactor).rounded())
                    config.height = Int((screen.frame.height * screen.backingScaleFactor).rounded())
                    config.showsCursor = false
                    config.pixelFormat = kCVPixelFormatType_32BGRA
                    list.append(Prepared(displayID: display.displayID,
                                         filter: SCContentFilter(display: display, excludingWindows: []), config: config))
                }
                self.prepared = list
            }
        }
    }

    /// Calls `completion` on the main queue with one frame per display, or nil if any capture failed.
    func freeze(completion: @escaping ([Frame]?) -> Void) {
        let items = prepared
        guard !items.isEmpty else { completion(nil); return }
        let box = FrameBox()
        let group = DispatchGroup()
        for item in items {
            group.enter()
            SCScreenshotManager.captureImage(contentFilter: item.filter, configuration: item.config) { image, error in
                if let image {
                    box.set(image, for: item.displayID)
                } else {
                    NSLog("SnipBar freeze: capture failed: %@", error.map { String(describing: $0) } ?? "no image")
                }
                group.leave()
            }
        }
        group.notify(queue: .main) {
            var frames: [Frame] = []
            for item in items {
                guard let image = box.image(for: item.displayID),
                      let screen = NSScreen.screens.first(where: { Self.displayID(of: $0) == item.displayID }) else {
                    completion(nil)
                    return
                }
                frames.append(Frame(screen: screen, image: image))
            }
            completion(frames)
        }
    }
}

private final class FrameBox: @unchecked Sendable {
    private var images: [CGDirectDisplayID: CGImage] = [:]
    private let lock = NSLock()
    func set(_ image: CGImage, for id: CGDirectDisplayID) { lock.lock(); images[id] = image; lock.unlock() }
    func image(for id: CGDirectDisplayID) -> CGImage? { lock.lock(); defer { lock.unlock() }; return images[id] }
}

/// Crops `image` (pixels, origin top-left) to `viewRect` (points, origin bottom-left) of a view of `viewSize`.
func cropFrozen(_ image: CGImage, viewRect: CGRect, viewSize: CGSize) -> CGImage? {
    guard viewSize.width > 0, viewSize.height > 0 else { return nil }
    let sx = CGFloat(image.width) / viewSize.width
    let sy = CGFloat(image.height) / viewSize.height
    let pixels = CGRect(x: viewRect.minX * sx, y: (viewSize.height - viewRect.maxY) * sy,
                        width: viewRect.width * sx, height: viewRect.height * sy).integral
    return image.cropping(to: pixels.intersection(CGRect(x: 0, y: 0, width: image.width, height: image.height)))
}

/// Full-screen panel that shows the frozen picture of one display. It becomes key without activating
/// SnipBar (so the Esc key reaches it, and the app that was in front stays the active app).
private final class SelectionPanel: NSPanel {
    var onEscape: (() -> Void)?
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override func keyDown(with event: NSEvent) { if event.keyCode == 53 { onEscape?() } }
    override func cancelOperation(_ sender: Any?) { onEscape?() }
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }  // may cover the menu bar
}

private final class SelectionView: NSView {
    private let image: CGImage
    var onSelect: ((CGImage, Bool) -> Void)?
    private let dim = CAShapeLayer()
    private let border = CAShapeLayer()
    private let label = CATextLayer()
    private var start: CGPoint?
    private var rightButton = false

    init(frame: NSRect, image: CGImage, scale: CGFloat) {
        self.image = image
        super.init(frame: frame)
        wantsLayer = true
        layer?.contents = image
        layer?.contentsGravity = .resize
        layer?.contentsScale = scale
        dim.fillColor = NSColor.black.withAlphaComponent(0.4).cgColor
        dim.fillRule = .evenOdd
        border.fillColor = nil
        border.strokeColor = NSColor.white.cgColor
        border.lineWidth = 1.5
        label.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        label.fontSize = 12
        label.alignmentMode = .center
        label.foregroundColor = NSColor.white.cgColor
        label.backgroundColor = NSColor.black.withAlphaComponent(0.65).cgColor
        label.cornerRadius = 4
        label.contentsScale = scale
        for l in [dim, border, label] {
            l.isHidden = true
            layer?.addSublayer(l)
        }
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.cursorUpdate, .mouseMoved, .activeAlways, .inVisibleRect], owner: self))
    }
    required init?(coder: NSCoder) { fatalError() }

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func cursorUpdate(with event: NSEvent) { NSCursor.crosshair.set() }
    override func mouseMoved(with event: NSEvent) { NSCursor.crosshair.set() }

    private func point(_ e: NSEvent) -> CGPoint {
        let p = convert(e.locationInWindow, from: nil)
        return CGPoint(x: min(max(p.x, 0), bounds.width), y: min(max(p.y, 0), bounds.height))
    }
    override func mouseDown(with e: NSEvent) { begin(at: point(e), right: false) }
    override func rightMouseDown(with e: NSEvent) { begin(at: point(e), right: true) }
    override func mouseDragged(with e: NSEvent) { move(to: point(e)) }
    override func rightMouseDragged(with e: NSEvent) { move(to: point(e)) }
    override func mouseUp(with e: NSEvent) { end(at: point(e), right: false) }
    override func rightMouseUp(with e: NSEvent) { end(at: point(e), right: true) }

    // The selection logic is separate from the events so that tests can drive it.
    func begin(at p: CGPoint, right: Bool) {
        guard start == nil else { return }  // the first button that went down owns the selection
        start = p
        rightButton = right
    }
    func move(to p: CGPoint) {
        guard let s = start else { return }
        show(rectBetween(s, p))
    }
    func end(at p: CGPoint, right: Bool) {
        guard let s = start, right == rightButton else { return }
        start = nil
        let r = rectBetween(s, p)
        hideSelection()
        guard r.width >= 4, r.height >= 4,  // a plain click selects nothing
              let cropped = cropFrozen(image, viewRect: r, viewSize: bounds.size) else { return }
        onSelect?(cropped, right)
    }
    func testDrag(from a: CGPoint, to b: CGPoint, right: Bool) {
        begin(at: a, right: right)
        move(to: b)
        end(at: b, right: right)
    }

    private func show(_ r: CGRect) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let path = CGMutablePath()
        path.addRect(bounds)
        path.addRect(r)
        dim.frame = bounds
        dim.path = path
        border.frame = bounds
        border.path = CGPath(rect: r, transform: nil)
        let w = Int((r.width * CGFloat(image.width) / bounds.width).rounded())
        let h = Int((r.height * CGFloat(image.height) / bounds.height).rounded())
        let text = "\(w) × \(h)"
        let textW = (text as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 12, weight: .medium)]).width + 14
        var ly = r.maxY + 6
        if ly + 16 > bounds.height { ly = r.maxY - 22 }
        label.string = text
        label.frame = CGRect(x: min(max(r.minX, 0), bounds.width - textW), y: ly, width: textW, height: 16)
        for l in [dim, border, label] { l.isHidden = false }
        CATransaction.commit()
    }

    private func hideSelection() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for l in [dim, border, label] { l.isHidden = true }
        CATransaction.commit()
    }
}

private final class SelectionController {
    private var panels: [(panel: SelectionPanel, view: SelectionView)] = []
    var onSelect: ((CGImage, Bool) -> Void)?
    var onCancel: (() -> Void)?
    private var finished = false
    private let invisible: Bool

    /// `invisible` is for tests: the panels exist but show nothing and take no mouse events or key focus.
    init(frames: [ScreenFreezer.Frame], invisible: Bool = false) {
        self.invisible = invisible
        for f in frames {
            let panel = SelectionPanel(contentRect: f.screen.frame, styleMask: [.borderless, .nonactivatingPanel],
                                       backing: .buffered, defer: false)
            panel.setFrame(f.screen.frame, display: false)
            panel.level = .screenSaver
            panel.isOpaque = true
            panel.backgroundColor = .black
            panel.hasShadow = false
            panel.animationBehavior = .none  // it must appear at once, not fade in
            panel.isReleasedWhenClosed = false
            panel.hidesOnDeactivate = false
            panel.acceptsMouseMovedEvents = true
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
            let view = SelectionView(frame: NSRect(origin: .zero, size: f.screen.frame.size), image: f.image,
                                     scale: f.screen.backingScaleFactor)
            view.onSelect = { [weak self] image, right in self?.finish((image, right)) }
            panel.onEscape = { [weak self] in self?.finish(nil) }
            panel.contentView = view
            if invisible {
                panel.alphaValue = 0
                panel.ignoresMouseEvents = true
            }
            panels.append((panel, view))
        }
    }

    var testView: SelectionView? { panels.first?.view }
    func testEscape() { panels.first?.panel.onEscape?() }

    func show() {
        for p in panels { p.panel.orderFrontRegardless() }
        guard !invisible else { return }
        let mouse = NSEvent.mouseLocation
        (panels.first { NSMouseInRect(mouse, $0.panel.frame, false) } ?? panels.first)?.panel.makeKey()
        NSCursor.crosshair.set()
    }

    private func finish(_ result: (CGImage, Bool)?) {
        guard !finished else { return }
        finished = true
        for p in panels {
            p.panel.orderOut(nil)
            p.panel.close()
        }
        panels = []
        if let result { onSelect?(result.0, result.1) } else { onCancel?() }
    }
}

// MARK: - Region helpers

private func rectBetween(_ a: CGPoint, _ b: CGPoint) -> CGRect {
    CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
}

/// `screencapture -R` takes points with the origin at the top-left of the primary display;
/// AppKit screen coordinates have it at the bottom-left.
func regionArgument(for cocoaRect: CGRect) -> String {
    let primaryHeight = NSScreen.screens.first?.frame.height ?? cocoaRect.maxY
    let x = Int(cocoaRect.minX.rounded(.down))
    let y = Int((primaryHeight - cocoaRect.maxY).rounded(.down))
    let w = Int(cocoaRect.width.rounded(.up))
    let h = Int(cocoaRect.height.rounded(.up))
    return "\(x),\(y),\(w),\(h)"
}

/// Runs `screencapture -R region` and hands back the PNG without touching the clipboard. screencapture
/// cannot write to a pipe (`/dev/stdout` is refused), so the picture takes a detour through a file in the
/// per-user private temp directory, which is read and deleted again right away. `completion` runs on the main queue.
private func captureRegionToMemory(_ region: String,
                                   completion: @escaping (_ png: Data?, _ stderr: String, _ status: Int32) -> Void) {
    let path = (NSTemporaryDirectory() as NSString).appendingPathComponent("snipbar-\(UUID().uuidString).png")
    let task = Process()
    task.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
    task.arguments = ["-R", region, "-t", "png", path]
    let errPipe = Pipe()
    task.standardError = errPipe
    task.terminationHandler = { finished in
        let status = finished.terminationStatus
        let errText = (String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let data = FileManager.default.contents(atPath: path)
        try? FileManager.default.removeItem(atPath: path)
        DispatchQueue.main.async {
            completion(data.flatMap { $0.starts(with: [0x89, 0x50, 0x4E, 0x47]) ? $0 : nil }, errText, status)
        }
    }
    do {
        try task.run()
    } catch {
        completion(nil, error.localizedDescription, -1)
    }
}

/// A click-through red rectangle that follows a right-button drag. It sits above everything,
/// including the system's selection overlay, and is hidden again before anything is captured.
private final class RubberBand {
    private let window: NSWindow
    init() {
        window = NSWindow(contentRect: .zero, styleMask: .borderless, backing: .buffered, defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.isReleasedWhenClosed = false
        window.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.maximumWindow)))
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        window.contentView = BandView()
    }
    func show(_ rect: CGRect) {
        window.setFrame(rect, display: true)
        window.orderFrontRegardless()
    }
    func hide() { window.orderOut(nil) }
}

private final class BandView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        NSColor.systemRed.withAlphaComponent(0.12).setFill()
        bounds.fill()
        NSColor.systemRed.setStroke()
        let path = NSBezierPath(rect: bounds.insetBy(dx: 1, dy: 1))
        path.lineWidth = 2
        path.stroke()
    }
}

// MARK: - Rendering (no UI dependencies)

// RENDER-BEGIN
struct AnnotShape {
    enum Kind { case outline, box, pen, text }
    var kind: Kind
    var rect: CGRect = .zero       // outline / box; text: origin = bottom-left of the line box
    var points: [CGPoint] = []     // pen
    var text: String = ""          // text
}

let textFontSize: CGFloat = 18  // view points

func textFont(size: CGFloat) -> CTFont {
    NSFont.systemFont(ofSize: size, weight: .semibold) as CTFont
}

/// Height of a one-line text box in view points. Shared by the editing field and the renderer
/// so both place the baseline identically: baseline = box bottom + font descent.
func textLineHeight() -> CGFloat {
    let f = textFont(size: textFontSize)
    return ceil(CTFontGetAscent(f) + CTFontGetDescent(f) + CTFontGetLeading(f))
}

/// Smooth pen path: quadratic curves through the midpoints of consecutive points.
func penPath(_ pts: [CGPoint], sx: CGFloat, sy: CGFloat) -> CGPath {
    let path = CGMutablePath()
    let q = pts.map { CGPoint(x: $0.x * sx, y: $0.y * sy) }
    guard let first = q.first else { return path }
    path.move(to: first)
    if q.count < 3 {
        path.addLine(to: q.last!)  // a single point becomes a dot thanks to the round cap
        return path
    }
    for i in 1..<(q.count - 1) {
        let mid = CGPoint(x: (q[i].x + q[i + 1].x) / 2, y: (q[i].y + q[i + 1].y) / 2)
        path.addQuadCurve(to: mid, control: q[i])
    }
    path.addLine(to: q.last!)
    return path
}

/// Draws shapes (view points, bottom-left origin) into `ctx`, scaled by sx/sy.
func drawShapes(_ shapes: [AnnotShape], in ctx: CGContext, sx: CGFloat, sy: CGFloat,
                lineWidthPoints: CGFloat, color: CGColor) {
    ctx.saveGState()
    ctx.setStrokeColor(color)
    ctx.setLineWidth(lineWidthPoints * sx)
    ctx.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 1))
    for sh in shapes {
        switch sh.kind {
        case .box:
            ctx.fill(CGRect(x: sh.rect.minX * sx, y: sh.rect.minY * sy,
                            width: sh.rect.width * sx, height: sh.rect.height * sy))
        case .outline:
            ctx.setLineJoin(.miter)
            ctx.stroke(CGRect(x: sh.rect.minX * sx, y: sh.rect.minY * sy,
                              width: sh.rect.width * sx, height: sh.rect.height * sy))
        case .pen:
            ctx.setLineCap(.round)
            ctx.setLineJoin(.round)
            ctx.addPath(penPath(sh.points, sx: sx, sy: sy))
            ctx.strokePath()
        case .text:
            let font = textFont(size: textFontSize * sx)
            let attrs: [NSAttributedString.Key: Any] = [
                NSAttributedString.Key(kCTFontAttributeName as String): font,
                NSAttributedString.Key(kCTForegroundColorAttributeName as String): color,
            ]
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: sh.text, attributes: attrs))
            ctx.textMatrix = .identity
            ctx.textPosition = CGPoint(x: sh.rect.minX * sx, y: sh.rect.minY * sy + CTFontGetDescent(font))
            CTLineDraw(line, ctx)
        }
    }
    ctx.restoreGState()
}

/// Draws `shapes` (in view points, bottom-left origin, inside a view of `viewSize`) on top of
/// `base`, at the base image's full pixel resolution.
func renderAnnotated(base: CGImage, shapes: [AnnotShape], viewSize: CGSize,
                     lineWidthPoints: CGFloat, color: CGColor) -> CGImage? {
    let w = base.width, h = base.height
    let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!
    let info = CGImageAlphaInfo.premultipliedLast.rawValue
    guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                              space: base.colorSpace ?? sRGB, bitmapInfo: info)
            ?? CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                         space: sRGB, bitmapInfo: info) else { return nil }
    ctx.draw(base, in: CGRect(x: 0, y: 0, width: w, height: h))
    drawShapes(shapes, in: ctx, sx: CGFloat(w) / viewSize.width, sy: CGFloat(h) / viewSize.height,
               lineWidthPoints: lineWidthPoints, color: color)
    return ctx.makeImage()
}
// RENDER-END

// MARK: - Editor

/// If another app keeps a full-width floating strip hanging from the top of `screen` (a clipboard or
/// screenshot shelf, say), returns the AppKit y of its lowest bottom edge, so the editor can open below it.
/// Hidden windows count too: such a strip is ordered out until something hangs on it, but its frame stays.
private func topStripBottomEdge(on screen: NSScreen) -> CGFloat? {
    guard let list = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] else { return nil }
    let primaryHeight = NSScreen.screens.first?.frame.height ?? screen.frame.maxY
    let f = screen.frame
    let cgTop = primaryHeight - f.maxY  // the screen's top edge in CG coordinates (y grows downwards)
    let me = Int(ProcessInfo.processInfo.processIdentifier)
    let floating = Int(CGWindowLevelForKey(.floatingWindow))
    var lowest: CGFloat?
    for w in list {
        guard (w[kCGWindowOwnerPID as String] as? Int) != me,
              (w[kCGWindowLayer as String] as? Int) == floating,
              (w[kCGWindowAlpha as String] as? Double ?? 1) > 0,
              let dict = w[kCGWindowBounds as String] as? NSDictionary,
              let b = CGRect(dictionaryRepresentation: dict as CFDictionary) else { continue }
        let nearTop = b.minY - cgTop >= 0 && b.minY - cgTop <= f.height * 0.25
        let wide = b.width >= f.width * 0.9 && abs(b.minX - f.minX) <= f.width * 0.1
        let stripLike = b.height >= 30 && b.height <= f.height * 0.5
        guard nearTop, wide, stripLike else { continue }
        let bottom = primaryHeight - b.maxY  // back to AppKit coordinates
        lowest = min(lowest ?? bottom, bottom)
    }
    return lowest
}

private let editorLineWidth: CGFloat = 3
private let editorRed = NSColor.systemRed

private enum Tool: Int { case rect = 0, pen, box, text }

private final class EditorPanel: NSPanel {
    var onKey: ((NSEvent) -> Bool)?
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override func keyDown(with event: NSEvent) {
        if onKey?(event) != true { super.keyDown(with: event) }
    }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if onKey?(event) == true { return true }
        return super.performKeyEquivalent(with: event)
    }
}

/// Offset from the editing field's frame origin to the text box origin, so that the committed
/// text (drawn by drawShapes) lands exactly where the field showed it.
private let fieldTextOffset = CGPoint(x: 2, y: 2)  // measured: NSTextField cell insets x by 2pt and sits 2pt higher than the CoreText box

private final class CanvasView: NSView, NSTextFieldDelegate {
    let image: NSImage
    var tool: Tool = .rect {
        didSet { window?.invalidateCursorRects(for: self) }
    }
    private var field: NSTextField?
    private var fieldOrigin = CGPoint.zero
    var isEditingText: Bool { field != nil }
    var shapes: [AnnotShape] = [] { didSet { onChange?() } }
    var onChange: (() -> Void)?
    private var current: AnnotShape?
    private var dragStart = CGPoint.zero

    init(image: NSImage, size: NSSize) {
        self.image = image
        super.init(frame: NSRect(origin: .zero, size: size))
    }
    required init?(coder: NSCoder) { fatalError() }

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    // Dragging on the image must draw, never move the window.
    override var mouseDownCanMoveWindow: Bool { false }
    override func resetCursorRects() { addCursorRect(bounds, cursor: tool == .text ? .iBeam : .crosshair) }

    /// Strokes are kept half a line width inside the image so they are never clipped at the edge.
    private func clamp(_ p: CGPoint, inset: Bool) -> CGPoint {
        let d = inset ? editorLineWidth / 2 : 0
        return CGPoint(x: min(max(p.x, d), bounds.width - d), y: min(max(p.y, d), bounds.height - d))
    }
    private func point(_ event: NSEvent, kind: AnnotShape.Kind) -> CGPoint {
        clamp(convert(event.locationInWindow, from: nil), inset: kind != .box)
    }
    private func rect(_ a: CGPoint, _ b: CGPoint) -> CGRect {
        CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
    }

    // MARK: Text editing

    private func beginText(at click: CGPoint) {
        let h = textLineHeight()
        let origin = CGPoint(x: min(max(click.x, 0), max(bounds.width - 24, 0)),
                             y: min(max(click.y - h / 2, 0), max(bounds.height - h, 0)))
        let f = NSTextField(frame: NSRect(x: origin.x, y: origin.y, width: max(bounds.width - origin.x, 24), height: h))
        f.isBordered = false
        f.drawsBackground = false
        f.focusRingType = .none
        f.font = NSFont.systemFont(ofSize: textFontSize, weight: .semibold)
        f.textColor = editorRed
        f.usesSingleLineMode = true
        f.cell?.wraps = false
        f.cell?.isScrollable = true
        f.delegate = self
        addSubview(f)
        field = f
        fieldOrigin = origin
        window?.makeFirstResponder(f)
        (window?.fieldEditor(true, for: f) as? NSTextView)?.allowsUndo = true
    }

    /// Turns the field's text into a shape (empty text is discarded) and returns focus to the canvas.
    func commitText() {
        guard let f = field else { return }
        field = nil  // first: ending the edit below re-enters through controlTextDidEndEditing
        let text = f.stringValue
        window?.makeFirstResponder(self)
        f.removeFromSuperview()
        if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            shapes.append(AnnotShape(kind: .text,
                                     rect: CGRect(x: fieldOrigin.x + fieldTextOffset.x, y: fieldOrigin.y + fieldTextOffset.y,
                                                  width: f.bounds.width, height: f.bounds.height),
                                     text: text))
        }
        needsDisplay = true
    }

    func cancelText() {
        guard let f = field else { return }
        field = nil
        window?.makeFirstResponder(self)
        f.removeFromSuperview()
        needsDisplay = true
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy sel: Selector) -> Bool {
        if sel == #selector(NSResponder.insertNewline(_:)) {
            commitText()  // Enter commits the text only; it does not copy or close
            return true
        }
        if sel == #selector(NSResponder.cancelOperation(_:)) || sel == #selector(NSTextView.complete(_:)) {
            cancelText()  // Esc cancels only this text
            return true
        }
        return false
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        commitText()  // focus left the field some other way: keep what was typed
    }

    // MARK: Mouse

    override func mouseDown(with event: NSEvent) {
        commitText()  // clicking elsewhere on the image commits an open text first
        if tool == .text && !event.modifierFlags.contains(.shift) {
            beginText(at: clamp(convert(event.locationInWindow, from: nil), inset: false))
            return
        }
        let kind: AnnotShape.Kind = event.modifierFlags.contains(.shift) ? .box
            : (tool == .rect ? .outline : tool == .pen ? .pen : .box)
        dragStart = point(event, kind: kind)
        current = AnnotShape(kind: kind, rect: CGRect(origin: dragStart, size: .zero),
                             points: kind == .pen ? [dragStart] : [])
        needsDisplay = true
    }
    override func mouseDragged(with event: NSEvent) {
        guard var cur = current else { return }
        let p = point(event, kind: cur.kind)
        if cur.kind == .pen {
            if let last = cur.points.last, hypot(p.x - last.x, p.y - last.y) < 0.5 { return }
            cur.points.append(p)
        } else {
            cur.rect = rect(dragStart, p)
        }
        current = cur
        needsDisplay = true
    }
    override func mouseUp(with event: NSEvent) {
        defer { current = nil; needsDisplay = true }
        guard var sh = current else { return }
        let p = point(event, kind: sh.kind)
        if sh.kind == .pen {
            if let last = sh.points.last, last != p { sh.points.append(p) }
            shapes.append(sh)  // a plain click leaves a dot
        } else {
            sh.rect = rect(dragStart, p)
            guard sh.rect.width >= 3, sh.rect.height >= 3 else { return }  // ignore plain clicks
            shapes.append(sh)
        }
    }

    func undo() {
        guard current == nil, !shapes.isEmpty else { return }
        shapes.removeLast()
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        image.draw(in: bounds)
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        var all = shapes
        if let c = current { all.append(c) }
        drawShapes(all, in: ctx, sx: 1, sy: 1, lineWidthPoints: editorLineWidth, color: editorRed.cgColor)
    }
}

/// The editor stays open until the user finishes it. Nothing is copied while editing: Enter / Bitti copies
/// the result once and closes, Esc / the close button closes without copying. (A clipboard history then
/// gets one entry, not one per annotation.) Losing focus or clicking elsewhere never closes it.
private final class EditorController: NSObject, NSWindowDelegate {
    private let cgImage: CGImage
    private let originalPNG: Data?
    private let clipboardHasImage: Bool  // the plain capture is already on the clipboard (left-button flow)
    private var panel: EditorPanel?
    private var canvas: CanvasView?
    private var toolButtons: [NSButton] = []
    private var undoButton: NSButton?
    private var closed = false
    var onClosed: (() -> Void)?

    init(image: CGImage, originalPNG: Data?, clipboardHasImage: Bool) {
        self.cgImage = image
        self.originalPNG = originalPNG
        self.clipboardHasImage = clipboardHasImage
        super.init()
    }

    #if SNIPBAR_TEST
    var testCanvas: CanvasView? { canvas }
    var testFrame: NSRect? { panel?.frame }
    func testFinish() { finish() }
    #endif

    private func makeButton(title: String, symbol: String, tip: String, action: Selector) -> NSButton {
        let b = NSButton(title: title, target: self, action: action)
        b.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
        b.imagePosition = .imageLeading
        b.bezelStyle = .texturedRounded
        b.focusRingType = .none
        b.toolTip = tip
        return b
    }

    func show() {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        guard let screen else { return }
        let visible = screen.visibleFrame
        let toolbarH: CGFloat = 30, pad: CGFloat = 10, minInnerW: CGFloat = 570
        let styleMask: NSWindow.StyleMask = [.titled, .closable, .nonactivatingPanel]
        // The real title bar height (it is not a fixed 28 pt on every macOS version).
        let titleBarH = NSPanel.frameRect(forContentRect: NSRect(x: 0, y: 0, width: 100, height: 100), styleMask: styleMask).height - 100
        let scale = screen.backingScaleFactor
        var size = NSSize(width: CGFloat(cgImage.width) / scale, height: CGFloat(cgImage.height) / scale)
        let chrome = toolbarH + 3 * pad + titleBarH
        // With a strip hanging from the top of the screen, open right below it (not in the middle)
        // and fit the image into the room that is left.
        let stripBottom = topStripBottomEdge(on: screen)
        let topLimit = stripBottom.map { max(min(visible.maxY, $0 - 8), visible.minY + 220) } ?? visible.maxY
        let maxWinH = stripBottom == nil ? visible.height * 0.8 : topLimit - visible.minY - 12
        let fit = min(1, (visible.width * 0.8 - 2 * pad) / size.width, (maxWinH - chrome) / size.height)
        size = NSSize(width: (size.width * fit).rounded(), height: (size.height * fit).rounded())

        let winW = max(size.width, minInnerW) + 2 * pad
        let winH = size.height + toolbarH + 3 * pad
        let frame = stripBottom == nil
            ? NSRect(x: visible.midX - winW / 2, y: visible.midY - (winH + titleBarH) / 2, width: winW, height: winH)
            : NSRect(x: visible.midX - winW / 2, y: topLimit - titleBarH - winH, width: winW, height: winH)

        // Non-activating: the panel takes keyboard input without SnipBar having to become the
        // active app, so the app the user was in stays active for the following Cmd+V.
        let panel = EditorPanel(contentRect: frame, styleMask: styleMask, backing: .buffered, defer: false)
        panel.title = "SnipBar — Enter: panoya kopyala · Esc: vazgeç"
        panel.level = .floating
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = false
        panel.isMovableByWindowBackground = false  // move by the title bar only; the image is for drawing
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.delegate = self

        let content = NSView(frame: NSRect(origin: .zero, size: frame.size))
        panel.contentView = content

        let canvas = CanvasView(image: NSImage(cgImage: cgImage, size: size), size: size)
        canvas.frame.origin = NSPoint(x: ((winW - size.width) / 2).rounded(), y: pad)
        content.addSubview(canvas)

        // Toolbar row above the image.
        let ty = pad + size.height + pad
        let gap: CGFloat = 6
        var x = pad
        let tools: [(String, String, String, String)] = [
            ("Kare", "rectangle", "Kare: kırmızı çerçeve çiz", "kare"),
            ("Kalem", "scribble", "Kalem: serbest çizim", "kalem"),
            ("Kapat", "rectangle.fill", "Kapat: siyah kutuyla gizle (⇧+sürükle ile de olur)", "kapat"),
            ("Yazı", "textformat", "Yazı: görüntüye tıklayıp yazın (Enter: ekle, Esc: vazgeç)", "yazi"),
        ]
        for (i, t) in tools.enumerated() {
            let b = makeButton(title: t.0, symbol: t.1, tip: t.2, action: #selector(toolPicked(_:)))
            b.tag = i
            b.setButtonType(.pushOnPushOff)
            b.frame = NSRect(x: x, y: ty, width: 80, height: toolbarH)
            content.addSubview(b)
            toolButtons.append(b)
            x += 80 + gap
        }
        x += gap
        let undo = makeButton(title: "Geri al", symbol: "arrow.uturn.backward", tip: "Geri al (⌘Z)",
                              action: #selector(undoPressed))
        undo.frame = NSRect(x: x, y: ty, width: 92, height: toolbarH)
        content.addSubview(undo)
        undoButton = undo

        let done = makeButton(title: "Bitti", symbol: "checkmark",
                              tip: "Panoya kopyala ve kapat (Enter). Vazgeçmek için Esc ya da sol üstteki çarpı.",
                              action: #selector(donePressed))
        done.bezelStyle = .rounded
        done.bezelColor = .controlAccentColor
        done.contentTintColor = .white
        done.frame = NSRect(x: winW - pad - 110, y: ty, width: 110, height: toolbarH)
        content.addSubview(done)

        canvas.onChange = { [weak self] in self?.refreshUndo() }
        panel.onKey = { [weak self] event in self?.handleKey(event) ?? false }
        self.panel = panel
        self.canvas = canvas
        select(.rect)
        refreshUndo()

        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(canvas)
        NSLog("SnipBar editor: opened image=%dx%d window=%.0fx%.0f below-strip=%d top=%.0f key=%d",
              cgImage.width, cgImage.height, winW, winH, stripBottom == nil ? 0 : 1,
              frame.maxY + titleBarH, panel.isKeyWindow ? 1 : 0)
    }

    private func select(_ tool: Tool) {
        canvas?.commitText()
        canvas?.tool = tool
        for (i, b) in toolButtons.enumerated() {
            let on = i == tool.rawValue
            b.state = on ? .on : .off
            b.bezelColor = on ? .controlAccentColor : nil
            b.contentTintColor = on ? .white : nil
        }
        panel?.makeFirstResponder(canvas)
    }
    private func refreshUndo() { undoButton?.isEnabled = !(canvas?.shapes.isEmpty ?? true) }

    @objc private func toolPicked(_ sender: NSButton) { select(Tool(rawValue: sender.tag) ?? .rect) }
    @objc private func undoPressed() {
        if canvas?.isEditingText == true { canvas?.cancelText() } else { canvas?.undo() }
        panel?.makeFirstResponder(canvas)
    }
    @objc private func donePressed() { finish() }

    /// While a text field is being edited the field editor owns the keyboard: Enter / Esc are handled
    /// by the canvas (field delegate), and the edit shortcuts are forwarded to the field editor
    /// (an accessory app has no Edit menu, so nothing else would deliver them).
    private func handleTextEditingKey(_ event: NSEvent) -> Bool {
        guard event.type == .keyDown, let tv = panel?.firstResponder as? NSTextView else { return false }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let key = event.charactersIgnoringModifiers?.lowercased()
        if flags == .command {
            switch key {
            case "z": tv.undoManager?.undo(); return true
            case "x": tv.cut(nil); return true
            case "c": tv.copy(nil); return true
            case "v": tv.paste(nil); return true
            case "a": tv.selectAll(nil); return true
            default: break
            }
        } else if flags == [.command, .shift], key == "z" {
            tv.undoManager?.redo()
            return true
        }
        return false  // everything else (including Enter / Esc) goes the normal responder route
    }

    private func handleKey(_ event: NSEvent) -> Bool {
        guard event.type == .keyDown else { return false }
        if canvas?.isEditingText == true { return handleTextEditingKey(event) }
        switch event.keyCode {
        case 36, 76:  // return, keypad enter
            finish()
            return true
        case 53:  // escape
            close(reason: "escape")
            return true
        default:
            if event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
               event.charactersIgnoringModifiers?.lowercased() == "z" {
                canvas?.undo()
                return true
            }
            return false
        }
    }

    /// The red close button behaves exactly like Escape.
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        close(reason: "close button")
        return false
    }

    /// Enter / Bitti: copy the result once, then close. With nothing drawn and the capture already on
    /// the clipboard there is nothing to write.
    private func finish() {
        guard let canvas else { return }
        canvas.commitText()  // a text still being typed counts
        if canvas.shapes.isEmpty && clipboardHasImage {
            close(reason: "done, nothing drawn")
            return
        }
        let started = Date()
        let png: Data
        let tiff: Data?
        if canvas.shapes.isEmpty, let original = originalPNG {
            png = original  // untouched capture: keep its exact bytes
            tiff = NSBitmapImageRep(cgImage: cgImage).tiffRepresentation
        } else {
            guard let out = renderAnnotated(base: cgImage, shapes: canvas.shapes, viewSize: canvas.bounds.size,
                                            lineWidthPoints: editorLineWidth, color: editorRed.cgColor) else {
                NSLog("SnipBar editor: render failed, nothing copied")
                NSSound.beep()
                return
            }
            let rep = NSBitmapImageRep(cgImage: out)
            guard let encoded = rep.representation(using: .png, properties: [:]) else {
                NSLog("SnipBar editor: PNG encoding failed, nothing copied")
                NSSound.beep()
                return
            }
            png = encoded
            tiff = rep.tiffRepresentation
        }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setData(png, forType: .png)
        if let tiff { pb.setData(tiff, forType: .tiff) }
        NSLog("SnipBar editor: copied rects=%ld pens=%ld boxes=%ld texts=%ld bytes=%ld changeCount=%ld ms=%.0f",
              canvas.shapes.filter { $0.kind == .outline }.count, canvas.shapes.filter { $0.kind == .pen }.count,
              canvas.shapes.filter { $0.kind == .box }.count, canvas.shapes.filter { $0.kind == .text }.count,
              png.count, pb.changeCount, Date().timeIntervalSince(started) * 1000)
        close(reason: "done")
    }

    /// Closing never touches the clipboard; only `finish` writes it.
    func close(reason: String) {
        guard !closed else { return }
        closed = true
        NSLog("SnipBar editor: closed (%@)", reason)
        panel?.onKey = nil
        panel?.delegate = nil
        canvas?.onChange = nil
        panel?.orderOut(nil)
        panel?.close()
        panel = nil
        canvas = nil
        toolButtons = []
        undoButton = nil
        onClosed?()
        onClosed = nil
    }
}
