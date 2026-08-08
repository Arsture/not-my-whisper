import Foundation

/// Stable identifier for a queued dictation job.
typealias DictationJobID = UUID

/// Resource backing for recorded audio. G001 keeps in-memory payloads; later
/// resource-pressure work can spill to a temp URL without changing queue logic.
enum DictationAudioPayload: Equatable {
    case memory([Float])
    case tempFile(URL)

    var isEmpty: Bool {
        switch self {
        case let .memory(samples): samples.isEmpty
        case .tempFile: false
        }
    }

    var samples: [Float]? {
        switch self {
        case let .memory(samples): samples
        case .tempFile: nil
        }
    }
}

enum DictationResourceState: Equatable {
    case normal
    case warning(String)
    case spilled(URL)
}

/// Immutable capture/settings snapshot. A queued job must use this snapshot even
/// if the user changes settings or providers while it waits or processes.
struct DictationJobSnapshot: Equatable {
    let sttProviderType: STTProviderType
    let llmProviderType: LLMProviderType
    let llmEnabled: Bool
    let sttProviderConfigKey: String?
    let llmProviderConfigKey: String?
    let correctionMode: CorrectionMode
    let customPrompt: String?
    let language: SupportedLanguage
    let glossary: [String]
    let domainWordSets: [DomainWordSet]
    let correctionMappings: [CorrectionMapping]
    let screenshotContextEnabled: Bool
    let screenshotPasteEnabled: Bool
    let hasCompletedOnboarding: Bool
    let vadEnabled: Bool

    init(
        sttProviderType: STTProviderType,
        llmProviderType: LLMProviderType,
        llmEnabled: Bool = true,
        sttProviderConfigKey: String? = nil,
        llmProviderConfigKey: String? = nil,
        correctionMode: CorrectionMode,
        customPrompt: String? = nil,
        language: SupportedLanguage,
        glossary: [String] = [],
        domainWordSets: [DomainWordSet] = [],
        correctionMappings: [CorrectionMapping] = [],
        screenshotContextEnabled: Bool = false,
        screenshotPasteEnabled: Bool = false,
        hasCompletedOnboarding: Bool = true,
        vadEnabled: Bool = true
    ) {
        self.sttProviderType = sttProviderType
        self.llmProviderType = llmProviderType
        self.llmEnabled = llmEnabled
        self.sttProviderConfigKey = sttProviderConfigKey
        self.llmProviderConfigKey = llmProviderConfigKey
        self.correctionMode = correctionMode
        self.customPrompt = customPrompt
        self.language = language
        self.glossary = glossary
        self.domainWordSets = domainWordSets
        self.correctionMappings = correctionMappings
        self.screenshotContextEnabled = screenshotContextEnabled
        self.screenshotPasteEnabled = screenshotPasteEnabled
        self.hasCompletedOnboarding = hasCompletedOnboarding
        self.vadEnabled = vadEnabled
    }
}

enum DictationJobStatus: Equatable {
    case queued
    case transcribing
    case correcting
    case readyForDelivery
    case awaitingScreenshotSelection
    case delivering
    case delivered
    case copiedToClipboard
    case failed(String)
    case canceled
    case skipped

    var isTerminal: Bool {
        switch self {
        case .delivered, .copiedToClipboard, .failed, .canceled, .skipped:
            true
        default:
            false
        }
    }

    var isProcessing: Bool {
        switch self {
        case .queued, .transcribing, .correcting:
            true
        default:
            false
        }
    }

    var isDeliverable: Bool {
        switch self {
        case .readyForDelivery, .awaitingScreenshotSelection:
            true
        default:
            false
        }
    }
}

struct DictationJob {
    let id: DictationJobID
    let sequence: Int
    let createdAt: Date
    let snapshot: DictationJobSnapshot
    var audio: DictationAudioPayload
    var resourceState: DictationResourceState
    var targetContext: ExternalContext?
    var screenshots: [CapturedScreenshot]
    var selectedImages: [Data]
    var transcribedText: String
    var correctedText: String
    var status: DictationJobStatus
    var ownsSTTPermit: Bool
    var ownsLLMPermit: Bool

    /// Whether this job must go through screenshot review before insertion.
    /// This is queue truth, not a UI decision: delivery admission reads it synchronously
    /// so the projected UI state can never disagree with what `deliver()` will do.
    var needsScreenshotSelection: Bool {
        snapshot.hasCompletedOnboarding && snapshot.screenshotPasteEnabled && !screenshots.isEmpty
    }

    init(
        id: DictationJobID = UUID(),
        sequence: Int,
        createdAt: Date = Date(),
        snapshot: DictationJobSnapshot,
        audio: DictationAudioPayload,
        resourceState: DictationResourceState = .normal,
        targetContext: ExternalContext? = nil,
        screenshots: [CapturedScreenshot] = []
    ) {
        self.id = id
        self.sequence = sequence
        self.createdAt = createdAt
        self.snapshot = snapshot
        self.audio = audio
        self.resourceState = resourceState
        self.targetContext = targetContext
        self.screenshots = screenshots
        self.selectedImages = []
        self.transcribedText = ""
        self.correctedText = ""
        self.status = .queued
        self.ownsSTTPermit = false
        self.ownsLLMPermit = false
    }
}

struct DictationQueueSnapshot: Equatable {
    let totalCount: Int
    let processingCount: Int
    let deliveryReadyCount: Int
    let terminalCount: Int
    let isRecordingActive: Bool
    let activeDeliverySequence: Int?
    let foregroundJobSequence: Int?

    static let empty = DictationQueueSnapshot(
        totalCount: 0,
        processingCount: 0,
        deliveryReadyCount: 0,
        terminalCount: 0,
        isRecordingActive: false,
        activeDeliverySequence: nil,
        foregroundJobSequence: nil
    )

    var activeCount: Int {
        totalCount - terminalCount
    }
}

struct DictationProviderConcurrencyPolicy: Equatable {
    let sttLimit: Int
    let llmLimit: Int

    init(sttLimit: Int, llmLimit: Int) {
        self.sttLimit = max(1, sttLimit)
        self.llmLimit = max(1, llmLimit)
    }

    static func limits(sttProvider: STTProviderType, llmProvider: LLMProviderType) -> Self {
        let sttLimit: Int = switch sttProvider {
        case .whisperKit, .mlxAudio: 1
        case .groq: 2
        }

        let llmLimit: Int = switch llmProvider {
        case .none: Int.max / 4
        case .local: 1
        case .openai, .groq: 2
        }

        return Self(sttLimit: sttLimit, llmLimit: llmLimit)
    }
}

/// Test-visible queue state machine. The coordinator will own one instance and
/// attach real provider tasks in later stories.
@MainActor
final class DictationQueueState {
    private(set) var jobs: [DictationJob] = []
    private(set) var isRecordingActive = false
    private(set) var activeDeliveryJobID: DictationJobID?

    private var nextSequence = 1
    private var activeSTTPermitsByProvider: [STTProviderType: Int] = [:]
    private var activeLLMPermitsByProvider: [LLMProviderType: Int] = [:]
    private let terminalRetentionLimit = 20

    var snapshot: DictationQueueSnapshot {
        DictationQueueSnapshot(
            totalCount: jobs.count,
            processingCount: jobs.filter(\.status.isProcessing).count,
            deliveryReadyCount: jobs.filter(\.status.isDeliverable).count,
            terminalCount: jobs.filter(\.status.isTerminal).count,
            isRecordingActive: isRecordingActive,
            activeDeliverySequence: activeDeliveryJobID.flatMap(sequenceForJob),
            foregroundJobSequence: foregroundJobID.flatMap(sequenceForJob)
        )
    }

    var foregroundJobID: DictationJobID? {
        if let activeDeliveryJobID { return activeDeliveryJobID }
        return jobs.first { !$0.status.isTerminal }?.id
    }

    func setRecordingActive(_ active: Bool) {
        isRecordingActive = active
    }

    @discardableResult
    func enqueue(
        snapshot: DictationJobSnapshot,
        audio: DictationAudioPayload,
        targetContext: ExternalContext? = nil,
        screenshots: [CapturedScreenshot] = [],
        resourceState: DictationResourceState = .normal
    ) -> DictationJobID? {
        guard !audio.isEmpty else { return nil }
        let job = DictationJob(
            sequence: nextSequence,
            snapshot: snapshot,
            audio: audio,
            resourceState: resourceState,
            targetContext: targetContext,
            screenshots: screenshots
        )
        nextSequence += 1
        jobs.append(job)
        return job.id
    }

    func job(id: DictationJobID) -> DictationJob? {
        jobs.first { $0.id == id }
    }

    func nonTerminalJobs() -> [DictationJob] {
        jobs.filter { !$0.status.isTerminal }.sorted { $0.sequence < $1.sequence }
    }

    func transcribingJobIDs() -> [DictationJobID] {
        jobs.filter { $0.status == .transcribing }.map(\.id)
    }

    func correctingJobIDs() -> [DictationJobID] {
        jobs.filter { $0.status == .correcting }.map(\.id)
    }

    func sequenceForJob(_ id: DictationJobID) -> Int? {
        job(id: id)?.sequence
    }

    func startNextSTT() -> DictationJobID? {
        guard let index = jobs.firstIndex(where: { job in
            guard job.status == .queued else { return false }
            let limit = DictationProviderConcurrencyPolicy.limits(
                sttProvider: job.snapshot.sttProviderType,
                llmProvider: job.snapshot.llmProviderType
            ).sttLimit
            return (activeSTTPermitsByProvider[job.snapshot.sttProviderType] ?? 0) < limit
        }) else { return nil }
        activeSTTPermitsByProvider[jobs[index].snapshot.sttProviderType, default: 0] += 1
        jobs[index].ownsSTTPermit = true
        jobs[index].status = .transcribing
        return jobs[index].id
    }

    func completeSTT(jobID: DictationJobID, text: String, requiresLLM: Bool) {
        guard let index = jobs.firstIndex(where: { $0.id == jobID }) else { return }
        guard !jobs[index].status.isTerminal else { return }
        releaseSTTPermitIfNeeded(index: index)
        jobs[index].transcribedText = text
        jobs[index].status = requiresLLM ? .correcting : .readyForDelivery
    }

    func failSTT(jobID: DictationJobID, message: String) {
        markTerminal(jobID: jobID, status: .failed(message))
    }

    func startNextLLM() -> DictationJobID? {
        guard let index = jobs.firstIndex(where: { job in
            guard job.status == .correcting, !job.ownsLLMPermit else { return false }
            let limit = DictationProviderConcurrencyPolicy.limits(
                sttProvider: job.snapshot.sttProviderType,
                llmProvider: job.snapshot.llmProviderType
            ).llmLimit
            return (activeLLMPermitsByProvider[job.snapshot.llmProviderType] ?? 0) < limit
        }) else { return nil }
        activeLLMPermitsByProvider[jobs[index].snapshot.llmProviderType, default: 0] += 1
        jobs[index].ownsLLMPermit = true
        return jobs[index].id
    }

    func completeLLM(jobID: DictationJobID, correctedText: String?) {
        guard let index = jobs.firstIndex(where: { $0.id == jobID }) else { return }
        guard !jobs[index].status.isTerminal else { return }
        releaseLLMPermitIfNeeded(index: index)
        jobs[index].correctedText = correctedText ?? ""
        jobs[index].status = .readyForDelivery
    }

    func setSelectedImages(jobID: DictationJobID, images: [Data]) {
        guard let index = jobs.firstIndex(where: { $0.id == jobID }) else { return }
        jobs[index].selectedImages = images
    }

    func updateTargetContext(jobID: DictationJobID, targetContext: ExternalContext) {
        guard let index = jobs.firstIndex(where: { $0.id == jobID }) else { return }
        guard !jobs[index].status.isTerminal else { return }
        jobs[index].targetContext = targetContext
    }

    func failLLMFallbackToRaw(jobID: DictationJobID) {
        completeLLM(jobID: jobID, correctedText: nil)
    }

    func nextDeliveryHeadID() -> DictationJobID? {
        jobs
            .filter { !$0.status.isTerminal }
            .sorted { $0.sequence < $1.sequence }
            .first?
            .id
    }

    func startDeliveryIfPossible() -> DictationJobID? {
        guard !isRecordingActive, activeDeliveryJobID == nil,
              let headID = nextDeliveryHeadID(),
              let index = jobs.firstIndex(where: { $0.id == headID }),
              jobs[index].status.isDeliverable
        else { return nil }
        activeDeliveryJobID = headID
        // Screenshot review is entered here, synchronously, and not later inside the
        // delivery task. Callers project UI state from queue truth immediately after this
        // returns; if the job sat in `.delivering` until the async task body ran, the
        // projection would publish "inserting" first and tear the selection panel down
        // before the user could ever use it.
        jobs[index].status = jobs[index].needsScreenshotSelection
            ? .awaitingScreenshotSelection
            : .delivering
        return headID
    }

    /// Screenshot review finished for the active delivery job — proceed to insertion.
    func beginDeliveryAfterScreenshotSelection(jobID: DictationJobID) {
        guard let index = jobs.firstIndex(where: { $0.id == jobID }),
              activeDeliveryJobID == jobID,
              jobs[index].status == .awaitingScreenshotSelection
        else { return }
        jobs[index].status = .delivering
    }

    func pauseActiveDeliveryForRecording(jobID: DictationJobID) {
        // `.awaitingScreenshotSelection` must be accepted here: starting a new recording
        // while the selection panel is open goes through this path, and the job is not in
        // `.delivering` at that point.
        guard let index = jobs.firstIndex(where: { $0.id == jobID }),
              activeDeliveryJobID == jobID,
              jobs[index].status == .delivering || jobs[index].status == .awaitingScreenshotSelection
        else { return }
        activeDeliveryJobID = nil
        jobs[index].selectedImages = []
        jobs[index].status = .readyForDelivery
    }

    func completeDelivery(jobID: DictationJobID, copiedFallback: Bool = false) {
        markTerminal(jobID: jobID, status: copiedFallback ? .copiedToClipboard : .delivered)
    }

    func skipJob(jobID: DictationJobID) {
        markTerminal(jobID: jobID, status: .skipped)
    }

    func cancelJob(jobID: DictationJobID) {
        markTerminal(jobID: jobID, status: .canceled)
    }

    private func markTerminal(jobID: DictationJobID, status: DictationJobStatus) {
        guard let index = jobs.firstIndex(where: { $0.id == jobID }) else { return }
        guard !jobs[index].status.isTerminal else { return }
        releaseSTTPermitIfNeeded(index: index)
        releaseLLMPermitIfNeeded(index: index)
        cleanupHeavyPayloads(index: index)
        jobs[index].selectedImages = []
        jobs[index].status = status
        if activeDeliveryJobID == jobID {
            activeDeliveryJobID = nil
        }
        pruneOldTerminalJobsIfNeeded()
    }

    private func releaseSTTPermitIfNeeded(index: Int) {
        guard jobs[index].ownsSTTPermit else { return }
        jobs[index].ownsSTTPermit = false
        let provider = jobs[index].snapshot.sttProviderType
        activeSTTPermitsByProvider[provider] = max(0, (activeSTTPermitsByProvider[provider] ?? 0) - 1)
    }

    private func releaseLLMPermitIfNeeded(index: Int) {
        guard jobs[index].ownsLLMPermit else { return }
        jobs[index].ownsLLMPermit = false
        let provider = jobs[index].snapshot.llmProviderType
        activeLLMPermitsByProvider[provider] = max(0, (activeLLMPermitsByProvider[provider] ?? 0) - 1)
    }

    private func cleanupHeavyPayloads(index: Int) {
        if case let .tempFile(url) = jobs[index].audio {
            try? FileManager.default.removeItem(at: url)
        }
        jobs[index].audio = .memory([])
        jobs[index].targetContext = nil
        jobs[index].screenshots = []
        jobs[index].selectedImages = []
    }

    private func pruneOldTerminalJobsIfNeeded() {
        let terminalJobs = jobs.filter(\.status.isTerminal)
        guard terminalJobs.count > terminalRetentionLimit else { return }
        let removableSequences = Set(
            terminalJobs
                .sorted { $0.sequence < $1.sequence }
                .prefix(terminalJobs.count - terminalRetentionLimit)
                .map(\.sequence)
        )
        jobs.removeAll { removableSequences.contains($0.sequence) }
    }
}
