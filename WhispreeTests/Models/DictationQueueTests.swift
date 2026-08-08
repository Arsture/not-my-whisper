import XCTest
@testable import Whispree

@MainActor
final class DictationQueueTests: XCTestCase {
    private func snapshot(
        stt: STTProviderType = .whisperKit,
        llm: LLMProviderType = .openai,
        glossary: [String] = ["API"],
        correctionMode: CorrectionMode = .standard,
        screenshotPasteEnabled: Bool = true
    ) -> DictationJobSnapshot {
        DictationJobSnapshot(
            sttProviderType: stt,
            llmProviderType: llm,
            correctionMode: correctionMode,
            customPrompt: nil,
            language: .korean,
            glossary: glossary,
            correctionMappings: [CorrectionMapping(from: "리엑트", to: "React")],
            screenshotContextEnabled: true,
            screenshotPasteEnabled: screenshotPasteEnabled
        )
    }

    private func makeScreenshot(imageData: Data = Data([1, 2, 3])) -> CapturedScreenshot {
        CapturedScreenshot(
            id: UUID(),
            timestamp: Date(),
            appName: "Test",
            appBundleIdentifier: "test.bundle",
            imageData: imageData
        )
    }

    func testEnqueueRecordingCreatesMonotonicSequenceNumbers() throws {
        let queue = DictationQueueState()
        let ids = (0..<3).compactMap { idx in
            queue.enqueue(snapshot: snapshot(), audio: .memory([Float(idx + 1)]))
        }

        XCTAssertEqual(ids.count, 3)
        XCTAssertEqual(ids.compactMap { queue.sequenceForJob($0) }, [1, 2, 3])
        XCTAssertEqual(queue.snapshot.totalCount, 3)
    }

    func testQueueAdmissionHasNoSmallFixedCap() {
        let queue = DictationQueueState()
        for idx in 0..<100 {
            XCTAssertNotNil(queue.enqueue(snapshot: snapshot(), audio: .memory([Float(idx + 1)])))
        }

        XCTAssertEqual(queue.snapshot.totalCount, 100)
    }

    func testEmptyRecordingIsDiscarded() {
        let queue = DictationQueueState()
        XCTAssertNil(queue.enqueue(snapshot: snapshot(), audio: .memory([])))
        XCTAssertEqual(queue.snapshot.totalCount, 0)
    }

    func testJobSnapshotFreezesSettingsAndProviders() throws {
        let queue = DictationQueueState()
        let original = snapshot(stt: .groq, llm: .openai, glossary: ["Swift"], correctionMode: .structured)
        let id = try XCTUnwrap(queue.enqueue(snapshot: original, audio: .memory([1])))

        // Simulate later settings changes by creating a different snapshot. The queued
        // job must still expose the original immutable capture/settings snapshot.
        _ = snapshot(stt: .mlxAudio, llm: .none, glossary: ["Changed"], correctionMode: .custom)
        let job = try XCTUnwrap(queue.job(id: id))
        XCTAssertEqual(job.snapshot.sttProviderType, .groq)
        XCTAssertEqual(job.snapshot.llmProviderType, .openai)
        XCTAssertEqual(job.snapshot.glossary, ["Swift"])
        XCTAssertEqual(job.snapshot.correctionMode, .structured)
    }

    func testResourcePressureMarksWarningWithoutDroppingJobs() throws {
        let queue = DictationQueueState()
        let id = try XCTUnwrap(queue.enqueue(
            snapshot: snapshot(),
            audio: .memory([1]),
            resourceState: .warning("memory pressure")
        ))

        XCTAssertEqual(queue.snapshot.totalCount, 1)
        XCTAssertEqual(queue.job(id: id)?.resourceState, .warning("memory pressure"))
    }

    func testProcessingRespectsSTTConcurrencyLimit() throws {
        let queue = DictationQueueState()
        _ = queue.enqueue(snapshot: snapshot(), audio: .memory([1]))
        _ = queue.enqueue(snapshot: snapshot(), audio: .memory([2]))

        XCTAssertNotNil(queue.startNextSTT())
        XCTAssertNil(queue.startNextSTT())
    }

    func testProcessingAllowsParallelSTTWhenLimitAllows() throws {
        let queue = DictationQueueState()
        _ = queue.enqueue(snapshot: snapshot(stt: .groq), audio: .memory([1]))
        _ = queue.enqueue(snapshot: snapshot(stt: .groq), audio: .memory([2]))

        XCTAssertNotNil(queue.startNextSTT())
        XCTAssertNotNil(queue.startNextSTT())
    }

    func testLLMRespectsSeparateConcurrencyLimit() throws {
        let queue = DictationQueueState()
        let id1 = try XCTUnwrap(queue.enqueue(snapshot: snapshot(llm: .local), audio: .memory([1])))
        let id2 = try XCTUnwrap(queue.enqueue(snapshot: snapshot(llm: .local), audio: .memory([2])))
        queue.completeSTT(jobID: id1, text: "one", requiresLLM: true)
        queue.completeSTT(jobID: id2, text: "two", requiresLLM: true)

        XCTAssertEqual(queue.startNextLLM(), id1)
        XCTAssertNil(queue.startNextLLM())
        queue.completeLLM(jobID: id1, correctedText: "one!")
        XCTAssertEqual(queue.startNextLLM(), id2)
    }

    func testProviderDefaults() {
        XCTAssertEqual(DictationProviderConcurrencyPolicy.limits(sttProvider: .whisperKit, llmProvider: .local), .init(sttLimit: 1, llmLimit: 1))
        XCTAssertEqual(DictationProviderConcurrencyPolicy.limits(sttProvider: .mlxAudio, llmProvider: .local).sttLimit, 1)
        XCTAssertEqual(DictationProviderConcurrencyPolicy.limits(sttProvider: .groq, llmProvider: .openai), .init(sttLimit: 2, llmLimit: 2))
    }

    func testDeliveryWaitsForEarlierJobWhenLaterFinishesFirst() throws {
        let queue = DictationQueueState()
        let first = try XCTUnwrap(queue.enqueue(snapshot: snapshot(), audio: .memory([1])))
        let second = try XCTUnwrap(queue.enqueue(snapshot: snapshot(), audio: .memory([2])))
        queue.completeSTT(jobID: second, text: "second", requiresLLM: false)

        XCTAssertNil(queue.startDeliveryIfPossible())

        queue.completeSTT(jobID: first, text: "first", requiresLLM: false)
        XCTAssertEqual(queue.startDeliveryIfPossible(), first)
    }

    func testDeliveryResumesFIFOAfterRecordingStops() throws {
        let queue = DictationQueueState()
        let first = try XCTUnwrap(queue.enqueue(snapshot: snapshot(), audio: .memory([1])))
        queue.completeSTT(jobID: first, text: "first", requiresLLM: false)
        queue.setRecordingActive(true)

        XCTAssertNil(queue.startDeliveryIfPossible())

        queue.setRecordingActive(false)
        XCTAssertEqual(queue.startDeliveryIfPossible(), first)
    }

    func testDeliverySerializesTextAndImageInsertion() throws {
        let queue = DictationQueueState()
        let first = try XCTUnwrap(queue.enqueue(snapshot: snapshot(), audio: .memory([1])))
        let second = try XCTUnwrap(queue.enqueue(snapshot: snapshot(), audio: .memory([2])))
        queue.completeSTT(jobID: first, text: "first", requiresLLM: false)
        queue.completeSTT(jobID: second, text: "second", requiresLLM: false)

        XCTAssertEqual(queue.startDeliveryIfPossible(), first)
        XCTAssertNil(queue.startDeliveryIfPossible())

        queue.completeDelivery(jobID: first)
        XCTAssertEqual(queue.startDeliveryIfPossible(), second)
    }

    func testDeliverySkipsCanceledEarlierJobAndContinuesFIFO() throws {
        let queue = DictationQueueState()
        let first = try XCTUnwrap(queue.enqueue(snapshot: snapshot(), audio: .memory([1])))
        let second = try XCTUnwrap(queue.enqueue(snapshot: snapshot(), audio: .memory([2])))
        queue.completeSTT(jobID: second, text: "second", requiresLLM: false)
        queue.cancelJob(jobID: first)

        XCTAssertEqual(queue.startDeliveryIfPossible(), second)
    }

    func testScreenshotSelectionWaitsUntilNoActiveRecordingAndCanSuspend() throws {
        let queue = DictationQueueState()
        let first = try XCTUnwrap(queue.enqueue(
            snapshot: snapshot(),
            audio: .memory([1]),
            screenshots: [makeScreenshot()]
        ))
        queue.completeSTT(jobID: first, text: "first", requiresLLM: false)
        queue.setRecordingActive(true)

        XCTAssertNil(queue.startDeliveryIfPossible())

        queue.setRecordingActive(false)
        XCTAssertEqual(queue.startDeliveryIfPossible(), first)
        XCTAssertEqual(queue.job(id: first)?.status, .awaitingScreenshotSelection)

        // Starting a new recording while the selection panel is open must release the
        // active delivery and requeue the job at the FIFO head.
        queue.setRecordingActive(true)
        queue.pauseActiveDeliveryForRecording(jobID: first)
        XCTAssertEqual(queue.job(id: first)?.status, .readyForDelivery)
        XCTAssertNil(queue.activeDeliveryJobID)

        queue.setRecordingActive(false)
        XCTAssertEqual(queue.startDeliveryIfPossible(), first)
        XCTAssertEqual(queue.job(id: first)?.status, .awaitingScreenshotSelection)
    }

    /// Regression (US-001): a job carrying screenshots must enter delivery as
    /// `.awaitingScreenshotSelection`, synchronously, so the projected UI state can never
    /// publish "inserting" ahead of the selection panel and make images unattachable.
    func testDeliveryWithScreenshotsAwaitsSelectionBeforeInserting() throws {
        let queue = DictationQueueState()
        let first = try XCTUnwrap(queue.enqueue(
            snapshot: snapshot(),
            audio: .memory([1]),
            screenshots: [makeScreenshot()]
        ))
        let second = try XCTUnwrap(queue.enqueue(snapshot: snapshot(), audio: .memory([2])))
        queue.completeSTT(jobID: first, text: "first", requiresLLM: false)
        queue.completeSTT(jobID: second, text: "second", requiresLLM: false)

        XCTAssertEqual(queue.startDeliveryIfPossible(), first)
        XCTAssertEqual(queue.job(id: first)?.status, .awaitingScreenshotSelection)
        XCTAssertEqual(queue.activeDeliveryJobID, first)
        // FIFO holds while the head job is under review.
        XCTAssertNil(queue.startDeliveryIfPossible())
        XCTAssertEqual(queue.job(id: second)?.status, .readyForDelivery)

        queue.setSelectedImages(jobID: first, images: [Data([9])])
        queue.beginDeliveryAfterScreenshotSelection(jobID: first)
        XCTAssertEqual(queue.job(id: first)?.status, .delivering)

        queue.completeDelivery(jobID: first)
        let delivered = try XCTUnwrap(queue.job(id: first))
        XCTAssertEqual(delivered.status, .delivered)
        XCTAssertTrue(delivered.screenshots.isEmpty)
        XCTAssertEqual(queue.startDeliveryIfPossible(), second)
        XCTAssertEqual(queue.job(id: second)?.status, .delivering)
    }

    func testDeliveryWithoutScreenshotsSkipsSelection() throws {
        let queue = DictationQueueState()
        let noScreenshots = try XCTUnwrap(queue.enqueue(snapshot: snapshot(), audio: .memory([1])))
        queue.completeSTT(jobID: noScreenshots, text: "first", requiresLLM: false)

        XCTAssertEqual(queue.startDeliveryIfPossible(), noScreenshots)
        XCTAssertEqual(queue.job(id: noScreenshots)?.status, .delivering)
    }

    func testScreenshotPasteDisabledSkipsSelectionEvenWithScreenshots() throws {
        let queue = DictationQueueState()
        let job = try XCTUnwrap(queue.enqueue(
            snapshot: snapshot(screenshotPasteEnabled: false),
            audio: .memory([1]),
            screenshots: [makeScreenshot()]
        ))
        queue.completeSTT(jobID: job, text: "first", requiresLLM: false)

        XCTAssertEqual(queue.startDeliveryIfPossible(), job)
        XCTAssertEqual(queue.job(id: job)?.status, .delivering)
    }

    func testCancelDuringScreenshotSelectionIsTerminalAndUnblocksFIFO() throws {
        let queue = DictationQueueState()
        let first = try XCTUnwrap(queue.enqueue(
            snapshot: snapshot(),
            audio: .memory([1]),
            screenshots: [makeScreenshot()]
        ))
        let second = try XCTUnwrap(queue.enqueue(snapshot: snapshot(), audio: .memory([2])))
        queue.completeSTT(jobID: first, text: "first", requiresLLM: false)
        queue.completeSTT(jobID: second, text: "second", requiresLLM: false)
        XCTAssertEqual(queue.startDeliveryIfPossible(), first)

        queue.cancelJob(jobID: first)

        XCTAssertEqual(queue.job(id: first)?.status, .canceled)
        XCTAssertNil(queue.activeDeliveryJobID)
        XCTAssertEqual(queue.startDeliveryIfPossible(), second)
    }

    func testCancelReleasesProviderPermitAndAdvancesFIFO() throws {
        let queue = DictationQueueState()
        let first = try XCTUnwrap(queue.enqueue(snapshot: snapshot(), audio: .memory([1])))
        let second = try XCTUnwrap(queue.enqueue(snapshot: snapshot(), audio: .memory([2])))
        XCTAssertEqual(queue.startNextSTT(), first)

        queue.cancelJob(jobID: first)
        XCTAssertEqual(queue.startNextSTT(), second)
    }

    func testForegroundCancelTargetsOnlyOldestNonTerminalJob() throws {
        let queue = DictationQueueState()
        let first = try XCTUnwrap(queue.enqueue(snapshot: snapshot(stt: .groq), audio: .memory([1])))
        let second = try XCTUnwrap(queue.enqueue(snapshot: snapshot(stt: .groq), audio: .memory([2])))
        XCTAssertEqual(queue.startNextSTT(), first)
        XCTAssertEqual(queue.startNextSTT(), second)
        XCTAssertEqual(queue.foregroundJobID, first)

        queue.cancelJob(jobID: first)

        XCTAssertEqual(queue.job(id: first)?.status, .canceled)
        XCTAssertEqual(queue.job(id: second)?.status, .transcribing)
        XCTAssertEqual(queue.foregroundJobID, second)
    }

    func testLateProviderCompletionDoesNotReviveCanceledJob() throws {
        let queue = DictationQueueState()
        let first = try XCTUnwrap(queue.enqueue(snapshot: snapshot(), audio: .memory([1])))
        XCTAssertEqual(queue.startNextSTT(), first)

        queue.cancelJob(jobID: first)
        queue.completeSTT(jobID: first, text: "late", requiresLLM: true)
        XCTAssertEqual(queue.job(id: first)?.status, .canceled)

        queue.completeLLM(jobID: first, correctedText: "late!")
        queue.completeDelivery(jobID: first)
        XCTAssertEqual(queue.job(id: first)?.status, .canceled)
    }

    func testTerminalJobClearsHeavyPayloadsButKeepsTextMetadata() throws {
        let queue = DictationQueueState()
        let first = try XCTUnwrap(queue.enqueue(
            snapshot: snapshot(),
            audio: .memory([1, 2, 3]),
            screenshots: [makeScreenshot()]
        ))
        queue.completeSTT(jobID: first, text: "raw", requiresLLM: false)
        queue.setSelectedImages(jobID: first, images: [Data([4, 5, 6])])

        queue.completeDelivery(jobID: first)

        let job = try XCTUnwrap(queue.job(id: first))
        XCTAssertEqual(job.status, .delivered)
        XCTAssertEqual(job.transcribedText, "raw")
        XCTAssertEqual(job.audio, .memory([]))
        XCTAssertTrue(job.screenshots.isEmpty)
        XCTAssertTrue(job.selectedImages.isEmpty)
    }

    func testSTTFailureMarksTerminalAndUnblocksLaterJobs() throws {
        let queue = DictationQueueState()
        let first = try XCTUnwrap(queue.enqueue(snapshot: snapshot(), audio: .memory([1])))
        let second = try XCTUnwrap(queue.enqueue(snapshot: snapshot(), audio: .memory([2])))
        queue.completeSTT(jobID: second, text: "second", requiresLLM: false)
        queue.failSTT(jobID: first, message: "boom")

        XCTAssertEqual(queue.startDeliveryIfPossible(), second)
    }

    func testLLMFailureFallsBackToRawAndDelivers() throws {
        let queue = DictationQueueState()
        let first = try XCTUnwrap(queue.enqueue(snapshot: snapshot(), audio: .memory([1])))
        queue.completeSTT(jobID: first, text: "raw", requiresLLM: true)
        XCTAssertEqual(queue.startNextLLM(), first)
        queue.failLLMFallbackToRaw(jobID: first)

        let job = try XCTUnwrap(queue.job(id: first))
        XCTAssertEqual(job.status, .readyForDelivery)
        XCTAssertEqual(job.transcribedText, "raw")
        XCTAssertEqual(job.correctedText, "")
        XCTAssertEqual(queue.startDeliveryIfPossible(), first)
    }
}
