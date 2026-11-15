//
//  MenuBarLayout.swift
//  DynamicIsland
//
//  Where the frontmost app's menus end, so a live activity can stay out of
//  their way.
//

import AppKit
import ApplicationServices
import Combine

/// Tracks the right edge of the frontmost application's menu bar items.
///
/// A live activity draws into the strip of menu bar to the left of the notch,
/// which is the same strip the app's own menus occupy. macOS lays those menus
/// out inside `NSScreen.auxiliaryTopLeftArea` and offers no way to tell it that
/// something else is using part of that space -- both auxiliary areas are
/// read-only and derived from the display hardware. So rather than reserving
/// room, Atoll measures what is already there and moves aside.
///
/// The measurement is the accessibility API's view of the menu bar, which is
/// how the geometry is available at all: every menu reports its own position
/// and size.
@MainActor
final class MenuBarLayout: ObservableObject {
    static let shared = MenuBarLayout()

    /// Right edge of the last menu of the frontmost app, in screen coordinates.
    /// `nil` when it cannot be known -- no accessibility permission, an app that
    /// exposes no menu bar, or a process that did not answer in time. Callers
    /// treat that as "no constraint" rather than guessing.
    @Published private(set) var appMenusRightEdge: CGFloat?

    /// Frames of the status items in the menu bar (accessibility coordinates:
    /// origin top-left of the primary display). Empty when none could be read.
    @Published private(set) var statusItemFrames: [CGRect] = []

    /// Menus change with the frontmost app, and within an app as its windows
    /// change, so a slow poll backs up the activation notice. It runs only
    /// while something actually needs the measurement.
    private static let pollInterval: TimeInterval = 3

    private var observer: NSObjectProtocol?
    private var pollTimer: Timer?
    private var trackers = 0
    private var inFlight = false
    private var loggedUntrusted = false

    private init() {}

    /// How far right content of `contentWidth`, centred in `screenFrame`, has to
    /// move so its left edge clears menus ending at `menusRightEdge`.
    ///
    /// Zero when nothing is covered. Capped at the room remaining on the right,
    /// because a shift that pushes the content off the far edge has traded one
    /// covered thing for another.
    ///
    /// The right-hand side is the status items -- clock, Wi-Fi, the menu bar's
    /// own overflow chevron -- which macOS lays out from the notch outward just
    /// as it does the app's menus. Content wide enough to reach them moves left
    /// instead. When both sides are covered and there is no position that
    /// clears both, the overlap is split between them rather than one side
    /// being buried entirely.
    nonisolated static func clearanceOffset(
        contentWidth: CGFloat,
        screenFrame: CGRect,
        menusRightEdge: CGFloat?,
        statusItemsLeftEdge: CGFloat? = nil,
        gap: CGFloat
    ) -> CGFloat {
        guard contentWidth > 0 else { return 0 }
        let contentLeftEdge = screenFrame.midX - contentWidth / 2
        let contentRightEdge = contentLeftEdge + contentWidth
        let rightHeadroom = max(0, screenFrame.maxX - contentRightEdge)
        let leftHeadroom = max(0, contentLeftEdge - screenFrame.minX)

        // The smallest shift that clears the app's menus, and the largest that
        // still clears the status items. Positive is rightward.
        let lowest = menusRightEdge.map { ($0 + gap) - contentLeftEdge }
        let highest = statusItemsLeftEdge.map { ($0 - gap) - contentRightEdge }

        let shift: CGFloat
        switch (lowest, highest) {
        case (nil, nil):
            return 0
        case (let lowest?, nil):
            guard lowest > 0 else { return 0 }
            shift = lowest
        case (nil, let highest?):
            guard highest < 0 else { return 0 }
            shift = highest
        case (let lowest?, let highest?):
            if lowest <= highest {
                // Some position clears both; take the one nearest centre.
                shift = min(max(0, lowest), highest)
            } else {
                shift = (lowest + highest) / 2
            }
        }
        return min(max(shift, -leftHeadroom), rightHeadroom)
    }

    /// Tallest menu bar there is (a notched display's is about 39pt); only
    /// used to tell menu bar items from anything else the scan returns.
    nonisolated private static let maxMenuBarHeight: CGFloat = 50

    /// Left edge of the leftmost status item right of centre on `screenFrame`,
    /// from the frames `refresh()` collected; `nil` when there are none.
    nonisolated static func statusItemsLeftEdge(
        in screenFrame: CGRect,
        frames: [CGRect],
        primaryScreenHeight: CGFloat
    ) -> CGFloat? {
        // Accessibility frames have their origin top-left of the primary
        // display, screen frames bottom-left. x is the
        // same in both; the menu bar's top is where they disagree.
        // Items are not all flush with the top: system ones span the whole
        // bar, third-party ones are inset (y 7.5, height 24 on a 39pt bar). So
        // an item counts if its middle falls inside the menu bar's height.
        let menuBarTop = primaryScreenHeight - screenFrame.maxY
        let menuBarBand = menuBarTop...(menuBarTop + maxMenuBarHeight)
        let edges = frames
            .filter { menuBarBand.contains($0.midY) }
            .filter { $0.minX >= screenFrame.midX && $0.maxX <= screenFrame.maxX + 1 }
            .map(\.minX)
        return edges.min()
    }

    /// Every app's status items, read from its accessibility "extras" menu
    /// bar. On current macOS they are not windows of their own -- the menu bar
    /// agent draws them -- so the window list cannot see them, but each item
    /// still reports its frame here. That includes the menu bar's own "show
    /// hidden items" chevron, which sits right against the notch.
    nonisolated private static func statusItemFrames(pids: [pid_t]) -> [CGRect] {
        let startedAt = Date()
        var frames: [CGRect] = []
        for pid in pids {
            guard Date().timeIntervalSince(startedAt) < scanDeadline else { break }
            let app = AXUIElementCreateApplication(pid)
            AXUIElementSetMessagingTimeout(app, extrasTimeout)

            var barValue: CFTypeRef?
            guard AXUIElementCopyAttributeValue(app, "AXExtrasMenuBar" as CFString, &barValue) == .success,
                  CFGetTypeID(barValue) == AXUIElementGetTypeID()
            else { continue }
            let bar = unsafeBitCast(barValue, to: AXUIElement.self)
            AXUIElementSetMessagingTimeout(bar, extrasTimeout)

            var childrenValue: CFTypeRef?
            guard AXUIElementCopyAttributeValue(bar, kAXChildrenAttribute as CFString, &childrenValue) == .success,
                  let items = childrenValue as? [AXUIElement]
            else { continue }

            for item in items {
                AXUIElementSetMessagingTimeout(item, extrasTimeout)
                if let frame = frame(of: item), frame.width > 0 {
                    frames.append(frame)
                }
            }
        }
        return frames
    }

    /// Most apps have no extras menu bar and answer at once; one that does not
    /// answer is skipped quickly rather than holding up the rest.
    nonisolated private static let extrasTimeout: Float = 0.1

    nonisolated private static func frame(of element: AXUIElement) -> CGRect? {
        var positionValue: CFTypeRef?
        var sizeValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &positionValue) == .success,
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeValue) == .success
        else { return nil }
        var origin = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(positionValue as! AXValue, .cgPoint, &origin),
              AXValueGetValue(sizeValue as! AXValue, .cgSize, &size)
        else { return nil }
        return CGRect(origin: origin, size: size)
    }

    /// Breathing room between the last menu and the notch content, so they do
    /// not end up flush against each other.
    nonisolated static let clearanceGap: CGFloat = 8

    /// Begin measuring. Balanced by `stopTracking()`; nested calls are counted,
    /// so several live activities can ask at once without one's disappearance
    /// stopping the others.
    func startTracking() {
        trackers += 1
        guard trackers == 1 else { return }

        observer = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }

        let timer = Timer(timeInterval: Self.pollInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer

        refresh()
    }

    func stopTracking() {
        guard trackers > 0 else { return }
        trackers -= 1
        guard trackers == 0 else { return }

        if let observer {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
            self.observer = nil
        }
        pollTimer?.invalidate()
        pollTimer = nil
        appMenusRightEdge = nil
        statusItemFrames = []
    }

    func refresh() {
        guard !inFlight else { return }
        guard AXIsProcessTrusted() else {
            if appMenusRightEdge != nil || !statusItemFrames.isEmpty || !loggedUntrusted {
                Logger.log("MenuBarLayout: no accessibility permission, menu bar not measured", category: .lifecycle)
                loggedUntrusted = true
            }
            appMenusRightEdge = nil
            statusItemFrames = []
            return
        }
        loggedUntrusted = false
        let frontmostPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let ownPID = ProcessInfo.processInfo.processIdentifier
        // Atoll itself is skipped: accessibility requests to this process are
        // answered on its own main thread, which the scan should not depend on.
        let pids = NSWorkspace.shared.runningApplications.map(\.processIdentifier).filter { $0 != ownPID }

        // Off the main actor: these are cross-process calls, and an app that has
        // stopped answering would otherwise take the notch's UI down with it.
        inFlight = true
        Task.detached(priority: .utility) {
            let edge = frontmostPID.flatMap { Self.menusRightEdge(pid: $0) }
            let frames = Self.statusItemFrames(pids: pids)
            await MainActor.run {
                self.inFlight = false
                guard self.trackers > 0 else { return }
                if self.appMenusRightEdge != edge || self.statusItemFrames != frames {
                    let leftmost = frames.map(\.minX).filter { $0 > 0 }.min()
                    Logger.log(
                        "MenuBarLayout: app menus end \(edge.map { "\($0)" } ?? "?"), \(frames.count) status items, leftmost \(leftmost.map { "\($0)" } ?? "?")",
                        category: .lifecycle
                    )
                }
                if self.appMenusRightEdge != edge { self.appMenusRightEdge = edge }
                if self.statusItemFrames != frames { self.statusItemFrames = frames }
            }
        }
    }

    /// Longest the whole scan may take. A menu bar with many items could
    /// otherwise reach minutes at the per-element timeout, and until it returns
    /// no further measurement is taken.
    nonisolated private static let scanDeadline: TimeInterval = 1

    /// Per-element messaging timeout. `AXUIElementSetMessagingTimeout` applies
    /// only to the element it is called on -- it does not carry to the children
    /// that element hands back -- so every element messaged here is given its
    /// own, or a hung app would still block on the ones that inherited nothing.
    nonisolated private static let elementTimeout: Float = 0.25

    /// The right edge of the last menu, or `nil` if the menu bar cannot be read.
    nonisolated private static func menusRightEdge(pid: pid_t) -> CGFloat? {
        let startedAt = Date()
        let app = AXUIElementCreateApplication(pid)
        // A hung app must not hold this up; the measurement is an optimisation,
        // never something worth waiting on.
        AXUIElementSetMessagingTimeout(app, elementTimeout)

        var menuBarValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXMenuBarAttribute as CFString, &menuBarValue) == .success,
              CFGetTypeID(menuBarValue) == AXUIElementGetTypeID()
        else { return nil }
        let menuBar = unsafeBitCast(menuBarValue, to: AXUIElement.self)
        AXUIElementSetMessagingTimeout(menuBar, elementTimeout)

        var childrenValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(menuBar, kAXChildrenAttribute as CFString, &childrenValue) == .success,
              let items = childrenValue as? [AXUIElement], !items.isEmpty
        else { return nil }

        var rightEdge: CGFloat?
        for item in items {
            // Whatever has been measured so far is still usable; a scan that has
            // run long is one where the app is not answering, and waiting out
            // every remaining item only delays the next attempt.
            guard Date().timeIntervalSince(startedAt) < scanDeadline else { break }
            AXUIElementSetMessagingTimeout(item, elementTimeout)

            var positionValue: CFTypeRef?
            var sizeValue: CFTypeRef?
            guard AXUIElementCopyAttributeValue(item, kAXPositionAttribute as CFString, &positionValue) == .success,
                  AXUIElementCopyAttributeValue(item, kAXSizeAttribute as CFString, &sizeValue) == .success
            else { continue }

            var origin = CGPoint.zero
            var size = CGSize.zero
            guard AXValueGetValue(positionValue as! AXValue, .cgPoint, &origin),
                  AXValueGetValue(sizeValue as! AXValue, .cgSize, &size)
            else { continue }

            rightEdge = max(rightEdge ?? 0, origin.x + size.width)
        }
        return rightEdge
    }
}
