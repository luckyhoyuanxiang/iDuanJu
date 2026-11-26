import XCTest
import AVFoundation
import AVKit
@testable import STV

@MainActor final class PlayerTransportTests: XCTestCase {
    private var oldAutoNext: Any?
    override func setUp() async throws {
        await MainActor.run { oldAutoNext = UserDefaults.standard.object(forKey:"stv.player.autoNext") }
    }
    override func tearDown() async throws {
        await MainActor.run { UserDefaults.standard.set(oldAutoNext,forKey:"stv.player.autoNext") }
    }
    private func coordinator(_ engine: TestPlayerEngine) -> PlaybackCoordinator {
        let id = "transport-" + UUID().uuidString
        let series = HGSeries(source: .telegram, seriesId: id, title: "transport", cover: "")
        let co = PlaybackCoordinator(series: series, engine: engine, resolve: { _ in .file(URL(fileURLWithPath: "/fixture.mp4")) })
        co.detail = HGSeriesDetail(source: .telegram, seriesId: id, title: "transport", author: nil, actors: [], onlineTime: 0, totalEps: 3,
            episodes: (1...3).map { HGEpisode(ep: $0, vid: "ep\($0)", duration: 60, title: "episode") })
        co.autoNext = true
        co.start()
        return co
    }

    private func ready(_ co: PlaybackCoordinator, _ index: Int) async throws {
        for _ in 0..<200 {
            if co.readyIndex == index { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("episode \(index) never became ready")
    }

    func testTeardownIsIdempotentButAllowsANewPlaybackLifecycle() async throws {
        let e = TestPlayerEngine(); let co = coordinator(e)
        defer { co.teardown() }
        co.select(0); try await ready(co, 0)
        co.teardown()
        co.teardown()
        XCTAssertEqual(e.stopCount, 1, "exit and onDisappear must not stop the same engine twice")

        co.start()
        co.teardown()
        XCTAssertEqual(e.stopCount, 2, "a later mounted lifecycle must still clean up")
    }

    func testInternalPauseDuringEpisodeReplacementDoesNotCancelAutoplay() async throws {
        let e = TestPlayerEngine(); let co = coordinator(e)
        defer { co.teardown() }
        co.select(0); try await ready(co,0)
        XCTAssertFalse(e.isPaused)
        // The old item must pause while a new item is opened. Even a queued transport
        // callback in that interval must not overwrite the requested next-episode play.
        e.notifyInternalPause = true
        e.onEnded?()
        try await ready(co,1)
        XCTAssertEqual(co.current,1)
        XCTAssertFalse(e.isPaused)
        XCTAssertFalse(co.paused)
    }

    func testPiPPauseAndPlayRequestsRemainConsistentWhenReturningToApp() async throws {
        let e = TestPlayerEngine(); let co = coordinator(e)
        defer { co.teardown() }
        co.select(0); try await ready(co,0)
        co.didEnterBackground()
        e.onPlaybackRequested?(false)
        XCTAssertTrue(co.paused); XCTAssertTrue(e.isPaused)
        co.didBecomeActive()
        try await Task.sleep(for: .milliseconds(500))
        XCTAssertTrue(e.isPaused,"foreground must respect the PiP pause button")
        e.onPlaybackRequested?(true)
        XCTAssertFalse(co.paused); XCTAssertFalse(e.isPaused)
    }

    func testOldPiPStopDoesNotTearDownTheReplacementEpisode() async throws {
        let e = TestPlayerEngine(); e.exposePiP = true
        let co = coordinator(e); defer { co.teardown() }
        co.select(0); try await ready(co,0)
        guard let old = e.lastPiP else { throw XCTSkip("PiP controller unavailable in this simulator") }
        co.pictureInPictureControllerWillStartPictureInPicture(old)
        co.didEnterBackground()
        e.replacePiPOnLoad = true
        e.onEnded?(); try await ready(co,1)
        co.pictureInPictureControllerDidStopPictureInPicture(old)
        XCTAssertTrue(e.pictureIsActive,"stopping the old window must not release the replacement renderer")
        XCTAssertFalse(co.paused); XCTAssertFalse(e.isPaused)
        co.didBecomeActive()
        XCTAssertFalse(e.pictureIsActive,"foreground inline playback no longer needs the handover flag")
    }

    func testInterruptedIconShowsPausedAndOneExplicitPlayRecovers() async throws {
        let e = TestPlayerEngine(); let co = coordinator(e)
        defer { co.teardown() }
        co.select(0); try await ready(co,0)
        e.isPaused = true
        NotificationCenter.default.post(name: AVAudioSession.interruptionNotification, object: AVAudioSession.sharedInstance(),
            userInfo: [AVAudioSessionInterruptionTypeKey: AVAudioSession.InterruptionType.began.rawValue])
        XCTAssertTrue(co.paused)
        co.didEnterBackground(); co.didBecomeActive()
        XCTAssertTrue(co.paused,"an unended interruption must not display playing")
        co.togglePause()
        XCTAssertFalse(co.paused); XCTAssertFalse(e.isPaused)
    }

    func testPauseDuringLoadWinsOverAutoplay() async throws {
        let e = TestPlayerEngine(); e.loadDelay = .milliseconds(100)
        let co = coordinator(e); defer { co.teardown() }
        co.select(0); co.togglePause()
        try await ready(co,0)
        XCTAssertTrue(co.paused); XCTAssertTrue(e.isPaused)
    }

    func testExplicitPlayDuringInterruptedLoadIsAppliedWhenReady() async throws {
        let e = TestPlayerEngine(); e.loadDelay = .milliseconds(100)
        let co = coordinator(e); defer { co.teardown() }
        co.select(0)
        NotificationCenter.default.post(name: AVAudioSession.interruptionNotification, object: AVAudioSession.sharedInstance(),
            userInfo: [AVAudioSessionInterruptionTypeKey: AVAudioSession.InterruptionType.began.rawValue])
        XCTAssertTrue(co.paused)
        co.togglePause()
        try await ready(co,0)
        XCTAssertFalse(e.isPaused); XCTAssertFalse(co.paused)
    }

    func testForegroundRecoveryDoesNotUndoNewPause() async throws {
        let e = TestPlayerEngine(); let co = coordinator(e)
        defer { co.teardown() }
        co.select(0); try await ready(co,0)
        co.didEnterBackground(); e.isPaused = true; co.didBecomeActive()
        XCTAssertFalse(e.isPaused)
        co.togglePause()
        try await Task.sleep(for: .milliseconds(500))
        XCTAssertTrue(e.isPaused); XCTAssertTrue(co.paused)
    }

    func testLateEndNotificationDoesNotOverrideExplicitPause() async throws {
        let e = TestPlayerEngine(); let co = coordinator(e)
        defer { co.teardown() }
        co.select(0); try await ready(co,0)
        co.togglePause(); e.onEnded?()
        XCTAssertEqual(co.current,0)
        XCTAssertTrue(co.paused)
    }

    func testFailedPlaybackShowsPlayAndTheButtonRetries() async throws {
        let e = TestPlayerEngine(); e.failLoad = true
        let co = coordinator(e); defer { co.teardown() }
        co.select(0)
        for _ in 0..<200 where co.errors[0] == nil { try await Task.sleep(for:.milliseconds(10)) }
        XCTAssertNotNil(co.errors[0]); XCTAssertTrue(co.paused)
        e.failLoad = false
        co.togglePause(); try await ready(co,0)
        XCTAssertNil(co.errors[0]); XCTAssertFalse(e.isPaused); XCTAssertFalse(co.paused)
    }

    /// Two lines of three episodes; the resolver serves the same fixture for every index.
    private func multiLine(_ engine: TestPlayerEngine) -> PlaybackCoordinator {
        let co = coordinator(engine)
        func eps(_ p: String) -> [HGEpisode] { (1...3).map { HGEpisode(ep: $0, vid: "\(p)\($0)", duration: 60, title: "第\($0)集") } }
        co.detail?.lines = [HGPlayLine(id: "a", name: "甲", episodes: eps("a")), HGPlayLine(id: "b", name: "乙", episodes: eps("b")),
                            HGPlayLine(id: "c", name: "丙", episodes: eps("c")), HGPlayLine(id: "d", name: "丁", episodes: eps("d")),
                            HGPlayLine(id: "e", name: "戊", episodes: eps("e"))]
        return co
    }

    func testDeadLineFallsThroughToTheNextOneAndKeepsTheEpisode() async throws {
        let e = TestPlayerEngine(); e.failLoads = 1
        let co = multiLine(e); defer { co.teardown() }
        co.select(1); try await ready(co, 1)
        XCTAssertEqual(co.lineIndex, 1)
        XCTAssertEqual(co.episodes[1].vid, "b2")
        XCTAssertNotNil(co.notice)
        XCTAssertNil(co.errors[1]); XCTAssertFalse(co.paused)
    }

    func testAutomaticLineSwitchesAreBoundedAndEndInAnError() async throws {
        let e = TestPlayerEngine(); e.failLoad = true
        let co = multiLine(e); defer { co.teardown() }
        co.select(0)
        for _ in 0..<300 where co.errors[0] == nil { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertNotNil(co.errors[0])
        XCTAssertEqual(co.lineIndex, PlaybackCoordinator.maxAutoSwitches, "three automatic switches, then stop")
        // 重试 starts over with every line allowed again.
        e.failLoad = false
        co.retry(0); try await ready(co, 0)
        XCTAssertNil(co.errors[0])
    }

    func testManualLineSwitchKeepsEpisodeAndPosition() async throws {
        let e = TestPlayerEngine()
        let co = multiLine(e); defer { co.teardown() }
        co.select(2); try await ready(co, 2)
        e.currentTime = 33
        try await Task.sleep(for: .milliseconds(600))   // let a tick see the frame
        co.selectLine(2); try await ready(co, 2)
        XCTAssertEqual(co.current, 2)
        XCTAssertEqual(co.episodes[2].vid, "c3")
        XCTAssertEqual(e.lastStart ?? 0, 33, accuracy: 0.5)
    }

    func testLiveListIgnoresTimelineAndReconnectsWhenItEnds() async throws {
        let e = TestPlayerEngine(); e.duration = 0
        let co = coordinator(e); defer { co.teardown() }
        co.detail?.isLive = true
        co.select(0); try await ready(co, 0)
        e.currentTime = 5
        co.seek(fraction: 0.5)
        XCTAssertEqual(e.currentTime, 5, "live has no timeline")
        let loads = e.loads
        e.onEnded?()   // a live source that ends dropped its connection: same channel, not the next one
        for _ in 0..<200 where e.loads == loads { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(e.loads, loads + 1)
        XCTAssertEqual(co.current, 0); XCTAssertNil(co.errors[0])
    }

    func testSeekTargetIsShownUntilTheCoreArrives() async throws {
        let e = TestPlayerEngine(); e.holdSeeks = true
        let co = coordinator(e); defer { co.teardown() }
        co.select(0); try await ready(co, 0)
        try await Task.sleep(for: .milliseconds(400))
        co.seek(fraction: 0.5)
        try await Task.sleep(for: .milliseconds(600))
        XCTAssertEqual(co.time, 30, accuracy: 0.1, "the knob must not jump back to the old position")
        e.currentTime = 30.2
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertEqual(co.time, 30.2, accuracy: 0.1)
    }

    func testNativeObserverIgnoresExpectedCommandsAndBackgroundPauses() async throws {
        let player = AVPlayer(); let observer = PlayerTransportObserver()
        var requests: [Bool] = []
        observer.bind(player); observer.acceptingRequests = true
        observer.onRequest = { requests.append($0) }
        func notify(_ reason: AVPlayer.RateDidChangeReason) {
            NotificationCenter.default.post(name: AVPlayer.rateDidChangeNotification, object: player,
                userInfo: [AVPlayer.rateDidChangeReasonKey: reason.rawValue])
        }
        observer.expectPaused(true); notify(.setRateCalled)
        observer.expectPaused(false); notify(.appBackgrounded)
        XCTAssertTrue(requests.isEmpty)
        // A paused player differing from our expected playing state is an external PiP pause.
        notify(.setRateCalled)
        XCTAssertEqual(requests,[false])
        notify(.setRateCalled)
        XCTAssertEqual(requests,[false],"duplicate callback must not toggle intent")
        observer.bind(nil)
    }
}

@MainActor private final class TestPlayerEngine: PlayerEngine {
    let kind: PlayerEngineKind = .avplayer
    var onFailed: ((Error?) -> Void)?
    var onEnded: (() -> Void)?
    var onPlaybackRequested: ((Bool) -> Void)?
    let surface = UIView()
    var currentTime: Double = 0
    var duration: Double = 60
    var bufferedUntil: Double = 60
    var presentationSize: CGSize = .init(width:640,height:360)
    var isWaiting = false
    var isPaused = true
    var muted = false
    var maxRate: Double = 3
    var fill = false
    var audioTracks: [MediaTrack] = []
    var selectedAudio: Int?
    var subtitleTracks: [MediaTrack] = []
    var selectedSubtitle: Int?
    var subtitleText: String?
    var avPlayer: AVPlayer? { nil }
    var exposePiP = false
    var replacePiPOnLoad = false
    var pictureIsActive = false
    var pipLayer = AVPlayerLayer()
    var lastPiP: AVPictureInPictureController?
    var pipIdentity: ObjectIdentifier? { exposePiP ? ObjectIdentifier(pipLayer) : nil }
    var routeLabel: String { "test" }
    var loadDelay: Duration = .zero
    var notifyInternalPause = false
    var failLoad = false
    /// Fail this many loads, then succeed.
    var failLoads = 0
    var loads = 0
    var stopCount = 0
    var lastStart: Double?
    /// Accept seeks without moving the clock (a core still fetching).
    var holdSeeks = false
    func supports(_ src: PlaybackCoordinator.Source) -> Bool { true }
    func load(_ src: PlaybackCoordinator.Source, stream: HGStream?, start: Double?, title: String) async throws {
        try await Task.sleep(for:loadDelay); isPaused = true
        loads += 1
        lastStart = start
        if failLoads > 0 { failLoads -= 1; throw URLError(.cannotOpenFile) }
        if failLoad { throw URLError(.cannotOpenFile) }
        if replacePiPOnLoad { pipLayer = AVPlayerLayer() }
    }
    func play(rate: Double) { isPaused = false }
    func pause() { isPaused = true; if notifyInternalPause { onPlaybackRequested?(false) } }
    func setRate(_ rate: Double) {}
    func seek(to seconds: Double) async { if !holdSeeks { currentTime = seconds } }
    func stop() { stopCount += 1; isPaused = true }
    func selectAudio(_ id: Int) {}
    func selectSubtitle(_ id: Int?) {}
    func tech(stream: HGStream?) async -> PlayerTech { PlayerTech() }
    func makePiPController() -> AVPictureInPictureController? {
        lastPiP = AVPictureInPictureController(playerLayer:pipLayer)
        return lastPiP
    }
    func setPiPActive(_ active: Bool) { pictureIsActive = active }
}
