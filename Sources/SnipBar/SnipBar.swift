import AppKit
import Carbon.HIToolbox
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

@main
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private let menu = NSMenu()
    private var captureItem: NSMenuItem!
    private var loginItem: NSMenuItem!
    private var hotKeyRef: EventHotKeyRef?
    private var hotKeyRegistered = false
    private var capturing = false  // main-thread only
    private var permissionRequested = false
    private var editor: EditorController?

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
        statusItem.autosaveName = "SnipBarStatusItem"  // remembers a position chosen by Command-dragging
        if let button = statusItem.button {
            let image = NSImage(systemSymbolName: "scissors", accessibilityDescription: "SnipBar")
            image?.isTemplate = true
            button.image = image
            button.toolTip = "Sol tık veya ⌃⌥S: ekran alıntısı • Sağ tık: menü"
            button.target = self
            button.action = #selector(clicked(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            // Event-driven diagnostics: does macOS hide the icon when the menu bar overflows?
            NotificationCenter.default.addObserver(self, selector: #selector(statusItemOcclusionChanged),
                                                   name: NSWindow.didChangeOcclusionStateNotification,
                                                   object: button.window)
        }
        NSLog("SnipBar launched, screenRecordingPermission=%d", CGPreflightScreenCaptureAccess() ? 1 : 0)
        DispatchQueue.main.async { [weak self] in self?.logStatusItem() }  // once the window has settled

        // Test hook: open the editor on an image file without capturing, to check the window lifecycle.
        if let path = ProcessInfo.processInfo.environment["SNIPBAR_EDITOR_TEST_IMAGE"],
           let data = FileManager.default.contents(atPath: path),
           let cg = NSBitmapImageRep(data: data)?.cgImage {
            openEditor(image: cg)
        }
    }

    // MARK: Hotkey, menu, login item, diagnostics

    /// Control+Option+S via Carbon: needs no Accessibility / Input Monitoring permission.
    private func registerHotKey() {
        hotKeyAction = { [weak self] in self?.capture() }
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
        if hotKeyRegistered {
            NSLog("SnipBar hotkey ctrl+opt+S registered=1")
        } else {
            NSLog("SnipBar hotkey ctrl+opt+S registered=0 status=%d", Int32(status))
        }
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

    @objc private func clicked(_ sender: NSStatusBarButton) {
        guard let event = NSApp.currentEvent else { return }
        let isRight = event.type == .rightMouseUp
            || (event.type == .leftMouseUp && event.modifierFlags.contains(.control))
        if isRight {
            statusItem.menu = menu
            sender.performClick(nil)
            statusItem.menu = nil
        } else {
            capture()
        }
    }

    private func capture() {
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
        let pasteboard = NSPasteboard.general
        let countBefore = pasteboard.changeCount
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
        } catch {
            capturing = false
            NSLog("SnipBar could not start screencapture: %@", error.localizedDescription)
            showError("Ekran yakalama başlatılamadı: \(error.localizedDescription)", offerSettings: false)
        }
    }

    private func finished(status: Int32, stderr: String, countBefore: Int, started: Date) {
        capturing = false
        let pasteboard = NSPasteboard.general
        let countAfter = pasteboard.changeCount
        let hasImage = pasteboard.availableType(from: [.png, .tiff]) != nil
        let copied = countAfter != countBefore && hasImage
        NSLog("SnipBar capture done: exit=%d duration=%.2fs changeCount %ld->%ld image=%d stderr=\"%@\"",
              status, Date().timeIntervalSince(started), countBefore, countAfter, hasImage ? 1 : 0, stderr)

        if copied {
            showEditor()
            return
        }
        // Escape exits cleanly with no output; anything else is a real failure.
        if status != 0 || !stderr.isEmpty {
            let denied = !CGPreflightScreenCaptureAccess() || stderr.contains("could not create image")
            showError(denied
                ? "Görüntü alınamadı: SnipBar'ın Ekran Kaydı izni yok ya da geçersiz.\n\n\(stderr)"
                : "Görüntü panoya kopyalanamadı (çıkış kodu \(status)).\n\n\(stderr)",
                offerSettings: denied)
        }
    }

    private func showEditor() {
        let pb = NSPasteboard.general
        guard let data = pb.data(forType: .png) ?? pb.data(forType: .tiff),
              let cg = NSBitmapImageRep(data: data)?.cgImage else {
            NSLog("SnipBar editor: could not read image back from clipboard")
            return
        }
        openEditor(image: cg)
    }

    private func openEditor(image: CGImage) {
        editor?.close(reason: "replaced")
        let controller = EditorController(image: image)
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

/// The editor stays open until the user finishes it: Enter / Kopyala copies the annotated image,
/// Escape or the close button cancels. Losing focus or clicking elsewhere never closes it.
private final class EditorController: NSObject, NSWindowDelegate {
    private let cgImage: CGImage
    private var panel: EditorPanel?
    private var canvas: CanvasView?
    private var toolButtons: [NSButton] = []
    private var undoButton: NSButton?
    private var closed = false
    var onClosed: (() -> Void)?

    init(image: CGImage) {
        self.cgImage = image
        super.init()
    }

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
        let toolbarH: CGFloat = 30, pad: CGFloat = 10, minInnerW: CGFloat = 570, titleBarH: CGFloat = 28
        let scale = screen.backingScaleFactor
        var size = NSSize(width: CGFloat(cgImage.width) / scale, height: CGFloat(cgImage.height) / scale)
        let chrome = toolbarH + 3 * pad + titleBarH
        let fit = min(1, (visible.width * 0.8 - 2 * pad) / size.width, (visible.height * 0.8 - chrome) / size.height)
        size = NSSize(width: (size.width * fit).rounded(), height: (size.height * fit).rounded())

        let winW = max(size.width, minInnerW) + 2 * pad
        let winH = size.height + toolbarH + 3 * pad
        let frame = NSRect(x: visible.midX - winW / 2, y: visible.midY - (winH + titleBarH) / 2,
                           width: winW, height: winH)

        // Non-activating: the panel takes keyboard input without SnipBar having to become the
        // active app, so the app the user was in stays active for the following Cmd+V.
        let panel = EditorPanel(contentRect: frame, styleMask: [.titled, .closable, .nonactivatingPanel],
                                backing: .buffered, defer: false)
        panel.title = "SnipBar"
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

        let copy = makeButton(title: "Kopyala", symbol: "checkmark", tip: "Panoya kopyala ve kapat (Enter)",
                              action: #selector(copyPressed))
        copy.bezelStyle = .rounded
        copy.bezelColor = .controlAccentColor
        copy.contentTintColor = .white
        copy.frame = NSRect(x: winW - pad - 110, y: ty, width: 110, height: toolbarH)
        content.addSubview(copy)

        canvas.onChange = { [weak self] in self?.refreshUndo() }
        panel.onKey = { [weak self] event in self?.handleKey(event) ?? false }
        self.panel = panel
        self.canvas = canvas
        select(.rect)
        refreshUndo()

        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(canvas)
        NSLog("SnipBar editor: opened image=%dx%d window=%.0fx%.0f key=%d",
              cgImage.width, cgImage.height, winW, winH, panel.isKeyWindow ? 1 : 0)
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
    @objc private func copyPressed() { finish() }

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

    /// Enter / Kopyala: put the annotated image on the clipboard, then close.
    private func finish() {
        guard let canvas else { return }
        canvas.commitText()  // an open text field is committed first
        if canvas.shapes.isEmpty {
            // Nothing drawn: the plain capture is already on the clipboard.
            close(reason: "copy, no shapes")
            return
        }
        guard let out = renderAnnotated(base: cgImage, shapes: canvas.shapes, viewSize: canvas.bounds.size,
                                        lineWidthPoints: editorLineWidth, color: editorRed.cgColor) else {
            NSLog("SnipBar editor: render failed")
            NSSound.beep()
            return
        }
        let rep = NSBitmapImageRep(cgImage: out)
        let pb = NSPasteboard.general
        pb.clearContents()
        if let png = rep.representation(using: .png, properties: [:]) { pb.setData(png, forType: .png) }
        if let tiff = rep.tiffRepresentation { pb.setData(tiff, forType: .tiff) }
        NSLog("SnipBar editor: copied annotated image rects=%ld pens=%ld boxes=%ld texts=%ld size=%dx%d changeCount=%ld",
              canvas.shapes.filter { $0.kind == .outline }.count, canvas.shapes.filter { $0.kind == .pen }.count,
              canvas.shapes.filter { $0.kind == .box }.count, canvas.shapes.filter { $0.kind == .text }.count, out.width, out.height, pb.changeCount)
        close(reason: "copy")
    }

    /// Closing never touches the clipboard.
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
