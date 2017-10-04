//
//  VideoDownloadManager.swift
//  DownTube
//
//  Created by Adam Boyd on 2016-11-02.
//  Copyright © 2016 Adam. All rights reserved.
//

import Foundation
import UIKit
import CoreData
import XCDYouTubeKit

protocol VideoManagerDelegate: class {
    func reloadRows(_ rows: [IndexPath])
    func updateDownloadProgress(_ download: Download, at index: Int, with totalSize: String)
    func startDownloadOfVideoInfoFor(_ url: String)
    func showErrorAlertControllerWithMessage(_ message: String?)
}

class VideoManager: NSObject, URLSessionDelegate, URLSessionDownloadDelegate {
    let defaultSession = URLSession(configuration: URLSessionConfiguration.default)
    var dataTask: URLSessionDataTask?
    var activeDownloads: [String: Download] = [:]
    
    var currentlyEditingVideo: Video?
    
    lazy var downloadsSession: URLSession = {
        let configuration = URLSessionConfiguration.background(withIdentifier: "bgSessionConfiguration")
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
        return session
    }()
    
    weak var delegate: VideoManagerDelegate?
    var fileManager: FileManager = .default
    
    // Path where the video files are stored
    var documentsPath: String {
        return NSSearchPathForDirectoriesInDomains(.documentDirectory, .userDomainMask, true)[0]
    }
    
    init(delegate: VideoManagerDelegate?, fileManager: FileManager) {
        
        super.init()
        
        self.delegate = delegate
        self.fileManager = fileManager
        
        self.setUpSharedVideoListIfNeeded()
        
        //Need to specifically init this because self has to be used in the argument, which isn't formed until here
        _ = self.downloadsSession
    }
    
    /// Gets the streaming video information for a particular video
    ///
    /// - Parameters:
    ///   - youTubeUrl: youtube url for the video
    ///   - completion: called when the video info is ready or if there is an error
    func getStreamInfo(for youTubeUrl: String, completion: @escaping (_ url: URL?, _ video: StreamingVideo?, _ error: Error?) -> Void) {
        
        //Gets the video id, which is the last 11 characters of the string
        XCDYouTubeClient.default().getVideoWithIdentifier(String(youTubeUrl.characters.suffix(11))) { [unowned self] video, error in
            
            if let error = error {
                completion(nil, nil, error)
                return
            }
            
            if let streamUrl = self.highestQualityStreamUrlFor(video), let url = URL(string: streamUrl) {
                
                //Creating the fetch request, looking for the video with the same streamUrl
                let fetchRequest: NSFetchRequest<StreamingVideo> = StreamingVideo.fetchRequest()
                fetchRequest.predicate = NSPredicate(format: "youtubeUrl == %@", youTubeUrl)
                
                do {
                    let existingVideos = try CoreDataController.sharedController.managedObjectContext.fetch(fetchRequest)
                    var videoInCoreData: StreamingVideo
                    
                    if let existingVideo = existingVideos.first {
                        videoInCoreData = existingVideo
                    } else {
                        videoInCoreData = CoreDataController.sharedController.createNewStreamingVideo(youTubeUrl: youTubeUrl, streamUrl: streamUrl, videoObject: video)
                    }
                    
                    completion(url, videoInCoreData, nil)
                    
                } catch let error {
                    //Don't alert user
                    print("An error occurred saving the video: \(error)")
                }
                
            }
        }
    }
    
    // MARK: - Downloading
    
    /**
     Starts download for video, called when track is added
     
     - parameter video:     Video object
     - parameter onSuccess: closure that is called immediately if the video is valid
     */
    func startDownload(_ video: Video, onSuccess completion: (Int) -> Void) {
        print("Starting download of video \(video.title ?? "unknown video")")
        if let urlString = video.streamUrl, let url = URL(string: urlString), let index = self.videoIndexForStreamUrl(urlString) {
            let download = Download(url: urlString)
            download.downloadTask = self.downloadsSession.downloadTask(with: url)
            download.downloadTask?.resume()
            download.isDownloading = true
            self.activeDownloads[download.url] = download
            
            completion(index)
        }
    }
    
    /**
     Called when pause button for video is tapped
     
     - parameter video: Video object
     */
    func pauseDownload(_ video: Video) {
        print("Startind download")
        if let urlString = video.streamUrl, let download = self.activeDownloads[urlString] {
            if download.isDownloading {
                download.downloadTask?.cancel() { data in
                    if data != nil {
                        download.resumeData = data
                    }
                }
                download.isDownloading = false
            }
        }
    }
    
    /**
     Called when the cancel button for a video is tapped
     
     - parameter video: Video object
     */
    func cancelDownload(_ video: Video) {
        print("Canceling download of video \(video.title ?? "unknown video")")
        if let urlString = video.streamUrl, let download = self.activeDownloads[urlString] {
            download.downloadTask?.cancel()
            self.activeDownloads[urlString] = nil
        }
        
    }
    
    /**
     Called when the resume button for a video is tapped
     
     - parameter video: Video object
     */
    func resumeDownload(_ video: Video) {
        print("Resuming download of video \(video.title ?? "unknown video")")
        if let urlString = video.streamUrl, let download = self.activeDownloads[urlString] {
            if let resumeData = download.resumeData {
                download.downloadTask = self.downloadsSession.downloadTask(withResumeData: resumeData)
                download.downloadTask?.resume()
                download.isDownloading = true
            } else if let url = URL(string: download.url) {
                download.downloadTask = self.downloadsSession.downloadTask(with: url)
                download.downloadTask?.resume()
                download.isDownloading = true
            }
        }
    }
    
    // MARK: - Managing videos
    
    /**
     Called when the video info for a video is downloaded
     
     - parameter video:      optional video object that was downloaded, contains stream info, title, etc.
     - parameter youTubeUrl: youtube URL of the video
     - parameter error:      optional error
     */
    func videoObject(_ video: XCDYouTubeVideo?, downloadedForVideoAt youTubeUrl: String, error: NSError?) {
        if let videoTitle = video?.title {
            print("\(videoTitle)")
            
            if let video = video, let streamUrl = self.highestQualityStreamUrlFor(video) {
                self.createObjectInCoreDataAndStartDownloadFor(video, withStreamUrl: streamUrl, andYouTubeUrl: youTubeUrl)
                
                return
            }
            
        }
        
        //Show error to user and remove all errored out videos
        self.showErrorAndRemoveErroredVideos(error)
    }
    
    /**
     Creates new video object in core data, saves the information for that video, and starts the download of the video stream
     
     - parameter video:      video object
     - parameter streamUrl:  streaming URL for the video
     - parameter youTubeUrl: youtube URL for the video (youtube.com/watch?=v...)
     */
    private func createObjectInCoreDataAndStartDownloadFor(_ video: XCDYouTubeVideo?, withStreamUrl streamUrl: String, andYouTubeUrl youTubeUrl: String) {
        
        //Make sure the stream URL doesn't exist already
        guard self.videoIndexForYouTubeUrl(youTubeUrl) == nil else {
            self.delegate?.showErrorAlertControllerWithMessage("Video already downloaded")
            return
        }
        
        let newVideo = CoreDataController.sharedController.createNewVideo(youTubeUrl: youTubeUrl, streamUrl: streamUrl, videoObject: video)
        
        //Starts the download of the video
        self.startDownload(newVideo) { index in
            self.delegate?.reloadRows([IndexPath(row: index, section: 0)])
        }
    }
    
    /**
     Shows error to user in UIAlertController and then removes all errored out videos from core data
     
     - parameter error: error from getting the video info
     */
    func showErrorAndRemoveErroredVideos(_ error: NSError?) {
        //Show error to user, remove all unused cells from list
        DispatchQueue.main.async {
            if let error = error {
                print("Couldn't get video: \(error.localizedDescription)")
            } else {
                print("Couldn't get video: unknown error")
            }
            
            let message = error?.localizedDescription
            self.delegate?.showErrorAlertControllerWithMessage(message)
        }
        
        //Getting all blank videos with no downloaded data
        var objectsToRemove: [IndexPath] = []
        for (index, video) in CoreDataController.sharedController.fetchedVideosController.fetchedObjects!.enumerated() where video.streamUrl == nil {
            objectsToRemove.append(IndexPath(row: index, section: 0))
        }
        
        //Deleting them
        for indexPath in objectsToRemove {
            _ = self.deleteDownloadedVideo(at: indexPath)
            self.deleteVideoObject(at: indexPath)
        }
        
    }
    
    /**
     Deletes video object from core data
     
     - parameter indexPath: location of the video
     */
    func deleteVideoObject(at indexPath: IndexPath) {
        let video = CoreDataController.sharedController.fetchedVideosController.object(at: indexPath)
        
        let context = CoreDataController.sharedController.fetchedVideosController.managedObjectContext
        context.delete(video)
        
        do {
            try context.save()
        } catch {
            abort()
        }
    }
    
    /// Deletes the downloaded video at the specified index path
    ///
    /// - Parameter indexPath: indexpath of the video to delete
    /// - Returns: video that was deleted
    func deleteDownloadedVideo(at indexPath: IndexPath) -> Video {
        let video = CoreDataController.sharedController.fetchedVideosController.object(at: indexPath)
        
        self.cancelDownload(video)
        _ = self.deleteDownloadedVideo(for: video)
        
        return video
    }
    
    // MARK: - Getting indexes
    
    /**
     Gets the index of the video for the current download in the fetched results controller
     
     - parameter url: youtube url for the video
     
     - returns: optional index
     */
    func videoIndexForYouTubeUrl(_ url: String) -> Int? {
        for (index, video) in CoreDataController.sharedController.fetchedVideosController.fetchedObjects!.enumerated() where url == video.youtubeUrl {
            return index
        }
        
        return nil
    }
    
    /**
     Gets the index of the video for the current download in the fetched results controller
     
     - parameter url: streaming URL for the video
     
     - returns: optional index
     */
    func videoIndexForStreamUrl(_ url: String) -> Int? {
        for (index, video) in CoreDataController.sharedController.fetchedVideosController.fetchedObjects!.enumerated() where url == video.streamUrl {
            return index
        }
        
        return nil
    }
    
    /**
     Gets the index of the video for the current download in the fetched results controller
     
     - parameter downloadTask: video that is currently downloading
     
     - returns: optional index
     */
    func videoIndexForDownloadTask(_ downloadTask: URLSessionDownloadTask) -> Int? {
        if let url = downloadTask.originalRequest?.url?.absoluteString {
            return self.videoIndexForStreamUrl(url)
        }
        
        return nil
    }
    
    // MARK: - Locations of downloads
    
    /// Gets the file name of the video with the stream URL. Doesn't include path
    ///
    /// - Parameter streamUrl: youtube stream url
    /// - Returns: file's name
    fileprivate func fileNameForVideo(withStreamUrl streamUrl: String) -> String? {
        guard let url = URL(string: streamUrl), let query = url.query else { return nil }
        
        //Getting the video ID using regex
        guard let match = query.range(of: "&id=.*", options: .regularExpression) else { return nil }
        
        //Trimming the values
        let low = query.index(match.lowerBound, offsetBy: 4)
        let high = query.index(match.lowerBound, offsetBy: 21)
        
        //Only use part of the Url for the file name
        return String(query[low..<high]) + ".mp4"
    }
    
    /**
     Generates a permanent local file path to save a track to by appending the lastPathComponent of the URL to the path of the app's documents directory
     
     - parameter streamUrl: URL of the video
     
     - returns: URL to the file
     */
    func localFilePathForUrl(_ streamUrl: String) -> URL? {
        guard let fileName = self.fileNameForVideo(withStreamUrl: streamUrl) else { return nil }
        
        let fullPath = (self.documentsPath as NSString).appendingPathComponent(fileName)
        return URL(fileURLWithPath: fullPath)
    }
    
    /// Gets the string path location for the video. Without the file:// prefix
    ///
    /// - Parameter streamUrl: URL of the video
    /// - Returns: string path to the file
    func localFileLocationForUrl(_ streamUrl: String) -> String? {
        guard let stringPath = self.localFilePathForUrl(streamUrl)?.absoluteString else {
            return nil
        }
        
        let startIndex = stringPath.index(stringPath.startIndex, offsetBy: 7)
        let endIndex = stringPath.endIndex
        return String(stringPath[startIndex..<endIndex])
    }
    
    /**
     Determines whether or not a file exists for the video
     
     - parameter video: Video object
     
     - returns: true if object exists at path, false otherwise
     */
    func localFileExistsFor(_ video: Video) -> Bool {
        if let urlString = video.streamUrl, let localUrl = self.localFilePathForUrl(urlString) {
            var isDir: ObjCBool = false
            return self.fileManager.fileExists(atPath: localUrl.path, isDirectory: &isDir)
        }
        
        return false
    }
    
    // MARK: - Cleaning up downloads
    
    /// This makes sure that all videos located in the documents folder for DownTube actually have a Video object that they're attached to. This will delete all files not attached to a video.
    func cleanUpDownloadedFiles(from coreDataController: CoreDataController) {
        let streamUrls = coreDataController.fetchedVideosController.fetchedObjects?.flatMap({ $0.streamUrl }) ?? []
        let filesThatShouldExist = Set(streamUrls.flatMap({ self.fileNameForVideo(withStreamUrl: $0) }))
        
        let contents = try? self.fileManager.contentsOfDirectory(atPath: self.documentsPath as String)
        let videosInFolder = Set(contents?.filter({ $0.hasSuffix("mp4") }) ?? [])
        
        let videoFilesToDelete = videosInFolder.subtracting(filesThatShouldExist)
        
        print("Number of files that shouldn't be there: \(videoFilesToDelete.count)")
        
        for videoFile in videoFilesToDelete {
            self.deleteDownloadedVideo(withFileName: videoFile)
        }
    }
    
    /// Deletes the video file associated with the provided video
    ///
    /// - Parameter video: video to delete the file for
    /// - Returns: true if success, false otherwise
    func deleteDownloadedVideo(for video: Video) -> Bool {
        guard let streamUrl = video.streamUrl else { return false }
        
        guard let fileName = self.fileNameForVideo(withStreamUrl: streamUrl) else { return false }
        
        return self.deleteDownloadedVideo(withFileName: fileName)
    }
    
    /// Uses the filemanager to delete any downloaded video with the stream
    ///
    /// - Parameter fileName: local file name of the file. Shouldn't include any path
    @discardableResult fileprivate func deleteDownloadedVideo(withFileName fileName: String) -> Bool {
        let fullPath = (self.documentsPath as NSString).appendingPathComponent(fileName)
        let urlOfFile = URL(fileURLWithPath: fullPath)
        
        do {
            print("Successfully deleted file: \(fileName)")
            try self.fileManager.removeItem(at: urlOfFile)
            return true
        } catch let error {
            print("Couldn't delete file \(fileName): \(error.localizedDescription)")
            return false
        }
        
    }
    
    // MARK: - Editing videos
    
    /// Saves the trimmed video at the specified location to the location where the video's video file should be
    ///
    /// - Parameter trimmedLocation: string path of the trimmed video
    func saveCurrentlyEditedVideo(_ trimmedLocation: String) {
        guard var video = self.currentlyEditingVideo, let streamUrl = video.streamUrl else {
            print("Couldn't access current video")
            return
        }
        
        self.currentlyEditingVideo = nil
        
        let fromUrl = URL(fileURLWithPath: trimmedLocation)
        let toUrl = self.localFilePathForUrl(streamUrl)
        
        switch video.watchProgress {
        case .partiallyWatched:         video.watchProgress = .unwatched
        default:                        break
        }
        
        CoreDataController.sharedController.saveContext()
        
        if let toUrl = toUrl {
            do {
                try self.fileManager.removeItem(at: toUrl)
                try self.fileManager.copyItem(at: fromUrl, to: toUrl)
                print("File moved successfully")
            } catch let error as NSError {
                print("Could not copy file: \(error.localizedDescription)")
            }
        }
    }
    
    // MARK: - Videos from extension
    
    /**
     Initializes an empty of video URLs to add when the app opens in NSUserDefaults
     */
    func setUpSharedVideoListIfNeeded() {
        
        //If the array already exists, don't do anything
        if Constants.sharedDefaults.object(forKey: Constants.videosToAdd) != nil {
            return
        }
        
        let emptyArray: [String] = []
        Constants.sharedDefaults.set(emptyArray, forKey: Constants.videosToAdd)
        Constants.sharedDefaults.synchronize()
    }
    
    /**
     Starts the video info download for all videos stored in the shared array of youtube URLs. Clears the list when done
     */
    func addVideosFromSharedArray() {
        
        if let array = Constants.sharedDefaults.object(forKey: Constants.videosToAdd) as? [String] {
            for youTubeUrl in array {
                self.delegate?.startDownloadOfVideoInfoFor(youTubeUrl)
            }
        }
        
        //Deleting all videos
        let emptyArray: [String] = []
        Constants.sharedDefaults.set(emptyArray, forKey: Constants.videosToAdd)
        Constants.sharedDefaults.synchronize()
    }
    
    /**
     Called when a message was received from the app extension. Should contain YouTube URL
     
     - parameter message: message sent from the share extension
     */
    func messageWasReceivedFromExtension(_ message: Any?) {
        if let message = message as? String {
            
            //Remove the item at the end of the list from the list of items to add when the app opens
            var existingItems = Constants.sharedDefaults.object(forKey: Constants.videosToAdd) as! [String]
            existingItems.removeLast()
            Constants.sharedDefaults.set(existingItems, forKey: Constants.videosToAdd)
            Constants.sharedDefaults.synchronize()
            
            self.delegate?.startDownloadOfVideoInfoFor(message)
        }
    }
    
    // MARK: - Helpers
    
    /**
     Gets the highest quality video stream Url
     
     - parameter video:      optional video object that was downloaded, contains stream info, title, etc.
     
     - returns:              optional string containing the highest quality video stream
     */
    func highestQualityStreamUrlFor(_ video: XCDYouTubeVideo?) -> String? {
        var streamUrl: String?
        guard let video = video else { return nil }
        let streamURLs = NSDictionary(dictionary: video.streamURLs)
        
        if let highQualityStream = streamURLs[XCDYouTubeVideoQuality.HD720.rawValue] as? URL {
            
            //If 720p video exists
            streamUrl = highQualityStream.absoluteString
            
        } else if let mediumQualityStream = streamURLs[XCDYouTubeVideoQuality.medium360.rawValue] as? URL {
            
            //If 360p video exists
            streamUrl = mediumQualityStream.absoluteString
            
        } else if let lowQualityStream = streamURLs[XCDYouTubeVideoQuality.small240.rawValue] as? URL {
            
            //If 240p video exists
            streamUrl = lowQualityStream.absoluteString
        }
        
        return streamUrl
    }
    
    // MARK: - URLSessionDownloadDelegate
    
    //Download finished
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        if let originalURL = downloadTask.originalRequest?.url?.absoluteString {
            
            if let destinationURL = self.localFilePathForUrl(originalURL) {
                print("Destination URL: \(destinationURL)")
                
                let fileManager = self.fileManager
                
                //Removing the file at the path, just in case one exists
                do {
                    try fileManager.removeItem(at: destinationURL)
                } catch {
                    print("No file to remove. Proceeding...")
                }
                
                //Moving the downloaded file to the new location
                do {
                    try fileManager.copyItem(at: location, to: destinationURL)
                } catch let error as NSError {
                    print("Could not copy file: \(error.localizedDescription)")
                }
                
                //Updating the cell
                if let url = downloadTask.originalRequest?.url?.absoluteString {
                    self.activeDownloads[url] = nil
                    
                    if let videoIndex = self.videoIndexForDownloadTask(downloadTask) {
                        self.delegate?.reloadRows([IndexPath(row: videoIndex, section: 0)])
                    }
                }
            }
        }
    }
    
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        
        if let downloadUrl = downloadTask.originalRequest?.url?.absoluteString, let download = self.activeDownloads[downloadUrl] {
            download.progress = Float(totalBytesWritten)/Float(totalBytesExpectedToWrite)
            let totalSize = ByteCountFormatter.string(fromByteCount: totalBytesExpectedToWrite, countStyle: ByteCountFormatter.CountStyle.binary)
            if let trackIndex = self.videoIndexForDownloadTask(downloadTask) {
                self.delegate?.updateDownloadProgress(download, at: trackIndex, with: totalSize)
            }
        }
    }
    
    // MARK: - URLSessionDelegate
    
    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        if let appDelegate = UIApplication.shared.delegate as? AppDelegate {
            if let completionHandler = appDelegate.backgroundSessionCompletionHandler {
                appDelegate.backgroundSessionCompletionHandler = nil
                DispatchQueue.main.async(execute: {
                    completionHandler()
                })
            }
        }
    }
}
