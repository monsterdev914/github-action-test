import AVFoundation
import ScreenCaptureKit

class RecorderCLI: NSObject, SCStreamDelegate, SCStreamOutput {
    static var screenCaptureStream: SCStream?
    var contentEligibleForSharing: SCShareableContent?
    let semaphoreRecordingStopped = DispatchSemaphore(value: 0)
    var recordingPath: String?
    var recordingFilename: String?
    var streamFunctionCalled = false
    var streamFunctionTimeout: TimeInterval = 0.5 // Timeout in seconds

    override init() {
        super.init()
        processCommandLineArguments()
    }

    func processCommandLineArguments() {
        let arguments = CommandLine.arguments
        guard arguments.contains("--record") else {
            if arguments.contains("--check-permissions") {
                PermissionsRequester.requestScreenCaptureAccess { granted in
                    if granted {
                        ResponseHandler.returnResponse(["code": "PERMISSION_GRANTED"])
                    } else {
                        ResponseHandler.returnResponse(["code": "PERMISSION_DENIED"])
                    }
                }
            } else if arguments.contains("--check-all-permissions") {
                // Check both microphone and screen recording permissions
                var micGranted = false
                var screenGranted = false
                var responses = 0
                
                let checkComplete = {
                    responses += 1
                    if responses == 2 {
                        let allGranted = micGranted && screenGranted
                        ResponseHandler.returnResponse([
                            "code": allGranted ? "ALL_PERMISSIONS_GRANTED" : "SOME_PERMISSIONS_DENIED",
                            "microphone": micGranted ? "granted" : "denied",
                            "screen_recording": screenGranted ? "granted" : "denied"
                        ])
                    }
                }
                
                PermissionsRequester.requestMicrophoneAccess { granted in
                    micGranted = granted
                    checkComplete()
                }
                
                PermissionsRequester.requestScreenCaptureAccess { granted in
                    screenGranted = granted
                    checkComplete()
                }
            } else {
                ResponseHandler.returnResponse(["code": "INVALID_ARGUMENTS"])
            }

            return
        }

        if let recordIndex = arguments.firstIndex(of: "--record"), recordIndex + 1 < arguments.count {
            recordingPath = arguments[recordIndex + 1]
        } else {
            ResponseHandler.returnResponse(["code": "NO_PATH_SPECIFIED"])
        }

        if let filenameIndex = arguments.firstIndex(of: "--filename"), filenameIndex + 1 < arguments.count {
            recordingFilename = arguments[filenameIndex + 1]
        }
    }

    func executeRecordingProcess() {
        self.updateAvailableContent()
        setupInterruptSignalHandler()
        setupStreamFunctionTimeout()
        semaphoreRecordingStopped.wait()
    }

    func setupInterruptSignalHandler() {
        let interruptSignalHandler: @convention(c) (Int32) -> Void = { signal in
            if signal == SIGINT {
                RecorderCLI.terminateRecording()

                let timestamp = Date()
                let formattedTimestamp = ISO8601DateFormatter().string(from: timestamp)
                ResponseHandler.returnResponse(["code": "RECORDING_STOPPED", "timestamp": formattedTimestamp])
            }
        }

        signal(SIGINT, interruptSignalHandler)
    }

    func setupStreamFunctionTimeout() {
        DispatchQueue.global().asyncAfter(deadline: .now() + streamFunctionTimeout) { [weak self] in
            guard let self = self else { return }
            if !self.streamFunctionCalled {
                RecorderCLI.terminateRecording()
                ResponseHandler.returnResponse(["code": "STREAM_FUNCTION_NOT_CALLED"], shouldExitProcess: true)
            } else {
                let timestamp = Date()
                let formattedTimestamp = ISO8601DateFormatter().string(from: timestamp)

                ResponseHandler.returnResponse(["code": "RECORDING_STARTED", "timestamp": formattedTimestamp], shouldExitProcess: false)
            }
        }
    }

    func updateAvailableContent() {
        SCShareableContent.getExcludingDesktopWindows(true, onScreenWindowsOnly: true) { [weak self] content, _ in
            guard let self = self else { return }
            self.contentEligibleForSharing = content
            self.setupRecordingEnvironment()
        }
    }

    func setupRecordingEnvironment() {
        guard let firstDisplay = contentEligibleForSharing?.displays.first else {
            ResponseHandler.returnResponse(["code": "NO_DISPLAY_FOUND"])
            return
        }

        let screenContentFilter = SCContentFilter(display: firstDisplay, excludingApplications: [], exceptingWindows: [])

        Task { await initiateRecording(with: screenContentFilter) }
    }

    func initiateRecording(with filter: SCContentFilter) async {
        let streamConfiguration = SCStreamConfiguration()
        configureStream(streamConfiguration)

        do {
            RecorderCLI.screenCaptureStream = SCStream(filter: filter, configuration: streamConfiguration, delegate: self)

            try RecorderCLI.screenCaptureStream?.addStreamOutput(self, type: .audio, sampleHandlerQueue: .global())
            try await RecorderCLI.screenCaptureStream?.startCapture()
        } catch {
            ResponseHandler.returnResponse(["code": "CAPTURE_FAILED"])
        }
    }

    func configureStream(_ configuration: SCStreamConfiguration) {
        configuration.width = 2
        configuration.height = 2
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale.max)
        configuration.showsCursor = false
        configuration.capturesAudio = true
        configuration.sampleRate = 48000
        configuration.channelCount = 2
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of outputType: SCStreamOutputType) {
        self.streamFunctionCalled = true
        guard let audioBuffer = sampleBuffer.asPCMBuffer, sampleBuffer.isValid else { return }

        // Send the audio buffer to the renderer through stderr
        if let channelData = audioBuffer.floatChannelData {
            let channelCount = Int(audioBuffer.format.channelCount)
            let frameLength = Int(audioBuffer.frameLength)
            
            // Interleave float data from all channels
            var interleavedData = [Float]()
            interleavedData.reserveCapacity(frameLength * channelCount)
            
            for frame in 0..<frameLength {
                for channel in 0..<channelCount {
                    interleavedData.append(channelData[channel][frame])
                }
            }
            
            // Convert Float32 array to Data (little endian)
            let data = interleavedData.withUnsafeBufferPointer {
                Data(buffer: $0)
            }
            
            // Write raw PCM float32 data to stderr
            FileHandle.standardError.write(data)
        }
        fflush(stderr)
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        ResponseHandler.returnResponse(["code": "STREAM_ERROR"], shouldExitProcess: false)
        RecorderCLI.terminateRecording()
        semaphoreRecordingStopped.signal()
    }

    static func terminateRecording() {
        screenCaptureStream?.stopCapture()
        screenCaptureStream = nil
    }
}

extension Date {
    func toFormattedFileName() -> String {
        let fileNameFormatter = DateFormatter()
        fileNameFormatter.dateFormat = "y-MM-dd HH.mm.ss"
        return fileNameFormatter.string(from: self)
    }
}

class PermissionsRequester {
    static func requestScreenCaptureAccess(completion: @escaping (Bool) -> Void) {
        let hasAccess = CGPreflightScreenCaptureAccess()
        
        if !hasAccess {
            let result = CGRequestScreenCaptureAccess()
            
            if !result {
                // Permission was denied and dialog won't show again
                // Open System Preferences to the Screen Recording section
                openScreenRecordingPreferences()
                
                ResponseHandler.returnResponse([
                    "code": "PERMISSION_DENIED_NO_DIALOG",
                    "message": "Screen recording permission denied. Opening System Preferences..."
                ])
                return
            }
            
            completion(result)
        } else {
            completion(true)
        }
    }
    
    static func requestMicrophoneAccess(completion: @escaping (Bool) -> Void) {
        let authorizationStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        
        switch authorizationStatus {
        case .authorized:
            completion(true)
        case .denied, .restricted:
            // Permission denied - open System Preferences
            openMicrophonePreferences()
            ResponseHandler.returnResponse([
                "code": "PERMISSION_DENIED",
                "message": "Microphone permission denied. Opening System Preferences..."
            ])
            completion(false)
        case .notDetermined:
            // Request permission
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                if granted {
                    completion(true)
                } else {
                    openMicrophonePreferences()
                    ResponseHandler.returnResponse([
                        "code": "PERMISSION_DENIED",
                        "message": "Microphone permission denied. Opening System Preferences..."
                    ])
                    completion(false)
                }
            }
        @unknown default:
            completion(false)
        }
    }
    
    static func openScreenRecordingPreferences() {
        // Open System Preferences to Privacy & Security > Screen Recording
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!
        NSWorkspace.shared.open(url)
    }
    
    static func openMicrophonePreferences() {
        // Open System Preferences to Privacy & Security > Microphone
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!
        NSWorkspace.shared.open(url)
    }
}

class ResponseHandler {
    static func returnResponse(_ response: [String: Any], shouldExitProcess: Bool = true) {
        if let jsonData = try? JSONSerialization.data(withJSONObject: response),
           let jsonString = String(data: jsonData, encoding: .utf8) {
            print(jsonString)
            fflush(stdout)
        } else {
            print("{\"code\": \"JSON_SERIALIZATION_FAILED\"}")
            fflush(stdout)
        }

        if shouldExitProcess {
            exit(0)
        }
    }
}

// https://developer.apple.com/documentation/screencapturekit/capturing_screen_content_in_macos
// For Sonoma updated to https://developer.apple.com/forums/thread/727709
extension CMSampleBuffer {
    var asPCMBuffer: AVAudioPCMBuffer? {
        try? self.withAudioBufferList { audioBufferList, _ -> AVAudioPCMBuffer? in
            guard let absd = self.formatDescription?.audioStreamBasicDescription else { return nil }
            guard let format = AVAudioFormat(standardFormatWithSampleRate: absd.mSampleRate, channels: absd.mChannelsPerFrame) else { return nil }
            return AVAudioPCMBuffer(pcmFormat: format, bufferListNoCopy: audioBufferList.unsafePointer)
        }
    }
}

// Based on https://gist.github.com/aibo-cora/c57d1a4125e145e586ecb61ebecff47c
extension AVAudioPCMBuffer {
    var asSampleBuffer: CMSampleBuffer? {
        let asbd = self.format.streamDescription
        var sampleBuffer: CMSampleBuffer? = nil
        var format: CMFormatDescription? = nil

        guard CMAudioFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            asbd: asbd,
            layoutSize: 0,
            layout: nil,
            magicCookieSize: 0,
            magicCookie: nil,
            extensions: nil,
            formatDescriptionOut: &format
        ) == noErr else { return nil }

        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: Int32(asbd.pointee.mSampleRate)),
            presentationTimeStamp: CMClockGetTime(CMClockGetHostTimeClock()),
            decodeTimeStamp: .invalid
        )

        guard CMSampleBufferCreate(
            allocator: kCFAllocatorDefault,
            dataBuffer: nil,
            dataReady: false,
            makeDataReadyCallback: nil,
            refcon: nil,
            formatDescription: format,
            sampleCount: CMItemCount(self.frameLength),
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 0,
            sampleSizeArray: nil,
            sampleBufferOut: &sampleBuffer
        ) == noErr else { return nil }

        guard CMSampleBufferSetDataBufferFromAudioBufferList(
            sampleBuffer!,
            blockBufferAllocator: kCFAllocatorDefault,
            blockBufferMemoryAllocator: kCFAllocatorDefault,
            flags: 0,
            bufferList: self.mutableAudioBufferList
        ) == noErr else { return nil }

        return sampleBuffer
    }
}

let app = RecorderCLI()
app.executeRecordingProcess()