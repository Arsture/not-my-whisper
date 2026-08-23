import XCTest
@testable import Whispree

@MainActor
final class AppStateSTTLifecycleTests: XCTestCase {
    private static let suiteName = "com.whispree.app.tests.AppStateSTTLifecycle"
    private var defaults: UserDefaults?

    private var store: UserDefaults {
        guard let defaults else {
            preconditionFailure("AppStateSTTLifecycleTests store accessed before setUp")
        }
        return defaults
    }

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: Self.suiteName)
        store.removePersistentDomain(forName: Self.suiteName)
    }

    override func tearDown() {
        defaults?.removePersistentDomain(forName: Self.suiteName)
        defaults = nil
        super.tearDown()
    }

    func testConcurrentSameConfigurationCreatesOneProvider() async {
        let settings = makeSettings()
        settings.groqApiKey = "first-key"
        var providers: [TestSTTProvider] = []
        let appState = AppState(settings: settings) { _, _ in
            let provider = TestSTTProvider(setupDelayNanoseconds: 200_000_000)
            providers.append(provider)
            return provider
        }

        let firstLoad = Task { @MainActor in
            await appState.switchSTTProvider(to: .groq)
        }
        while providers.isEmpty {
            await Task.yield()
        }
        let duplicateLoad = Task { @MainActor in
            await appState.switchSTTProvider(to: .groq)
        }

        await duplicateLoad.value
        await firstLoad.value

        XCTAssertEqual(providers.count, 1)
        XCTAssertEqual(providers[0].setupCount, 1)
        assertProvider(appState.sttProvider, is: providers[0])
        XCTAssertEqual(appState.whisperModelState, .ready)
    }

    func testChangedConfigurationReloadsSameProviderType() async {
        let settings = makeSettings()
        settings.groqApiKey = "first-key"
        var providers: [TestSTTProvider] = []
        let appState = AppState(settings: settings) { _, _ in
            let provider = TestSTTProvider()
            providers.append(provider)
            return provider
        }

        await appState.switchSTTProvider(to: .groq)
        await appState.switchSTTProvider(to: .groq)
        XCTAssertEqual(providers.count, 1)

        settings.groqApiKey = "second-key"
        await appState.switchSTTProvider(to: .groq)

        XCTAssertEqual(providers.count, 2)
        XCTAssertEqual(providers[0].teardownCount, 1)
        assertProvider(appState.sttProvider, is: providers[1])
    }

    func testStaleLoadCannotReplaceNewerConfiguration() async {
        let settings = makeSettings()
        settings.groqApiKey = "first-key"
        var providers: [TestSTTProvider] = []
        let appState = AppState(settings: settings) { _, _ in
            let delay: UInt64 = providers.isEmpty ? 200_000_000 : 0
            let provider = TestSTTProvider(setupDelayNanoseconds: delay)
            providers.append(provider)
            return provider
        }

        let staleLoad = Task { @MainActor in
            await appState.switchSTTProvider(to: .groq)
        }
        while providers.isEmpty {
            await Task.yield()
        }

        settings.groqApiKey = "second-key"
        await appState.switchSTTProvider(to: .groq)
        await staleLoad.value

        XCTAssertEqual(providers.count, 2)
        XCTAssertEqual(providers[0].teardownCount, 1)
        assertProvider(appState.sttProvider, is: providers[1])
        XCTAssertEqual(appState.whisperModelState, .ready)
    }

    func testFailedCandidateIsTornDownAndCanRetry() async {
        let settings = makeSettings()
        settings.groqApiKey = "test-key"
        var providers: [TestSTTProvider] = []
        let appState = AppState(settings: settings) { _, _ in
            let provider = TestSTTProvider(shouldFailSetup: providers.isEmpty)
            providers.append(provider)
            return provider
        }

        await appState.switchSTTProvider(to: .groq)

        XCTAssertEqual(providers.count, 1)
        XCTAssertEqual(providers[0].teardownCount, 1)
        XCTAssertNil(appState.sttProvider)
        guard case .error = appState.whisperModelState else {
            return XCTFail("Expected failed setup to publish an error state")
        }

        await appState.switchSTTProvider(to: .groq)

        XCTAssertEqual(providers.count, 2)
        assertProvider(appState.sttProvider, is: providers[1])
        XCTAssertEqual(appState.whisperModelState, .ready)
    }

    private func makeSettings() -> AppSettings {
        AppSettings(store: store, migrateHotkeys: false)
    }

    private func assertProvider(
        _ actual: (any STTProvider)?,
        is expected: TestSTTProvider,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard let actual else {
            return XCTFail("Expected an active STT provider", file: file, line: line)
        }
        XCTAssertEqual(ObjectIdentifier(actual), ObjectIdentifier(expected), file: file, line: line)
    }
}

private final class TestSTTProvider: STTProvider, @unchecked Sendable {
    let name = "Test STT"
    let isAvailable = true

    private let lock = NSLock()
    private let setupDelayNanoseconds: UInt64
    private let shouldFailSetup: Bool
    private var ready = false
    private var _setupCount = 0
    private var _teardownCount = 0

    init(
        setupDelayNanoseconds: UInt64 = 0,
        shouldFailSetup: Bool = false
    ) {
        self.setupDelayNanoseconds = setupDelayNanoseconds
        self.shouldFailSetup = shouldFailSetup
    }

    var setupCount: Int {
        withLock { _setupCount }
    }

    var teardownCount: Int {
        withLock { _teardownCount }
    }

    func validate() -> ProviderValidation {
        withLock { ready ? .valid : .invalid("not ready") }
    }

    func setup() async throws {
        withLock { _setupCount += 1 }
        if setupDelayNanoseconds > 0 {
            try await Task.sleep(nanoseconds: setupDelayNanoseconds)
        }
        if shouldFailSetup {
            throw STTError.modelNotLoaded
        }
        withLock { ready = true }
    }

    func teardown() async {
        withLock {
            ready = false
            _teardownCount += 1
        }
    }

    func transcribe(
        audioBuffer: [Float],
        language: SupportedLanguage?,
        promptTokens: [Int]?
    ) async throws -> TranscriptionResult {
        TranscriptionResult(text: "", segments: [], language: nil)
    }

    func transcribeStream(
        audioBuffer: [Float],
        language: SupportedLanguage?,
        promptTokens: [Int]?
    ) -> AsyncStream<PartialTranscription> {
        AsyncStream { $0.finish() }
    }

    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}
