import Combine
import Foundation

/// The compact artwork lingers after a pause; full player metadata stays intact.
@MainActor
final class CompactMediaVisibility: ObservableObject {
    @Published private(set) var isVisible = false
    private let pauseDelay: Duration
    private var lastPlaybackState: Bool?
    private var pendingHide: Task<Void, Never>?

    init(pauseDelay: Duration = .seconds(10)) {
        self.pauseDelay = pauseDelay
    }

    func update(isPlaying: Bool?) {
        // Metadata/artwork refreshes must not restart an existing pause countdown
        // or redisplay artwork whose countdown has already elapsed.
        guard lastPlaybackState != isPlaying else { return }
        lastPlaybackState = isPlaying
        pendingHide?.cancel()
        pendingHide = nil
        guard let isPlaying else {
            isVisible = false
            return
        }
        isVisible = true
        guard !isPlaying else { return }
        let delay = pauseDelay
        pendingHide = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: delay) }
            catch { return }
            guard let self, !Task.isCancelled, self.lastPlaybackState == false else { return }
            self.isVisible = false
            self.pendingHide = nil
        }
    }

    deinit { pendingHide?.cancel() }
}
