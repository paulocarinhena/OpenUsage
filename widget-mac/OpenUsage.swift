// Floating Claude / Codex / Cursor / OpenCode Go usage widget for macOS.
// Plain AppKit + SwiftUI, compiled on the user's Mac by build.sh: nothing to download.
// Data comes from ../scripts/usage-json.ts, run with Node (>= 22.6).

import AppKit
import Combine
import SwiftUI

let refreshMinutes = 5.0
let bundleId = "com.openusage.widget"
let showNotification = Notification.Name("com.openusage.widget.show")
let icons = ["claude": "\u{273B}", "codex": "\u{25CE}", "cursor": "\u{2B21}", "opencode-go": "\u{25A3}"]

// ---- data ----------------------------------------------------------------------

struct UsageWindow: Codable {
  var label: String
  var usedPct: Double
  var resetsAt: Double?
}

struct UsageExtra: Codable {
  var label: String
  var value: String
}

struct ProviderUsage: Codable {
  var id: String
  var name: String
  var windows: [UsageWindow]
  var extras: [UsageExtra]
  var plan: String?
  var account: String?
  var error: String?
  var fetchedAt: Double
}

struct Cache: Codable {
  var updatedAt: Double?
  var data: [ProviderUsage]
}

/** Files build.sh writes into the bundle: where the repo lives and which node to run. */
func resource(_ name: String) -> String? {
  guard let url = Bundle.main.url(forResource: name, withExtension: "txt"),
    let s = try? String(contentsOf: url, encoding: .utf8)
  else { return nil }
  let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
  return t.isEmpty ? nil : t
}

let stateDir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
  .appendingPathComponent("usage-widget")
let cacheURL = stateDir.appendingPathComponent("data.json")
let defaults = UserDefaults.standard

final class Model: ObservableObject {
  @Published var data: [ProviderUsage] = []
  @Published var updatedAt: Double?
  @Published var refreshing = false
  @Published var lastError = ""
  @Published var display = defaults.string(forKey: "display") ?? "used"

  private var proc: Process?

  init() {
    // The last good result is cached on disk, so a restart (or a rate-limited first fetch) still shows numbers.
    if let raw = try? Data(contentsOf: cacheURL), let cache = try? JSONDecoder().decode(Cache.self, from: raw) {
      data = cache.data
      updatedAt = cache.updatedAt
    }
  }

  func toggleDisplay() {
    display = display == "used" ? "remaining" : "used"
    defaults.set(display, forKey: "display")
  }

  func refresh() {
    guard proc == nil, let root = resource("root") else {
      if resource("root") == nil { lastError = "run build.sh again" }
      return
    }
    let script = root + "/scripts/usage-json.ts"
    let p = Process()
    // Apps started from Finder do not get the shell's PATH, so prefer the node build.sh found.
    if let node = resource("node"), FileManager.default.isExecutableFile(atPath: node) {
      p.executableURL = URL(fileURLWithPath: node)
      p.arguments = ["--experimental-strip-types", "--no-warnings", script]
    } else {
      p.executableURL = URL(fileURLWithPath: "/bin/zsh")
      p.arguments = ["-lc", "exec node --experimental-strip-types --no-warnings \"$0\"", script]
    }
    p.currentDirectoryURL = URL(fileURLWithPath: root)
    let out = Pipe()
    p.standardOutput = out
    p.standardError = FileHandle.nullDevice
    do {
      try p.run()
    } catch {
      lastError = "node not found"
      return
    }
    proc = p
    refreshing = true
    let timeout = DispatchWorkItem { if p.isRunning { p.terminate() } }
    DispatchQueue.global().asyncAfter(deadline: .now() + 60, execute: timeout)
    // Read on a background thread so a full pipe never blocks the child.
    DispatchQueue.global().async {
      let raw = out.fileHandleForReading.readDataToEndOfFile()
      p.waitUntilExit()
      timeout.cancel()
      DispatchQueue.main.async { self.complete(raw, timedOut: p.terminationReason == .uncaughtSignal) }
    }
  }

  private func complete(_ raw: Data, timedOut: Bool) {
    proc = nil
    refreshing = false
    guard let fresh = try? JSONDecoder().decode([ProviderUsage].self, from: raw) else {
      lastError = timedOut ? "timed out" : "refresh failed"
      return
    }
    // A transient provider failure keeps the last good numbers, flagged as stale.
    let prev = Dictionary(data.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
    data = fresh.map { u in
      if let err = u.error, var old = prev[u.id], !old.windows.isEmpty {
        old.error = err
        return old
      }
      return u
    }
    updatedAt = Date().timeIntervalSince1970 * 1000
    lastError = ""
    try? FileManager.default.createDirectory(at: stateDir, withIntermediateDirectories: true)
    if let json = try? JSONEncoder().encode(Cache(updatedAt: updatedAt, data: data)) {
      try? json.write(to: cacheURL)
    }
  }

  var trayText: String {
    let parts = data.compactMap { u -> String? in
      guard let m = u.windows.map(\.usedPct).max() else { return nil }
      return "\(u.name) \(Int(m.rounded()))%"
    }
    return parts.isEmpty ? "OpenUsage" : "OpenUsage - " + parts.joined(separator: " | ")
  }
}

// ---- theme (follows macOS light/dark) ------------------------------------------

extension NSColor {
  convenience init(hex: UInt32) {
    self.init(
      srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
      blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
  }
}

func themed(_ light: UInt32, _ dark: UInt32) -> Color {
  Color(
    nsColor: NSColor(name: nil) { ap in
      NSColor(hex: ap.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light)
    })
}

enum C {
  static let bg = themed(0xFBFAF8, 0x1C1A19)
  static let border = themed(0xE2DDD7, 0x34302D)
  static let divider = themed(0xECE8E3, 0x2C2926)
  static let text = themed(0x1F1C1A, 0xEBE7E2)
  static let muted = themed(0x857D76, 0x8D8680)
  static let warn = themed(0xC46D12, 0xE8953F)
  static let error = themed(0xC9362D, 0xE5584F)
  static let track = themed(0xE4DED7, 0x35302C)
  static let hover = themed(0xF1EDE8, 0x2A2725)
  static let card = themed(0xF3F0EB, 0x242120)
  static let cardBorder = themed(0xE8E3DD, 0x2E2A27)
}

func level(_ pct: Double) -> Color? { pct >= 80 ? C.error : pct >= 50 ? C.warn : nil }

// ---- formatting ------------------------------------------------------------------

func formatReset(_ ms: Double?) -> String {
  guard let ms = ms else { return "" }
  let d = Date(timeIntervalSince1970: ms / 1000)
  let time = DateFormatter.localizedString(from: d, dateStyle: .none, timeStyle: .short)
  if Calendar.current.isDateInToday(d) { return time }
  let f = DateFormatter()
  f.setLocalizedDateFormatFromTemplate("EEEddMMM")
  return f.string(from: d) + ", " + time
}

func formatAgo(_ ms: Double?) -> String {
  guard let ms = ms else { return "" }
  let m = Int(((Date().timeIntervalSince1970 * 1000 - ms) / 60000).rounded())
  if m < 1 { return "updated just now" }
  if m < 60 { return "updated \(m) min ago" }
  return "updated \(Int((Double(m) / 60).rounded())) h ago"
}

// ---- views -----------------------------------------------------------------------

/// View-local state without `@State`: in recent SDKs `@State` is a macro whose plugin only ships with
/// full Xcode, so it does not compile with the Command Line Tools alone.
final class LocalState<Value>: ObservableObject {
  @Published var value: Value
  init(_ value: Value) { self.value = value }
}

struct HeaderButton: View {
  let title: String
  let help: String
  let action: () -> Void
  @StateObject private var hover = LocalState(false)

  var body: some View {
    Button(action: action) {
      Text(title)
        .font(.system(size: 12))
        .foregroundColor(hover.value ? C.text : C.muted)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(RoundedRectangle(cornerRadius: 5).fill(hover.value ? C.hover : Color.clear))
        .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .help(help)
    .onHover { hover.value = $0 }
  }
}

struct Bar: View {
  let pct: Double
  let color: Color

  var body: some View {
    GeometryReader { g in
      ZStack(alignment: .leading) {
        Capsule().fill(C.track)
        Capsule().fill(color).frame(width: g.size.width * CGFloat(max(0, min(100, pct))) / 100)
      }
    }
    .frame(height: 4)
  }
}

struct Card: View {
  let u: ProviderUsage
  let display: String

  var body: some View {
    let hasData = !u.windows.isEmpty || !u.extras.isEmpty
    VStack(alignment: .leading, spacing: 0) {
      HStack {
        (Text("\(icons[u.id] ?? "")  ").foregroundColor(C.muted) + Text(u.name))
          .font(.system(size: 13.5, weight: .semibold))
        Spacer()
        if let plan = u.plan {
          Text(plan.uppercased())
            .font(.system(size: 10, weight: .semibold))
            .foregroundColor(C.muted)
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(RoundedRectangle(cornerRadius: 4).fill(C.track))
        }
      }
      if let account = u.account {
        Text(account).font(.system(size: 11.5)).foregroundColor(C.muted).lineLimit(1).truncationMode(.tail)
          .help(account).padding(.top, 1)
      }
      if let err = u.error {
        Text(hasData ? "stale - \(err)" : err)
          .font(.system(size: 12))
          .foregroundColor(hasData ? C.warn : C.muted)
          .fixedSize(horizontal: false, vertical: true)
          .padding(.top, 6)
      }
      ForEach(Array(u.windows.enumerated()), id: \.offset) { i, w in
        let pct = display == "used" ? w.usedPct : 100 - w.usedPct
        let lv = level(w.usedPct)
        HStack {
          let reset = formatReset(w.resetsAt)
          (Text(w.label) + Text(reset.isEmpty ? "" : "  \(reset)").font(.system(size: 12)).foregroundColor(C.muted))
            .lineLimit(1).truncationMode(.tail)
          Spacer()
          Text("\(Int(pct.rounded()))%").font(.system(size: 13, weight: .semibold)).foregroundColor(lv ?? C.text)
        }
        .padding(.top, i == 0 ? 9 : 8)
        Bar(pct: w.usedPct, color: lv ?? C.muted).padding(.top, 5)
      }
      ForEach(Array(u.extras.enumerated()), id: \.offset) { i, x in
        HStack {
          Text(x.label).foregroundColor(C.muted)
          Spacer()
          Text(x.value)
        }
        .font(.system(size: 12.5))
        .padding(.top, u.windows.isEmpty && i == 0 ? 9 : 8)
      }
    }
    .padding(EdgeInsets(top: 9, leading: 11, bottom: 10, trailing: 11))
    .background(RoundedRectangle(cornerRadius: 8).fill(C.card))
    .overlay(RoundedRectangle(cornerRadius: 8).stroke(C.cardBorder, lineWidth: 1))
  }
}

struct WidgetView: View {
  @ObservedObject var m: Model
  let hide: () -> Void
  // Re-renders the "updated N min ago" label.
  @StateObject private var now = LocalState(Date())
  private let clock = Timer.publish(every: 30, on: .main, in: .common).autoconnect()

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      HStack(spacing: 2) {
        (Text("\u{25F7}").foregroundColor(C.muted) + Text(" OpenUsage")).font(.system(size: 13, weight: .semibold))
        Spacer()
        HeaderButton(title: m.display == "used" ? "Used" : "Left", help: "Used / left") { m.toggleDisplay() }
        HeaderButton(title: "\u{27F3}", help: "Refresh") { m.refresh() }
        HeaderButton(title: "\u{2715}", help: "Hide (menu bar icon brings it back)", action: hide)
      }
      .padding(.bottom, 8)
      .background(DragArea())
      Rectangle().fill(C.divider).frame(height: 1).padding(.bottom, 8)
      if m.data.isEmpty {
        Text(m.refreshing ? "Loading..." : "No data").foregroundColor(C.muted)
      }
      VStack(spacing: 8) {
        ForEach(m.data, id: \.id) { Card(u: $0, display: m.display) }
      }
      Rectangle().fill(C.divider).frame(height: 1).padding(.top, 10).padding(.bottom, 6)
      HStack {
        Text(m.refreshing ? "refreshing..." : formatAgo(m.updatedAt)).foregroundColor(C.muted)
        Spacer()
        Text(m.lastError).foregroundColor(C.error)
      }
      .font(.system(size: 11.5))
      .id(now.value)
    }
    .font(.system(size: 13))
    .foregroundColor(C.text)
    .padding(EdgeInsets(top: 10, leading: 14, bottom: 10, trailing: 14))
    .frame(width: 304)
    .fixedSize(horizontal: false, vertical: true)
    .background(RoundedRectangle(cornerRadius: 12).fill(C.bg))
    .overlay(RoundedRectangle(cornerRadius: 12).stroke(C.border, lineWidth: 1))
    .onReceive(clock) { now.value = $0 }
  }
}

// ---- window ----------------------------------------------------------------------

/** The header drags the window, like the Windows widget. */
struct DragArea: NSViewRepresentable {
  final class DragView: NSView {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) { window?.performDrag(with: event) }
  }
  func makeNSView(context: Context) -> NSView { DragView() }
  func updateNSView(_ nsView: NSView, context: Context) {}
}

/** Borderless panels refuse key status by default, which would leave the buttons dead. */
final class Panel: NSPanel {
  override var canBecomeKey: Bool { true }
}

final class HostingView<V: View>: NSHostingView<V> {
  override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

// ---- start at login --------------------------------------------------------------

let agentURL = FileManager.default.homeDirectoryForCurrentUser
  .appendingPathComponent("Library/LaunchAgents/\(bundleId).plist")

func setStartAtLogin(_ on: Bool) {
  if on {
    let plist: [String: Any] = [
      "Label": bundleId,
      "ProgramArguments": ["/usr/bin/open", "-a", Bundle.main.bundlePath],
      "RunAtLoad": true,
    ]
    try? FileManager.default.createDirectory(
      at: agentURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    (plist as NSDictionary).write(to: agentURL, atomically: true)
  } else {
    try? FileManager.default.removeItem(at: agentURL)
  }
}

// ---- app -------------------------------------------------------------------------

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
  let model = Model()
  var panel: Panel!
  var status: NSStatusItem!
  var topItem: NSMenuItem!
  var loginItem: NSMenuItem!
  var bag = Set<AnyCancellable>()

  func applicationDidFinishLaunching(_ note: Notification) {
    let host = HostingView(rootView: WidgetView(m: model, hide: { [weak self] in self?.toggleWindow() }))
    host.frame.size = host.fittingSize

    panel = Panel(
      contentRect: NSRect(origin: .zero, size: host.fittingSize),
      styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    panel.contentView = host
    panel.isOpaque = false
    panel.backgroundColor = .clear
    panel.hasShadow = true
    panel.hidesOnDeactivate = false
    panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    let topmost = defaults.object(forKey: "topmost") as? Bool ?? true
    panel.level = topmost ? .floating : .normal

    let area = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
    if let x = defaults.object(forKey: "x") as? Double, let top = defaults.object(forKey: "top") as? Double {
      panel.setFrameTopLeftPoint(NSPoint(x: x, y: top))
    } else {
      panel.setFrameTopLeftPoint(NSPoint(x: area.maxX - 330, y: area.maxY - 16))
    }
    NotificationCenter.default.addObserver(forName: NSWindow.didMoveNotification, object: panel, queue: .main) {
      [weak self] _ in
      guard let f = self?.panel.frame else { return }
      defaults.set(Double(f.minX), forKey: "x")
      defaults.set(Double(f.maxY), forKey: "top")
    }

    // Grow or shrink with the content, keeping the top edge where the user put it.
    model.objectWillChange.sink { [weak self] _ in
      DispatchQueue.main.async {
        guard let self else { return }
        let size = host.fittingSize
        let top = self.panel.frame.maxY
        self.panel.setFrame(
          NSRect(x: self.panel.frame.minX, y: top - size.height, width: size.width, height: size.height),
          display: true)
        self.status.button?.toolTip = self.model.trayText
      }
    }.store(in: &bag)

    setupStatusItem(topmost: topmost)

    // A second launch asks this instance to show itself.
    DistributedNotificationCenter.default().addObserver(forName: showNotification, object: nil, queue: .main) {
      [weak self] _ in self?.showWindow()
    }

    Timer.scheduledTimer(withTimeInterval: refreshMinutes * 60, repeats: true) { [weak self] _ in
      self?.model.refresh()
    }

    panel.orderFrontRegardless()
    model.refresh()
  }

  func setupStatusItem(topmost: Bool) {
    status = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    if let img = NSImage(systemSymbolName: "gauge", accessibilityDescription: "OpenUsage") {
      img.isTemplate = true
      status.button?.image = img
    } else {
      status.button?.title = "\u{25F7}"
    }
    status.button?.toolTip = model.trayText

    let menu = NSMenu()
    menu.delegate = self
    menu.addItem(withTitle: "Show / hide", action: #selector(toggleWindow), keyEquivalent: "").target = self
    menu.addItem(withTitle: "Refresh", action: #selector(refresh), keyEquivalent: "r").target = self
    menu.addItem(.separator())
    topItem = menu.addItem(withTitle: "Always on top", action: #selector(toggleTopmost), keyEquivalent: "")
    topItem.target = self
    topItem.state = topmost ? .on : .off
    loginItem = menu.addItem(withTitle: "Start at login", action: #selector(toggleLogin), keyEquivalent: "")
    loginItem.target = self
    menu.addItem(.separator())
    menu.addItem(withTitle: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
    status.menu = menu
  }

  func menuWillOpen(_ menu: NSMenu) {
    loginItem.state = FileManager.default.fileExists(atPath: agentURL.path) ? .on : .off
  }

  func showWindow() {
    panel.orderFrontRegardless()
  }

  @objc func toggleWindow() {
    if panel.isVisible { panel.orderOut(nil) } else { showWindow() }
  }

  @objc func refresh() { model.refresh() }

  @objc func toggleTopmost() {
    let on = panel.level != .floating
    panel.level = on ? .floating : .normal
    topItem.state = on ? .on : .off
    defaults.set(on, forKey: "topmost")
  }

  @objc func toggleLogin() {
    setStartAtLogin(!FileManager.default.fileExists(atPath: agentURL.path))
  }

  // `open -a OpenUsage` on a running copy lands here instead of starting a second one.
  func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
    showWindow()
    return false
  }
}

let others = NSRunningApplication.runningApplications(withBundleIdentifier: bundleId)
  .filter { $0 != NSRunningApplication.current }
if !others.isEmpty {
  DistributedNotificationCenter.default().postNotificationName(
    showNotification, object: nil, userInfo: nil, deliverImmediately: true)
  exit(0)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
