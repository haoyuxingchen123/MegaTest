//
//  MEGAAVViewController+HangFix.swift
//  MEGA
//
//  Created by liyizhen on 2025/9/15.
//  Copyright © 2025 MEGA. All rights reserved.
//

import Foundation

typealias TaskClosure = ((Any?) -> Void)
private var taskCoordinatorKey: UInt8 = 0

extension MEGAAVViewController {
    var taskCoordinator: MegaCoordinator? {
        get {
            return objc_getAssociatedObject(self, &taskCoordinatorKey) as? MegaCoordinator
        }
        set {
            objc_setAssociatedObject(self, &taskCoordinatorKey, newValue, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        }
    }
    
    @objc
    func startVideoPlayerTasks(_ complete: @escaping () -> Void) {
        BugFixLog("startVideoPlayerTask start")
        guard let coordinator = getTaskCoordinator() else {
            return
        }
        coordinator.registerBlock(taskType: .AsynTasksBefore) { _ in
            Task { [weak self] in
                do {
                    BugFixLog("startVideoPlayerTask asyncSetupAVPlayer")
                    try await self?.asyncSetupAVPlayer()
                } catch let err as NSError {
                    BugFixLog("error:\(err.userInfo.description)")
                }
            }
        }
        coordinator.registerBlock(taskType: .AsynTasksSeekToDestination) {[weak self] (_ param: Any?) in
            guard let param = param as? [String: Any] else {
                return
            }
            guard let playerItem = param["playerItem"] as? AVPlayerItem else {
                return
            }
            guard let readTo = param["readTo"] as? AVPlayerItem.Status, readTo == .readyToPlay else {
                return
            }
            BugFixLog("startVideoPlayerTasks Start SeekToDestination")
            self?.seekTo(mediaDestination: param["destination"] as? MOMediaDestination, playerItem: playerItem)
        }
        coordinator.registerBlock(taskType: .AsynTasksPlayerPlay) {[weak self] (_ param: Any?) in
            guard let param = param as? [String: Any] else {
                return
            }
            guard let presentFinish = param["presentFinish"] as? Bool, presentFinish == true else {
                return
            }
            guard let seekToFinish = param["seekToFinish"] as? Bool, seekToFinish == true else {
                return
            }
            self?.stopLoading()
            BugFixLog("startVideoPlayerTasks Start Play")
            self?.player?.play()
            complete()
        }
        Task {
            BugFixLog("startVideoPlayerTask executeTasks")
            await coordinator.executeTasks()
        }
    }
    
    @objc
    func seekToDestination(_ destination: MOMediaDestination?) {
        self.taskCoordinator?.seekToDestination(destination)
    }
    
    func playerItemReadyTo(_ readyTo: AVPlayerItem.Status) {
        if readyTo == .readyToPlay {
            BugFixLog("playerItemReadyTo")
            self.taskCoordinator?.playerItemReadyTo(.readyToPlay)
        }
    }
    
    func seekToFinish(_ finish: Bool) {
        if finish == true {
            BugFixLog("seekToFinish")
            self.taskCoordinator?.playerSeekToFinish(true)
        }
    }
    
    func presentAnimationFinish(_ finish: Bool) {
        guard let coordinator = getTaskCoordinator() else {
            return
        }
        if finish == true {
            coordinator.presentAnimationFinish(finish)
        }
    }
    
    private func playerItemFinishIntion(_ playerItem: AVPlayerItem) {
        self.taskCoordinator?.playerItemFinishInition(playerItem)
    }
    
    private func getTaskCoordinator() -> MegaCoordinator? {
        guard let coordinator = taskCoordinator else {
            let coordinator = MegaCoordinator()
            taskCoordinator = coordinator
            return coordinator
        }
        return coordinator
    }
    
    private func asyncSetupAVPlayer() async throws {
        return try await withCheckedThrowingContinuation { continuation in
            Task.detached(priority: .userInitiated) {[weak self] in
                guard let url = await self?.fileUrl else {
                    continuation.resume(throwing: NSError(domain: "AVViewController", code: -1, userInfo: ["msg": "fileUrl is nil"]))
                    return
                }
                guard let node = await self?.node else {
                    continuation.resume(throwing: NSError(domain: "AVViewController", code: -1, userInfo: ["msg": "node is nil"]))
                    return
                }
                let asset = MegaSafeAsset(url: url)
                let playerItem = asset.playItem()
                BugFixLog("asyncSetupAVPlayer asset.playItem create")
                await MainActor.run { [weak self] in
                    self?.playerItemFinishIntion(playerItem)
                    self?.setPlayerItemMetadata(playerItem: playerItem, node: node)
                    if let set = self?.bindPlayerItemStatus(playerItem: playerItem) {
                        BugFixLog("asyncSetupAVPlayer AVPlayerItem Binds")
                        self?.subscriptions.add(set)
                    }
                    self?.player = AVPlayer(playerItem: playerItem)
                    BugFixLog("asyncSetupAVPlayer AVPlayer create")
                    if let binds = self?.bindPlayerTimeControlStatus() {
                        BugFixLog("asyncSetupAVPlayer AVPlayer Binds")
                        self?.subscriptions.add(binds)
                    }
                    if let viewDidAppearFirstTime = self?.viewDidAppearFirstTime, viewDidAppearFirstTime == true {
                        var mediaDestination: MOMediaDestination?
                        if let fingerprint = self?.fileFingerprint(), fingerprint.count > 0 {
                            if self?.node != nil {
                                mediaDestination = MEGAStore.shareInstance().fetchRecentlyOpenedNode(fingerprint: fingerprint)?.mediaDestination
                            } else {
                                mediaDestination = MEGAStore.shareInstance().fetchMediaDestination(withFingerprint: fingerprint)
                            }
                        }
                        if let destination = mediaDestination?.destination, let timeScale = mediaDestination?.timescale, destination.int64Value > 0 && timeScale.intValue > 0 {
                            // no seekto here, seekto in alert decision
                        } else {
                            // seekto
                            BugFixLog("asyncSetupAVPlayer seekToDestination")
                            self?.seekToDestination(nil)
                        }
                    }
                    // has no "else" logic for old logic
                }
                BugFixLog("asyncSetupAVPlayer asset.loadAVAsset start")
                try await asset.loadAVAsset()
            }
        }
    }
}

extension MOMediaDestination: @unchecked Sendable {}

class MegaCoordinator: @unchecked Sendable {
    enum RegisterTaskType {
        case AsynTasksBefore
        case AsynTasksSeekToDestination
        case AsynTasksPlayerPlay
        case AsynTasksAfter
    }
    private var registerTaskMap = [RegisterTaskType: [TaskClosure]]()
    
    // seekTo
    private(set) var taskPlayerItemFinishInitionContinuation: CheckedContinuation<AVPlayerItem, Never>?
    private(set) var taskSeekToDestinationContinuation: CheckedContinuation<MOMediaDestination?, Never>?
    private(set) var taskPlayerItemReadyToContinuation: CheckedContinuation<AVPlayerItem.Status, Never>?
    // play
    private(set) var taskpresentAnimationFinishContinuation: CheckedContinuation<Bool, Never>?
    private(set) var taskPlayerSeekToFinishContinuation: CheckedContinuation<Bool, Never>?
    
    func playerItemFinishInition(_ playerItem: AVPlayerItem) {
        taskPlayerItemFinishInitionContinuation?.resume(returning: playerItem)
        taskPlayerItemFinishInitionContinuation = nil
    }
    
    func seekToDestination(_ destination: MOMediaDestination?) {
        taskSeekToDestinationContinuation?.resume(returning: destination)
        taskSeekToDestinationContinuation = nil
    }

    func playerItemReadyTo(_ readyTo: AVPlayerItem.Status) {
        taskPlayerItemReadyToContinuation?.resume(returning: readyTo)
        taskPlayerItemReadyToContinuation = nil
    }
    
    func presentAnimationFinish(_ finish: Bool) {
        taskpresentAnimationFinishContinuation?.resume(returning: finish)
        taskpresentAnimationFinishContinuation = nil
    }
    
    func playerSeekToFinish(_ finish: Bool) {
        taskPlayerSeekToFinishContinuation?.resume(returning: finish)
        taskPlayerSeekToFinishContinuation = nil
    }

    @MainActor
    func executeTasks() async {
        async let playerItemFinishInitionTask: AVPlayerItem = {@Sendable in
            return await withCheckedContinuation {[weak self] continuation in
                self?.taskPlayerItemFinishInitionContinuation = continuation
            }
        }()
        
        async let playerItemReadyToTask: AVPlayerItem.Status = {@Sendable in
            return await withCheckedContinuation {[weak self] continuation in
                self?.taskPlayerItemReadyToContinuation = continuation
            }
        }()
        
        async let seekToDestinationTask: MOMediaDestination? = {
            return await withCheckedContinuation {[weak self] (continuation: CheckedContinuation<MOMediaDestination?, Never>) in
                self?.taskSeekToDestinationContinuation = continuation
            }
        }()
        
        async let presentTask: Bool = {@Sendable in
            return await withCheckedContinuation {[weak self] continuation in
                self?.taskpresentAnimationFinishContinuation = continuation
            }
        }()
        
        async let playerSeekToFinishTask: Bool = { @Sendable in
            return await withCheckedContinuation {[weak self] (continuation: CheckedContinuation<Bool, Never>) in
                self?.taskPlayerSeekToFinishContinuation = continuation
            }
        }()
        
        BugFixLog("executeTasks AsynTasksBefore Tasks")
        if let beforeTasks = registerTaskMap[.AsynTasksBefore] {
            beforeTasks.forEach { block in
                block(nil)
            }
        }
        
        // seekTo
        if let seekToDestinationTasks = registerTaskMap[.AsynTasksSeekToDestination] {
            let playerItem = await playerItemFinishInitionTask
            let seekToDestination = await seekToDestinationTask
            let playerItemReadyTo = await playerItemReadyToTask
            
            BugFixLog("executeTasks seekTo Tasks")
            seekToDestinationTasks.forEach { (_ block: TaskClosure) in
                if let seekToDestination = seekToDestination {
                    block(["playerItem": playerItem, "destination": seekToDestination, "readTo": playerItemReadyTo])
                } else {
                    block(["playerItem": playerItem, "readTo": playerItemReadyTo])
                }
            }
        }
        
        // play
        if let playerPlayTasks = registerTaskMap[.AsynTasksPlayerPlay] {
            let presentAnimationFinish = await presentTask
            let seekToFinish = await playerSeekToFinishTask
            BugFixLog("executeTasks play Tasks")
            playerPlayTasks.forEach { (_ block: TaskClosure) in
                block(["presentFinish": presentAnimationFinish, "seekToFinish": seekToFinish])
            }
        }
        
        BugFixLog("executeTasks AsynTasksAfter Tasks")
        if let afterTasks = registerTaskMap[.AsynTasksAfter] {
            afterTasks.forEach { block in
                block(nil)
            }
        }
    }
    
    func registerBlock(taskType: RegisterTaskType, task: @escaping TaskClosure) {
        if var blocks = registerTaskMap[taskType] {
            blocks.append(task)
            return
        }
        var blocks = [TaskClosure]()
        blocks.append(task)
        registerTaskMap[taskType] = blocks
    }
}

struct MegaSafeAsset: @unchecked Sendable {
    private let asset: AVAsset
    
    init(url: URL) {
        self.asset = AVAsset(url: url)
    }
    
    func loadAVAsset() async throws {
        BugFixLog("loadAVAsset")
        try await AVAsset.loadValues(for: asset, for: [.tracks, .duration, .playable])
    }
    
    func playItem() -> AVPlayerItem {
        return AVPlayerItem(asset: asset)
    }
}

extension AVAsset {
    fileprivate enum AssetProperty {
        case tracks
        case duration
        case playable
        case metadata
        
        var key: String {
            switch self {
            case .tracks: return "tracks"
            case .duration: return "duration"
            case .playable: return "playable"
            case .metadata: return "metadata"
            }
        }
        
        @available(iOS 16.0, *)
        var asynTracks: AVAsyncProperty<AVAsset, [AVAssetTrack]> {
            return .tracks
        }
        
        @available(iOS 16.0, *)
        var asynDuration: AVAsyncProperty<AVAsset, CMTime> {
            return .duration
        }
        
        @available(iOS 16.0, *)
        var asynIsPlayable: AVAsyncProperty<AVAsset, Bool> {
            return .isPlayable
        }
        
        @available(iOS 16.0, *)
        var asynMetadata: AVAsyncProperty<AVAsset, [AVMetadataItem]> {
            return .metadata
        }
    }

    @available(iOS, deprecated: 16.0, message: "Use modernLoad")
    private static func legacyLoad(for asset: AVAsset, properties: [AssetProperty]) async throws {
        try await withCheckedThrowingContinuation { continuation in
            var keys = [String]()
            properties.forEach { property in
                keys.append(property.key)
            }
            BugFixLog("legacyLoad loadValuesAsynchronously")
            asset.loadValuesAsynchronously(forKeys: keys) {
                BugFixLog("legacyLoad continuation.resume")
                continuation.resume()
            }
        }
    }

    @available(iOS 16.0, *)
    private static func loadProperty(for asset: AVAsset, property: AssetProperty) async throws {
        switch property {
        case .tracks:
            _ = try await asset.load(.tracks)
        case .duration:
            _ = try await asset.load(.duration)
        case .playable:
            _ = try await asset.load(.isPlayable)
        case .metadata:
            _ = try await asset.load(.metadata)
        }
    }

    @available(iOS 16.0, *)
    private static func modernLoad(for asset: AVAsset, properties: [AssetProperty]) async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            for property in properties {
                group.addTask {
                    BugFixLog("modernLoad property[\(property)]")
                    try await loadProperty(for: asset, property: property)
                }
            }
            
            BugFixLog("modernLoad waitForAll")
            try await group.waitForAll()
        }
    }

    fileprivate static func loadValues(for asset: AVAsset, for properties: [AssetProperty]) async throws {
        if #available(iOS 16.0, *) {
            BugFixLog("loadValues modernLoad")
            try await modernLoad(for: asset, properties: properties)
        } else {
            BugFixLog("loadValues legacyLoad")
            try await legacyLoad(for: asset, properties: properties)
        }
    }
}

func BugFixLog(_ msg: String, _ file: String = #file, _ line: Int = #line) {
    MEGALogDebug("[HangBugFixLyz][mainThread:\(Thread.current.isMainThread)] \(msg)", file, line)
}
