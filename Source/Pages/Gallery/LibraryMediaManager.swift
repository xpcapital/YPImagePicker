//
//  LibraryMediaManager.swift
//  YPImagePicker
//
//  Created by Sacha DSO on 26/01/2018.
//  Copyright © 2018 Yummypets. All rights reserved.
//

import UIKit
import Photos
import Foundation
import AVFoundation

class LibraryMediaManager {
    
    weak var v: YPLibraryView?
    var collection: PHAssetCollection?
    internal var fetchResult: PHFetchResult<PHAsset>?
    internal var previousPreheatRect: CGRect = .zero
    internal var imageManager: PHCachingImageManager?
    internal var exportTimer: Timer?
    internal var currentExportSessions: [AVAssetExportSession] = []

    /// If true then library has items to show. If false the user didn't allow any item to show in picker library.
    internal var hasResultItems: Bool {
        if let fetchResult = self.fetchResult {
            return fetchResult.count > 0
        } else {
            return false
        }
    }
    
    func initialize() {
        imageManager = PHCachingImageManager()
        resetCachedAssets()
    }
    
    func resetCachedAssets() {
        imageManager?.stopCachingImagesForAllAssets()
        previousPreheatRect = .zero
    }
    
    func updateCachedAssets(in collectionView: UICollectionView) {
        let screenWidth = YPImagePickerConfiguration.screenWidth
        let size = screenWidth / 4 * UIScreen.main.scale
        let cellSize = CGSize(width: size, height: size)
        
        var preheatRect = collectionView.bounds
        preheatRect = preheatRect.insetBy(dx: 0.0, dy: -0.5 * preheatRect.height)
        
        let delta = abs(preheatRect.midY - previousPreheatRect.midY)
        if delta > collectionView.bounds.height / 3.0 {
            
            var addedIndexPaths: [IndexPath] = []
            var removedIndexPaths: [IndexPath] = []
            
            previousPreheatRect.differenceWith(rect: preheatRect, removedHandler: { removedRect in
                let indexPaths = collectionView.aapl_indexPathsForElementsInRect(removedRect)
                removedIndexPaths += indexPaths
            }, addedHandler: { addedRect in
                let indexPaths = collectionView.aapl_indexPathsForElementsInRect(addedRect)
                addedIndexPaths += indexPaths
            })
            
            guard let assetsToStartCaching = fetchResult?.assetsAtIndexPaths(addedIndexPaths),
                  let assetsToStopCaching = fetchResult?.assetsAtIndexPaths(removedIndexPaths) else {
                print("Some problems in fetching and caching assets.")
                return
            }
            
            imageManager?.startCachingImages(for: assetsToStartCaching,
                                             targetSize: cellSize,
                                             contentMode: .aspectFill,
                                             options: nil)
            imageManager?.stopCachingImages(for: assetsToStopCaching,
                                            targetSize: cellSize,
                                            contentMode: .aspectFill,
                                            options: nil)
            previousPreheatRect = preheatRect
        }
    }
    
    func fetchVideoUrlAndCrop(for videoAsset: PHAsset,
                              cropRect: CGRect,
                              callback: @escaping (_ videoURL: URL?) -> Void) {
        fetchVideoUrlAndCropWithDuration(for: videoAsset, cropRect: cropRect, duration: nil, callback: callback)
    }
    
    func fetchVideoUrlAndCropWithDuration(for videoAsset: PHAsset,
                                          cropRect: CGRect,
                                          duration: CMTime?,
                                          callback: @escaping (_ videoURL: URL?) -> Void) {
        let videosOptions = PHVideoRequestOptions()
        videosOptions.isNetworkAccessAllowed = true
        videosOptions.deliveryMode = .highQualityFormat
        imageManager?.requestAVAsset(forVideo: videoAsset, options: videosOptions) { [self] asset, _, _ in
            do {

                let videoTrack = asset!.tracks(withMediaType: .video).first!
                
                let videoComposition = AVMutableVideoComposition()
                videoComposition.renderSize = cropRect.size
                videoComposition.frameDuration = CMTime(value: 1, timescale: 30)
                
                let instruction = AVMutableVideoCompositionInstruction()
                instruction.timeRange = CMTimeRange(start: .zero, duration: CMTime(seconds: 60, preferredTimescale: 30))
                
                let testTransform = self.getTransform(for: videoTrack, cropRect: cropRect)
                let transformer = AVMutableVideoCompositionLayerInstruction(assetTrack: videoTrack)
                
                transformer.setTransform(testTransform, at: .zero)
                instruction.layerInstructions = [transformer]
                videoComposition.instructions = [instruction]
                
                let fileURL = URL(fileURLWithPath: NSTemporaryDirectory())
                    .appendingUniquePathComponent(pathExtension: YPConfig.video.fileType.fileExtension)
                let exportSession = AVAssetExportSession(asset: asset!, presetName: AVAssetExportPresetHighestQuality)
                exportSession?.videoComposition = videoComposition
                exportSession?.outputURL = fileURL
                exportSession?.outputFileType = AVFileType.mp4

                exportSession?.exportAsynchronously(completionHandler: {
                    
                    DispatchQueue.main.async {
                        switch exportSession?.status {
                        case .completed:
                            if let url = exportSession?.outputURL {
                                if let exportSession = exportSession,
                                   let index = self.currentExportSessions.firstIndex(of: exportSession) {
                                    self.currentExportSessions.remove(at: index)
                                }
                                callback(url)
                            } else {
                                ypLog("Don't have URL.")
                                callback(nil)
                            }
                        case .failed:
                            ypLog("Export of the video failed : \(String(describing: exportSession?.error))")
                            callback(nil)
                        default:
                            ypLog("Export session completed with \(exportSession?.status ?? .unknown) status. Not handled.")
                            callback(nil)
                        }
                    }
                })

                // 6. Exporting
                DispatchQueue.main.async {
                    self.exportTimer = Timer.scheduledTimer(timeInterval: 0.1,
                                                            target: self,
                                                            selector: #selector(self.onTickExportTimer),
                                                            userInfo: exportSession,
                                                            repeats: true)
                }
//
                if let s = exportSession {
                    self.currentExportSessions.append(s)
                }
            } catch let error {
                ypLog("Error: \(error)")
            }
        }
    }
    
    private func getTransform(for videoTrack: AVAssetTrack, cropRect: CGRect) -> CGAffineTransform {
        
        let renderScale: CGFloat = 1 //renderSize.width / cropFrame.width // TO DEFINE
        let offset = CGPoint(x: -cropRect.origin.x, y: -cropRect.origin.y)
        let rotation = atan2(videoTrack.preferredTransform.b, videoTrack.preferredTransform.a)

        var rotationOffset = CGPoint(x: 0, y: 0)

        if videoTrack.preferredTransform.b == -1.0 {
            rotationOffset.y = videoTrack.naturalSize.width
        } else if videoTrack.preferredTransform.c == -1.0 {
            rotationOffset.x = videoTrack.naturalSize.height
        } else if videoTrack.preferredTransform.a == -1.0 {
            rotationOffset.x = videoTrack.naturalSize.width
            rotationOffset.y = videoTrack.naturalSize.height
        }

        var transform = CGAffineTransform.identity
        transform = transform.scaledBy(x: renderScale, y: renderScale)
        transform = transform.translatedBy(x: offset.x + rotationOffset.x, y: offset.y + rotationOffset.y)
        transform = transform.rotated(by: rotation)

        print("track size \(videoTrack.naturalSize)")
        print("preferred Transform = \(videoTrack.preferredTransform)")
        print("rotation angle \(rotation)")
        print("rotation offset \(rotationOffset)")
        print("actual Transform = \(transform)")
        return transform
    }
    
    private func getMaxVideoDuration(between duration: CMTime?, andAssetDuration assetDuration: CMTime) -> CMTime {
        guard let duration = duration else { return assetDuration }

        if assetDuration <= duration {
            return assetDuration
        } else {
            return duration
        }
    }
    
    @objc func onTickExportTimer(sender: Timer) {
        if let exportSession = sender.userInfo as? AVAssetExportSession {
            if let v = v {
                if exportSession.progress > 0 {
                    v.updateProgress(exportSession.progress)
                }
            }
            
            if exportSession.progress > 0.99 {
                sender.invalidate()
                v?.updateProgress(0)
                self.exportTimer = nil
            }
        }
    }
    
    func forseCancelExporting() {
        for s in self.currentExportSessions {
            s.cancelExport()
        }
    }

    func getAsset(at index: Int) -> PHAsset? {
        guard let fetchResult = fetchResult else {
            print("FetchResult not contain this index: \(index)")
            return nil
        }
        guard fetchResult.count > index else {
            print("FetchResult not contain this index: \(index)")
            return nil
        }
        return fetchResult.object(at: index)
    }
    
    public func radians<T: FloatingPoint>(_ degrees: T) -> T {
        return .pi * degrees / 180
    }

    public func degrees<T: FloatingPoint>(radians: T) -> T {
        return radians * 180 / .pi
    }
}
