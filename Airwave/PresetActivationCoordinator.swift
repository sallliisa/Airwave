import Foundation

/// Latest-wins coordinator used to keep activation work cancellable and deduplicated.
struct PresetActivationCoordinator<Value> {
    typealias Builder = (_ isCancelled: @escaping () -> Bool) throws -> Value

    private let storage = PresetActivationCoordinatorStorage()

    @discardableResult
    func request(
        key: PresetActivationKey,
        build: @escaping Builder,
        onSuccess: @escaping (PresetActivationKey, Value) -> Void,
        onFailure: @escaping (PresetActivationKey, Error) -> Void
    ) -> Bool {
        storage.request(
            key: key,
            build: { isCancelled in try build(isCancelled) },
            onSuccess: { key, value in
                guard let value = value as? Value else { return }
                onSuccess(key, value)
            },
            onFailure: onFailure
        )
    }

    func deactivate() {
        storage.deactivate()
    }
}

private final class PresetActivationCoordinatorStorage {
    typealias Builder = (_ isCancelled: @escaping () -> Bool) throws -> Any

    private let stateLock = NSLock()
    private var generation = 0
    private var currentKey: PresetActivationKey?
    private var inFlightKey: PresetActivationKey?
    private var workItem: DispatchWorkItem?
    private var token: ActivationCancellationToken?

    @discardableResult
    func request(
        key: PresetActivationKey,
        build: @escaping Builder,
        onSuccess: @escaping (PresetActivationKey, Any) -> Void,
        onFailure: @escaping (PresetActivationKey, Error) -> Void
    ) -> Bool {
        stateLock.lock()
        if key == currentKey || key == inFlightKey {
            stateLock.unlock()
            return false
        }
        workItem?.cancel()
        token?.cancel()
        generation += 1
        let requestGeneration = generation
        let cancellationToken = ActivationCancellationToken()
        token = cancellationToken
        inFlightKey = key
        stateLock.unlock()

        let item = DispatchWorkItem { [weak self] in
            do {
                let value = try build { cancellationToken.isCancelled }
                guard !cancellationToken.isCancelled else { return }
                self?.finishSuccess(
                    generation: requestGeneration,
                    key: key,
                    value: value,
                    callback: onSuccess
                )
            } catch {
                guard !cancellationToken.isCancelled else { return }
                self?.finishFailure(
                    generation: requestGeneration,
                    key: key,
                    error: error,
                    callback: onFailure
                )
            }
        }
        stateLock.lock()
        workItem = item
        stateLock.unlock()
        DispatchQueue.global(qos: .userInitiated).async(execute: item)
        return true
    }

    func deactivate() {
        stateLock.lock()
        workItem?.cancel()
        token?.cancel()
        generation += 1
        currentKey = nil
        inFlightKey = nil
        workItem = nil
        token = nil
        stateLock.unlock()
    }

    private func finishSuccess(
        generation requestGeneration: Int,
        key: PresetActivationKey,
        value: Any,
        callback: @escaping (PresetActivationKey, Any) -> Void
    ) {
        stateLock.lock()
        guard requestGeneration == generation, inFlightKey == key else {
            stateLock.unlock()
            return
        }
        currentKey = key
        inFlightKey = nil
        workItem = nil
        token = nil
        stateLock.unlock()
        DispatchQueue.main.async { callback(key, value) }
    }

    private func finishFailure(
        generation requestGeneration: Int,
        key: PresetActivationKey,
        error: Error,
        callback: @escaping (PresetActivationKey, Error) -> Void
    ) {
        stateLock.lock()
        guard requestGeneration == generation, inFlightKey == key else {
            stateLock.unlock()
            return
        }
        inFlightKey = nil
        workItem = nil
        token = nil
        stateLock.unlock()
        DispatchQueue.main.async { callback(key, error) }
    }
}
