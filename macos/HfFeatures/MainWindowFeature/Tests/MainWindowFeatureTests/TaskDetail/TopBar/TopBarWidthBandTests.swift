//
//  TopBarWidthBandTests.swift
//  MainWindowFeatureTests
//

import AppKit
import CoreGraphics
@testable import MainWindowFeature
import Observation
import SwiftUI
import Testing

// MARK: - TopBarWidthBandTests

@Suite struct TopBarWidthBandTests {

    @Test(arguments: [
        (CGFloat(0), TopBarWidthBand.narrow), (500, .narrow), (1099, .narrow), (1099.99, .narrow),
        (1100, .compact), (1101, .compact), (1279, .compact), (1279.99, .compact),
        (1280, .regular), (1281, .regular), (1599, .regular), (1599.99, .regular),
        (1600, .wide), (1601, .wide), (3000, .wide)
    ])
    func givenAWindowWidth_whenMappedToABand_thenTheEdgesFallAt1100And1280And1600(width: CGFloat, band: TopBarWidthBand) {
        // given / when
        let mapped = TopBarWidthBand(width: width)

        // then
        #expect(mapped == band)
    }

    @Test func givenANegativeWidth_whenMapped_thenItIsNarrow() {
        // given / when / then
        #expect(TopBarWidthBand(width: -1) == .narrow)
    }

    @Test func givenEachBand_whenAskedIfItIsNarrow_thenOnlyTheNarrowBandIs() {
        // given / when / then
        #expect(TopBarWidthBand.narrow.isNarrow)
        #expect(!TopBarWidthBand.compact.isNarrow)
        #expect(!TopBarWidthBand.regular.isNarrow)
        #expect(!TopBarWidthBand.wide.isNarrow)
    }

    @Test func givenTheNarrowThreshold_whenRead_thenItIsThePinsFrameRule() {
        // given / when / then
        #expect(TopBarWidthBand.narrowThreshold == 1100)
        #expect(TopBarWidthBand(width: TopBarWidthBand.narrowThreshold - 0.5).isNarrow)
        #expect(!TopBarWidthBand(width: TopBarWidthBand.narrowThreshold).isNarrow)
    }

    @Test(arguments: [
        (TopBarWidthBand.narrow, CGFloat(360)), (.compact, 360), (.regular, 440), (.wide, 560)
    ])
    func givenEachBand_whenItsCapIsRead_thenItMatchesTheTable(band: TopBarWidthBand, cap: CGFloat) {
        // given / when / then
        #expect(band.cap == cap)
    }

    @Test func givenWidthsWithinOneBand_whenMapped_thenTheBandIsUnchanged() {
        // given a resize that never leaves the band
        let widths: [CGFloat] = [1100, 1150, 1279, 1200, 1100]

        // when
        let bands = Set(widths.map { TopBarWidthBand(width: $0) })

        // then the shell's @State is only written on a crossing
        #expect(bands == [.compact])
    }
}

// MARK: - TopBarLayoutStateTests

@MainActor
@Suite struct TopBarLayoutStateTests {
    private final class Flag: @unchecked Sendable { var fired = false }

    @Test func givenANewState_whenRead_thenItStartsRegularAndUnmeasured() {
        // given / when
        let state = TopBarLayoutState()

        // then
        #expect(state.effectiveBand == .regular)
        #expect(state.measuredBand == nil)
        #expect(!state.isNarrow)
    }

    @Test func givenWidthsAcrossEveryEdge_whenMeasured_thenIsNarrowFlipsOnlyAtThe1100Edge() {
        // given
        let state = TopBarLayoutState()
        var flips = 0
        var last = state.isNarrow

        // when
        for width: CGFloat in [1000, 1099, 1100, 1279, 1280, 1599, 1600, 2000, 1599, 1100, 1099] {
            state.setBand(TopBarWidthBand(width: width))
            if state.isNarrow != last { flips += 1; last = state.isNarrow }
        }

        // then narrow, wide again at 1100, narrow again at 1099
        #expect(flips == 3)
        #expect(state.isNarrow)
    }

    @Test func givenCrossingsBetweenTheWiderBands_whenMeasured_thenIsNarrowReadersAreNotNotified() {
        // given
        let state = TopBarLayoutState()
        let flag = Flag()
        withObservationTracking { _ = state.isNarrow } onChange: { flag.fired = true }

        // when
        for band in [TopBarWidthBand.compact, .regular, .wide, .compact] { state.setBand(band) }

        // then
        #expect(!flag.fired)
    }

    @Test func givenACrossingIntoNarrow_whenMeasured_thenIsNarrowReadersAreNotified() {
        // given
        let state = TopBarLayoutState()
        let flag = Flag()
        withObservationTracking { _ = state.isNarrow } onChange: { flag.fired = true }

        // when
        state.setBand(.narrow)

        // then
        #expect(flag.fired)
    }

    @Test func givenARegularFirstMeasurement_whenRecorded_thenNothingIsWritten() {
        // given
        let state = TopBarLayoutState()
        let flag = Flag()
        withObservationTracking { _ = state.effectiveBand } onChange: { flag.fired = true }

        // when
        state.setBand(.regular)

        // then
        #expect(!flag.fired)
        #expect(state.measuredBand == .regular)
    }

    @Test func givenABand_whenTheSameBandIsRecordedAgain_thenNothingIsWritten() {
        // given
        let state = TopBarLayoutState()
        state.setBand(.compact)
        let flag = Flag()
        withObservationTracking { _ = state.effectiveBand } onChange: { flag.fired = true }

        // when
        state.setBand(.compact)

        // then
        #expect(!flag.fired)
    }

    @Test func givenABand_whenAnotherIsRecorded_thenReadersAreNotifiedOnce() {
        // given
        let state = TopBarLayoutState()
        let flag = Flag()
        withObservationTracking { _ = state.effectiveBand } onChange: { flag.fired = true }

        // when
        state.setBand(.narrow)

        // then
        #expect(flag.fired)
        #expect(state.effectiveBand == .narrow)
        #expect(state.isNarrow)
        #expect(state.measuredBand == .narrow)
    }

    @Test func givenResizesWithinOneBand_whenMeasured_thenReadersAreNotNotifiedAfterTheFirstCrossing() {
        // given
        let state = TopBarLayoutState()
        state.setBand(TopBarWidthBand(width: 1150))
        let flag = Flag()
        withObservationTracking { _ = state.effectiveBand } onChange: { flag.fired = true }

        // when
        for width: CGFloat in [1100, 1279, 1200, 1100] { state.setBand(TopBarWidthBand(width: width)) }

        // then
        #expect(!flag.fired)
    }
}

// MARK: - TopBarLayoutProbeTests

@MainActor
@Suite struct TopBarLayoutProbeTests {

    @Test func givenNoPass_whenAsked_thenMetaIsHidden() {
        // given / when
        let probe = TopBarLayoutProbe()

        // then
        #expect(!probe.hasSolved)
        #expect(probe.hidesMeta)
    }

    @Test func givenAPassThatKeptMeta_whenAsked_thenMetaIsShown() {
        // given
        let probe = TopBarLayoutProbe()

        // when
        probe.record(metaDropped: false)

        // then
        #expect(probe.hasSolved)
        #expect(!probe.hidesMeta)
    }

    @Test func givenAPassThatDroppedMeta_whenAsked_thenMetaIsHiddenUntilALaterPassKeepsIt() {
        // given
        let probe = TopBarLayoutProbe()

        // when
        probe.record(metaDropped: true)

        // then
        #expect(probe.hidesMeta)

        // when
        probe.record(metaDropped: false)

        // then
        #expect(!probe.hidesMeta)
    }
}
