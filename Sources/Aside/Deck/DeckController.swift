import AppKit
import SwiftUI
import Combine
import QuartzCore

@MainActor
final class DeckController {
    let viewModel: DeckViewModel
    private let deckPanel = DeckPanel()
    private var pillPanels: [String: PillPanel] = [:]
    private var currentScreen: NSScreen?
    private var cancellables = Set<AnyCancellable>()
    private var panelRetractionID: UUID?
    /// False between session-resign and session-become-active. Relayout is
    /// suppressed while false so the deck cannot re-show itself on the login
    /// window, and the model is forced back to `.pill` on the way out.
    private var sessionActive = true
    private var lastPanelEdge = AppSettings.deckEdge
    private var lastShowOverFullScreen = AppSettings.showOverFullScreen

    init(viewModel: DeckViewModel) {
        self.viewModel = viewModel

        let hostingView = PassThroughHostingView(rootView: DeckView(viewModel: viewModel))
        deckPanel.contentView = hostingView

        viewModel.$state
            .receive(on: DispatchQueue.main)
            .dropFirst()
            .sink { [weak self] _ in
                // Only reset text focus on state transitions — data-driven
                // relayouts (autosave reloads, store swaps) must not steal
                // focus from the open editor mid-typing.
                self?.deckPanel.makeFirstResponder(nil)
                self?.relayout(animated: true, reason: .stateChange)
            }
            .store(in: &cancellables)
        viewModel.$deckNotes
            .receive(on: DispatchQueue.main)
            .removeDuplicates()
            .sink { [weak self] _ in
                self?.relayout(animated: false, reason: .dataChange)
                if ProcessInfo.processInfo.environment["ASIDE_DEBUG_AUTOSAVE"] == "1",
                   let panel = NSApp.windows.first(where: { $0 is DeckPanel }) {
                    NSLog("Aside post-relayout responder: %@ visible=%d key=%d",
                          String(describing: type(of: panel.firstResponder)),
                          panel.isVisible ? 1 : 0,
                          panel.isKeyWindow ? 1 : 0)
                }
            }
            .store(in: &cancellables)
        // The undo toast lives outside the fan/card content rects; hit
        // testing must be refreshed whenever it appears or disappears, or
        // the Undo button is click-through.
        viewModel.$pendingDelete
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self, self.viewModel.state != .pill else { return }
                self.updateHitRects()
            }
            .store(in: &cancellables)
        viewModel.$cardOffsetY
            .receive(on: DispatchQueue.main)
            .removeDuplicates()
            .sink { [weak self] _ in
                guard let self, case .expanded = self.viewModel.state else { return }
                self.updateHitRects()
            }
            .store(in: &cancellables)
        viewModel.$peekedNoteID
            .receive(on: DispatchQueue.main)
            .removeDuplicates()
            .sink { [weak self] _ in
                guard let self, self.viewModel.state == .fan else { return }
                self.updateHitRects()
            }
            .store(in: &cancellables)
        // Paging changes how many tabs are drawn, which changes the fan rect.
        viewModel.$drawnTabCount
            .receive(on: DispatchQueue.main)
            .removeDuplicates()
            .sink { [weak self] _ in
                guard let self, self.viewModel.state != .pill else { return }
                self.updateHitRects()
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self else { return }
                // The deck's display may have just been unplugged. Falling back
                // to the stale NSScreen positioned the panel in a coordinate
                // space that no longer exists, with pills suppressed on the
                // surviving display and no gesture able to recover.
                if self.resolvedScreen() == nil {
                    self.currentScreen = nil
                    self.viewModel.clearPeek()
                    self.viewModel.state = .pill
                }
                self.rebuildPillPanels()
                self.relayout(animated: false)
            }
            .store(in: &cancellables)

        NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.sessionDidResignActiveNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.hideAllPanels() }
            .store(in: &cancellables)

        NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.sessionDidBecomeActiveNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.sessionActive = true
                self?.relayout(animated: false)
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: .appSettingsChanged)
            .debounce(for: .milliseconds(150), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self else { return }
                // Every AppSettings write posts this, including the card offset
                // saved on each drag-end. Rebuilding a panel per display for a
                // scroll position is waste, and it was a second way to abort an
                // in-flight collapse.
                let edge = AppSettings.deckEdge
                let overFullScreen = AppSettings.showOverFullScreen
                guard edge != self.lastPanelEdge
                        || overFullScreen != self.lastShowOverFullScreen else { return }
                self.lastPanelEdge = edge
                self.lastShowOverFullScreen = overFullScreen
                self.applyFullscreenBehavior()
                self.rebuildPillPanels()
                self.relayout(animated: false)
            }
            .store(in: &cancellables)
    }

    func install() {
        viewModel.shouldCollapseCheck = { [weak self] in
            guard let self, self.deckPanel.isVisible else { return true }
            // Only the content rects count (D25 follow-up): the panel is
            // fixed at its maximum extents, so a pointer inside the panel
            // frame but above/below the fan must still collapse the deck.
            guard let hosting = self.deckPanel.contentView as? PassThroughHostingView else {
                return !self.deckPanel.frame.contains(NSEvent.mouseLocation)
            }
            let windowPoint = self.deckPanel.convertPoint(fromScreen: NSEvent.mouseLocation)
            let local = hosting.convert(windowPoint, from: nil)
            // Same flip as `PassThroughHostingView.hitTest`: the hosting view is
            // flipped, the DeckMetrics rects are bottom-left. Without this the
            // undo toast reads as "pointer left the deck" (collapsing the panel
            // out from under the Undo button) while the mirrored band at the top
            // reads as "still inside" and pins the fan open.
            let unflipped = DeckMetrics.unflippedHitPoint(local, in: hosting.bounds, isFlipped: hosting.isFlipped)
            return !self.currentContentRects().contains { $0.contains(unflipped) }
        }
        viewModel.pinTransitionFrameProvider = { [weak self] in
            self?.expandedCardScreenFrame()
        }
        viewModel.collapseRequest = { [weak self] in
            self?.beginPanelRetraction()
        }
        viewModel.collapseCancellationRequest = { [weak self] in
            self?.cancelPanelRetraction()
        }
        rebuildPillPanels()
        relayout(animated: false)
    }

    // MARK: - Panels

    private func rebuildPillPanels() {
        pillPanels.values.forEach { $0.orderOut(nil) }
        pillPanels.removeAll()

        for screen in NSScreen.screens {
            let panel = PillPanel()
            let hostingView = FirstMouseHostingView(
                rootView: PillView(viewModel: viewModel, screen: screen) { [weak self] in
                    self?.openDeck(on: screen)
                }
            )
            panel.contentView = hostingView
            pillPanels[Self.screenKey(for: screen)] = panel
        }
    }

    /// Keyed by CGDirectDisplayID: two identical monitors report the same
    /// localizedName, so it must not be used as the identity.
    private static func screenKey(for screen: NSScreen) -> String {
        let screenNumber = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? Int ?? 0
        return "display-\(screenNumber)"
    }

    private static func screen(forKey key: String) -> NSScreen? {
        NSScreen.screens.first { Self.screenKey(for: $0) == key }
    }

    /// Re-resolves `currentScreen` against the live display list. `NSScreen`
    /// instances are not stable across reconfiguration, so identity is matched
    /// by display id.
    private func resolvedScreen() -> NSScreen? {
        guard let currentScreen else { return nil }
        return Self.screen(forKey: Self.screenKey(for: currentScreen))
    }

    private func applyFullscreenBehavior() {
        deckPanel.applyFullscreenBehavior()
        pillPanels.values.forEach { $0.applyFullscreenBehavior() }
    }

    private func hideAllPanels() {
        sessionActive = false
        panelRetractionID = nil
        DeckCursor.reset()
        // Without this the deck comes back from a lock still fanned, with the
        // pointer nowhere near it — and no hover exit will ever arrive to
        // collapse it.
        viewModel.clearPeek()
        viewModel.state = .pill
        deckPanel.orderOut(nil)
        hidePills()
    }

    // MARK: - State transitions

    /// Called when the pointer reaches a display's pill. Screen switching is
    /// deliberately sticky: only this (and explicit triggers) change screens.
    func openDeck(on screen: NSScreen) {
        guard viewModel.state == .pill else { return }
        viewModel.deckHoverChanged(true)
        currentScreen = screen
        // Animated so the tabs' insertion transitions (and their per-index
        // stagger) actually run — a bare assignment gives SwiftUI no
        // transaction to animate, and the fan just pops in.
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            viewModel.state = .fan
        } else {
            withAnimation { viewModel.state = .fan }
        }
    }

    /// Why a relayout was requested. A data change must never abort an
    /// in-flight collapse: the collapse task has already fired, so cancelling
    /// the retraction leaves the fan extended with nothing to re-arm it — an
    /// autosave landing ~270 ms after a keystroke was enough to strand it.
    private enum RelayoutReason {
        case stateChange
        case dataChange
    }

    private func relayout(animated: Bool, reason: RelayoutReason = .dataChange) {
        guard sessionActive else { return }
        let state = viewModel.state
        let count = viewModel.deckNotes.count
        if ProcessInfo.processInfo.environment["ASIDE_DEBUG_FAN"] != nil || ProcessInfo.processInfo.environment["ASIDE_DEBUG_EXPAND"] != nil || ProcessInfo.processInfo.environment["ASIDE_DEBUG_AUTOSAVE"] != nil {
            NSLog("Aside relayout state=\(state) count=\(count) animated=\(animated)")
        }

        switch state {
        case .pill:
            handOffToPill(noteCount: count)

        case .fan, .expanded:
            hidePills()
            // A hotkey or menu action can land mid-retraction. Skipping the
            // show here left the panel hidden with a live `.fan`/`.expanded`
            // state, and `openDeck` is guarded on `.pill` — the deck became
            // unreachable until the app was quit.
            if panelRetractionID != nil {
                guard reason == .stateChange else { return }
                cancelPanelRetraction()
            }
            positionAndShowDeck()
        }
    }

    /// Normal deck layout always uses this exact resting frame. Only the close
    /// path temporarily moves the whole panel, leaving its SwiftUI contents
    /// completely untouched.
    private func positionAndShowDeck() {
        guard let screen = resolvedScreen() ?? NSScreen.main else { return }
        currentScreen = screen

        let frame = DeckMetrics.deckPanelFrame(screen: screen)
        if viewModel.panelHeight != frame.height {
            viewModel.updatePanelHeight(frame.height)
        }
        if !deckPanel.isVisible {
            deckPanel.setFrame(frame, display: false)
            deckPanel.alphaValue = 1
            deckPanel.orderFrontRegardless()
        } else if deckPanel.frame != frame {
            deckPanel.setFrame(frame, display: true)
        }
        updateHitRects()
    }

    private func expandedCardScreenFrame() -> CGRect? {
        guard deckPanel.isVisible,
              let hosting = deckPanel.contentView as? PassThroughHostingView else { return nil }
        let local = DeckMetrics.cardContentRect(
            panelWidth: hosting.bounds.width,
            panelHeight: hosting.bounds.height,
            noteCount: viewModel.deckNotes.count,
            verticalOffset: viewModel.cardOffsetY
        )
        return local.offsetBy(dx: deckPanel.frame.minX, dy: deckPanel.frame.minY)
    }

    private func handOffToPill(noteCount: Int) {
        guard deckPanel.isVisible else {
            showPills(count: noteCount)
            return
        }
        showPills(count: noteCount)
        deckPanel.orderOut(nil)
        deckPanel.alphaValue = 1
    }

    private func beginPanelRetraction() {
        guard panelRetractionID == nil else { return }
        guard viewModel.state == .fan,
              deckPanel.isVisible,
              let screen = resolvedScreen() ?? NSScreen.main else {
            viewModel.completePanelRetraction()
            return
        }

        let restingFrame = DeckMetrics.deckPanelFrame(screen: screen)
        let exposedWidth = DeckMetrics.fanPadding
            + (viewModel.peekedNoteID == nil ? DeckMetrics.tabWidth : DeckMetrics.peekWidth)
        let targetFrame = DeckInteraction.retractedPanelFrame(
            restingFrame: restingFrame,
            exposedWidth: exposedWidth,
            isRightEdge: DeckMetrics.edge == .right
        )

        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            finishPanelRetraction(restingFrame: restingFrame)
            return
        }

        let retractionID = UUID()
        panelRetractionID = retractionID
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Double(DeckInteraction.panelRetractionMilliseconds) / 1_000
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            deckPanel.animator().setFrame(targetFrame, display: true)
        } completionHandler: { [weak self] in
            Task { @MainActor in
                guard let self, self.panelRetractionID == retractionID else { return }
                self.finishPanelRetraction(restingFrame: restingFrame)
            }
        }
    }

    private func cancelPanelRetraction() {
        guard panelRetractionID != nil else { return }
        // Cleared before the screen lookup: leaving it set when no screen can
        // be resolved (display teardown) made `beginPanelRetraction` early-
        // return forever, so the deck could never collapse again.
        panelRetractionID = nil
        guard let screen = resolvedScreen() ?? NSScreen.main else { return }
        let restingFrame = DeckMetrics.deckPanelFrame(screen: screen)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.12
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            deckPanel.animator().setFrame(restingFrame, display: true)
        }
    }

    private func finishPanelRetraction(restingFrame: CGRect) {
        panelRetractionID = nil
        guard viewModel.state == .fan else {
            // State moved on mid-animation (a new note, a hotkey). Put the
            // panel back where it belongs instead of hiding it.
            deckPanel.setFrame(restingFrame, display: true)
            deckPanel.alphaValue = 1
            return
        }
        showPills(count: viewModel.deckNotes.count)
        deckPanel.orderOut(nil)
        deckPanel.setFrame(restingFrame, display: false)
        deckPanel.alphaValue = 1
        viewModel.completePanelRetraction()
    }

    private func showPills(count: Int) {
        for (key, panel) in pillPanels {
            guard let screen = Self.screen(forKey: key) else { continue }
            panel.setFrame(DeckMetrics.pillFrame(noteCount: count, screen: screen), display: true)
            panel.alphaValue = 1
            panel.orderFrontRegardless()
        }
    }

    private func hidePills() {
        pillPanels.values.forEach { panel in
            panel.orderOut(nil)
            // Keep the next atomic handoff deterministic after a quick
            // re-entry or a display reconfiguration.
            panel.alphaValue = 1
        }
    }

    /// Content rects mirror the SwiftUI layout exactly (both are pure
    /// functions of state + metrics); everything else is click-through.
    private func currentContentRects() -> [CGRect] {
        guard let hosting = deckPanel.contentView as? PassThroughHostingView else { return [] }
        let state = viewModel.state
        let count = viewModel.deckNotes.count
        let bounds = hosting.bounds

        guard state != .pill else { return [] }

        let drawnTabs = viewModel.drawnTabCount
        var rects = [
            DeckMetrics.fanContentRect(
                panelWidth: bounds.width,
                panelHeight: bounds.height,
                noteCount: count,
                isPeeking: viewModel.peekedNoteID != nil,
                drawnTabCount: drawnTabs
            )
        ]
        if case .expanded = state {
            rects.append(
                DeckMetrics.cardContentRect(
                    panelWidth: bounds.width,
                    panelHeight: bounds.height,
                    noteCount: count,
                    verticalOffset: viewModel.cardOffsetY,
                    drawnTabCount: drawnTabs
                )
            )
        }
        if viewModel.pendingDelete != nil {
            rects.append(
                DeckMetrics.toastContentRect(
                    panelWidth: bounds.width,
                    panelHeight: bounds.height
                )
            )
        }
        return rects
    }

    private func updateHitRects() {
        guard let hosting = deckPanel.contentView as? PassThroughHostingView else { return }
        // Evaluate against the current hover state for every event. Capturing
        // a rect snapshot here leaves a one-run-loop gap after a tab expands,
        // during which the visible preview is click-through and immediately
        // receives a false hover exit.
        hosting.shouldAcceptHit = { [weak self] point in
            guard let self else { return false }
            return self.currentContentRects().contains { $0.contains(point) }
        }
    }
}
