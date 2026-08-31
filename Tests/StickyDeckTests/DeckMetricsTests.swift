import XCTest
@testable import StickyDeck

final class DeckMetricsTests: XCTestCase {
    override func tearDown() {
        AppSettings.deckEdge = .right
        super.tearDown()
    }

    // MARK: - Fan fit (D26)

    func testFanLayoutKeepsFullStaggerOnTallPanels() {
        let layout = DeckMetrics.fanLayout(noteCount: 8, panelHeight: 900)
        XCTAssertEqual(layout.visibleCount, 8)
        XCTAssertEqual(layout.tabStep, DeckMetrics.tabStep)
    }

    func testFanLayoutFitsShortPanels() {
        // 8 tabs at the full stagger need 158 + 7×84 = 746 pt plus the
        // plus-button allowance — a 500 pt panel must fit by tightening.
        let panelHeight: CGFloat = 500
        let layout = DeckMetrics.fanLayout(noteCount: 8, panelHeight: panelHeight)
        let column = DeckMetrics.fanColumnHeight(noteCount: 8, panelHeight: panelHeight)
        XCTAssertLessThanOrEqual(column, panelHeight)
        XCTAssertLessThan(layout.tabStep, DeckMetrics.tabStep)
        XCTAssertGreaterThanOrEqual(layout.tabStep, DeckMetrics.minTabStep)
        XCTAssertEqual(layout.visibleCount, 8)
    }

    func testFanLayoutDropsTabsWhenStaggerHitsTheFloor() {
        let layout = DeckMetrics.fanLayout(noteCount: 12, panelHeight: 320)
        XCTAssertLessThan(layout.visibleCount, DeckMetrics.maxVisibleTabs)
        let column = DeckMetrics.fanColumnHeight(noteCount: 12, panelHeight: 320)
        XCTAssertLessThanOrEqual(column, 320)
    }

    func testFanLayoutEmptyDeck() {
        let layout = DeckMetrics.fanLayout(noteCount: 0, panelHeight: 600)
        XCTAssertEqual(layout.visibleCount, 0)
        XCTAssertEqual(DeckMetrics.tabsExtent(visibleCount: 0, step: layout.tabStep), 0)
        XCTAssertEqual(
            DeckMetrics.fanColumnHeight(noteCount: 0, panelHeight: 600),
            DeckMetrics.plusSize * 2 + DeckMetrics.tileGap * 2
        )
    }

    func testOverflowFanAccountsForMoreTile() {
        let panelHeight: CGFloat = 500
        let layout = DeckMetrics.fanLayout(noteCount: 12, panelHeight: panelHeight)
        let tabs = DeckMetrics.tabsExtent(visibleCount: layout.visibleCount, step: layout.tabStep)
        let accessories = DeckMetrics.accessoryHeight(noteCount: 12, visibleCount: layout.visibleCount)

        XCTAssertEqual(accessories, DeckMetrics.plusSize * 2 + DeckMetrics.tileGap * 2)
        XCTAssertLessThanOrEqual(tabs + accessories, panelHeight)
        XCTAssertEqual(DeckMetrics.fanColumnHeight(noteCount: 12, panelHeight: panelHeight), tabs + accessories)
    }

    func testPillMatchesTwelvePointReferenceWidth() {
        XCTAssertEqual(DeckMetrics.pillWidth, 12)
        XCTAssertLessThan(DeckMetrics.pillDashWidth, DeckMetrics.pillWidth)
        XCTAssertGreaterThan(DeckMetrics.pillDashHeight, DeckMetrics.pillDashWidth)
    }

    func testPillHonorsTheMinimumHeightWithNoNotes() {
        XCTAssertEqual(
            DeckMetrics.pillHeight(noteCount: 0, maximumHeight: 1_000),
            36
        )
    }

    func testLiveMeasuredDeckDimensions() {
        XCTAssertEqual(DeckMetrics.tabWidth, 40)
        XCTAssertEqual(DeckMetrics.peekWidth, 192)
        XCTAssertEqual(DeckMetrics.noteWidth, 400)
        XCTAssertEqual(DeckMetrics.expandedCardHeight, 450)
    }

    func testLiveMeasuredPaletteOrderPreservesPersistenceValues() {
        XCTAssertEqual(NoteColor.allCases.map(\.name), ["Amber", "Coral", "Mint", "Sky", "Lilac"])
        XCTAssertEqual(NoteColor.amber.rawValue, 0)
        XCTAssertEqual(NoteColor.mint.rawValue, 1)
        XCTAssertEqual(NoteColor.sky.rawValue, 2)
        XCTAssertEqual(NoteColor.lilac.rawValue, 3)
        XCTAssertEqual(NoteColor.coral.rawValue, 4)
    }

    // MARK: - Edge-aware content rects

    func testContentRectsHugRightEdge() {
        AppSettings.deckEdge = .right
        let panelWidth: CGFloat = 480
        let panelHeight: CGFloat = 800

        let fan = DeckMetrics.fanContentRect(panelWidth: panelWidth, panelHeight: panelHeight, noteCount: 3)
        XCTAssertEqual(fan.maxX, panelWidth, accuracy: 0.01)

        let card = DeckMetrics.cardContentRect(panelWidth: panelWidth, panelHeight: panelHeight, noteCount: 3)
        XCTAssertEqual(card.maxX, fan.minX - DeckMetrics.noteGap, accuracy: 0.01)
    }

    func testPeekingFanUsesMeasuredPreviewWidth() {
        AppSettings.deckEdge = .right
        let panelWidth: CGFloat = 480
        let fan = DeckMetrics.fanContentRect(
            panelWidth: panelWidth,
            panelHeight: 800,
            noteCount: 3,
            isPeeking: true
        )

        XCTAssertEqual(fan.width, DeckMetrics.peekWidth)
        XCTAssertEqual(fan.maxX, panelWidth, accuracy: 0.01)
    }

    func testContentRectsHugLeftEdge() {
        AppSettings.deckEdge = .left
        let panelWidth: CGFloat = 480
        let panelHeight: CGFloat = 800

        let fan = DeckMetrics.fanContentRect(panelWidth: panelWidth, panelHeight: panelHeight, noteCount: 3)
        XCTAssertEqual(fan.minX, 0, accuracy: 0.01)

        let card = DeckMetrics.cardContentRect(panelWidth: panelWidth, panelHeight: panelHeight, noteCount: 3)
        XCTAssertEqual(card.minX, fan.maxX + DeckMetrics.noteGap, accuracy: 0.01)
        XCTAssertGreaterThan(card.maxX, 0)
        XCTAssertLessThan(card.maxX, panelWidth)
    }

    func testCardContentRectTracksSwiftUIVerticalOffset() {
        let centered = DeckMetrics.cardContentRect(
            panelWidth: 480,
            panelHeight: 800,
            noteCount: 3
        )
        let movedDown = DeckMetrics.cardContentRect(
            panelWidth: 480,
            panelHeight: 800,
            noteCount: 3,
            verticalOffset: 40
        )
        XCTAssertEqual(movedDown.minY, centered.minY - 40, accuracy: 0.01)
    }

    func testCardOffsetClampsToVisiblePanelArea() {
        let panelHeight: CGFloat = 600
        let limit = DeckMetrics.cardOffsetLimit(panelHeight: panelHeight)

        XCTAssertEqual(limit, 69)
        XCTAssertEqual(DeckMetrics.clampedCardOffset(500, panelHeight: panelHeight), limit)
        XCTAssertEqual(DeckMetrics.clampedCardOffset(-500, panelHeight: panelHeight), -limit)
        XCTAssertEqual(DeckMetrics.clampedCardOffset(24, panelHeight: panelHeight), 24)
    }

    func testCardOffsetCentersWhenPanelIsShorterThanCard() {
        XCTAssertEqual(DeckMetrics.clampedCardOffset(80, panelHeight: 400), 0)
    }

    // MARK: - Flipped hit testing (regression)

    /// `NSHostingView` is flipped, so hit-test points arrive top-left while
    /// every rect here is bottom-left. Without the conversion the undo toast
    /// was unclickable and an equivalent band at the opposite end of the panel
    /// swallowed clicks meant for the app underneath.
    func testFlippedHitPointConvertsIntoTheBottomLeftRectBasis() {
        let bounds = CGRect(x: 0, y: 0, width: 450, height: 800)

        // A click 10 pt above the panel's bottom arrives as y = 790 when flipped.
        // x is inside the edge-aligned toast itself (right edge, 260 pt wide).
        let nearBottom = DeckMetrics.unflippedHitPoint(
            CGPoint(x: 380, y: 790),
            in: bounds,
            isFlipped: true
        )
        XCTAssertEqual(nearBottom.y, 10, accuracy: 0.001)

        let toast = DeckMetrics.toastContentRect(panelWidth: 450, panelHeight: 800)
        XCTAssertTrue(toast.contains(nearBottom), "The undo button must accept clicks")

        // ...and the top of the panel must NOT be inside the bottom-anchored toast.
        let nearTop = DeckMetrics.unflippedHitPoint(
            CGPoint(x: 380, y: 10),
            in: bounds,
            isFlipped: true
        )
        XCTAssertFalse(toast.contains(nearTop), "The top of the deck must stay click-through")
    }

    /// The toast is edge-aligned and much narrower than the expanded panel.
    /// Claiming the full width left a wide invisible dead zone eating clicks
    /// meant for the app underneath, for ten seconds after every delete.
    func testToastRectDoesNotClaimTheWholePanelWidth() {
        let toast = DeckMetrics.toastContentRect(panelWidth: 450, panelHeight: 800)
        XCTAssertLessThan(toast.width, DeckMetrics.expandedPanelWidth())
        // A point in the blank area beside the toast must fall through.
        XCTAssertFalse(toast.contains(CGPoint(x: 60, y: 30)))
    }

    func testUnflippedHitPointLeavesUnflippedViewsAlone() {
        let point = CGPoint(x: 12, y: 34)
        XCTAssertEqual(
            DeckMetrics.unflippedHitPoint(point, in: CGRect(x: 0, y: 0, width: 100, height: 100), isFlipped: false),
            point
        )
    }

    /// Regression: the fan hit rect used the layout's page size rather than
    /// the tabs actually drawn, so a partial last page left a tall invisible
    /// strip that swallowed clicks and kept the deck from collapsing.
    func testFanColumnFollowsTheTabsActuallyDrawn() {
        let panelHeight: CGFloat = 1400
        let full = DeckMetrics.fanColumnHeight(noteCount: 12, panelHeight: panelHeight)
        let lastPage = DeckMetrics.fanColumnHeight(
            noteCount: 12,
            panelHeight: panelHeight,
            drawnTabCount: 4
        )
        XCTAssertLessThan(lastPage, full)

        let layout = DeckMetrics.fanLayout(noteCount: 12, panelHeight: panelHeight)
        let expected = DeckMetrics.tabsExtent(visibleCount: 4, step: layout.tabStep)
            + DeckMetrics.accessoryHeight(noteCount: 12, visibleCount: layout.visibleCount)
        XCTAssertEqual(lastPage, expected, accuracy: 0.001)
    }

    /// A drawn count larger than the page size must never widen the rect.
    func testFanColumnClampsAnOverlargeDrawnCount() {
        let panelHeight: CGFloat = 1400
        XCTAssertEqual(
            DeckMetrics.fanColumnHeight(noteCount: 12, panelHeight: panelHeight, drawnTabCount: 99),
            DeckMetrics.fanColumnHeight(noteCount: 12, panelHeight: panelHeight),
            accuracy: 0.001
        )
    }

    func testToastRectFollowsEdge() {
        let panelWidth: CGFloat = 480
        let panelHeight: CGFloat = 800

        AppSettings.deckEdge = .right
        let right = DeckMetrics.toastContentRect(panelWidth: panelWidth, panelHeight: panelHeight)
        XCTAssertEqual(right.maxX, panelWidth, accuracy: 0.01)

        AppSettings.deckEdge = .left
        let left = DeckMetrics.toastContentRect(panelWidth: panelWidth, panelHeight: panelHeight)
        XCTAssertEqual(left.minX, 0, accuracy: 0.01)
    }
}

final class ImportParsingTests: XCTestCase {
    func testMarkdownHeadingBecomesTitle() {
        let note = TransferService.markdownNote(from: Data("# Shopping\n\n- milk\n- bread\n".utf8))
        XCTAssertEqual(note?.title, "Shopping")
        XCTAssertEqual(note?.body, "- milk\n- bread")
    }

    func testMarkdownDeeperHeadingLevel() {
        let note = TransferService.markdownNote(from: Data("### Deep title\nbody line\n".utf8))
        XCTAssertEqual(note?.title, "Deep title")
        XCTAssertEqual(note?.body, "body line")
    }

    func testMarkdownWithoutHeadingKeepsBody() {
        let note = TransferService.markdownNote(from: Data("just text\nsecond line\n".utf8))
        XCTAssertEqual(note?.title, "")
        XCTAssertEqual(note?.body, "just text\nsecond line")
    }

    func testMarkdownEmptyFileIsRejected() {
        XCTAssertNil(TransferService.markdownNote(from: Data("   \n\n".utf8)))
        XCTAssertNil(TransferService.markdownNote(from: Data()))
    }

    func testPlainTextFirstLineBecomesTitle() {
        let note = TransferService.plainTextNote(from: Data("\nMeeting notes\n\nAction items here\n".utf8))
        XCTAssertEqual(note?.title, "Meeting notes")
        XCTAssertEqual(note?.body, "Action items here")
    }

    func testPlainTextEmptyFileIsRejected() {
        XCTAssertNil(TransferService.plainTextNote(from: Data("\n  \n".utf8)))
    }

    func testMarkdownExportImportRoundTrip() throws {
        // D7: export writes "# title\n\nbody"; import must reproduce both.
        let original = Note(title: "Round trip", body: "line one\nline two")
        let exported = TransferService.markdown(original)
        let imported = TransferService.markdownNote(from: Data(exported.utf8))
        XCTAssertEqual(imported?.title, original.title)
        XCTAssertEqual(imported?.body, original.body)
    }
}
