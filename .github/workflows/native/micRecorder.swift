import Foundation
import AVFoundation

class StreamRecorder {
    let audioEngine = AVAudioEngine()
    let outputFormat: AVAudioFormat

    init() {
        let inputNode = audioEngine.inputNode
        outputFormat = inputNode.inputFormat(forBus: 0)
    }

    func startStreaming() throws {
        // On macOS, we don't need to configure AVAudioSession
        // Just check microphone permission using AVCaptureDevice
        
        // Request microphone permission for macOS
        let authorizationStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        
        switch authorizationStatus {
        case .denied, .restricted:
            let error = NSError(domain: "StreamRecorder", code: 1, userInfo: [NSLocalizedDescriptionKey: "Microphone access denied. Please enable microphone access in System Preferences > Security & Privacy > Privacy > Microphone"])
            print("{\"error\":\"Microphone permission denied\"}")
            throw error
        case .notDetermined:
            let semaphore = DispatchSemaphore(value: 0)
            AVCaptureDevice.requestAccess(for: .audio) { allowed in
                if !allowed {
                    print("{\"error\":\"Microphone permission denied\"}")
                }
                semaphore.signal()
            }
            _ = semaphore.wait(timeout: .now() + 5.0)
            
            // Check again after permission request
            if AVCaptureDevice.authorizationStatus(for: .audio) != .authorized {
                let error = NSError(domain: "StreamRecorder", code: 1, userInfo: [NSLocalizedDescriptionKey: "Microphone access denied"])
                throw error
            }
        case .authorized:
            break
        @unknown default:
            break
        }

        let inputNode = audioEngine.inputNode
        let bus = 0

        inputNode.installTap(onBus: bus, bufferSize: 1024, format: outputFormat) { buffer, _ in
            // Access raw PCM audio data from buffer
            guard let channelData = buffer.floatChannelData else { return }
            let channelCount = Int(buffer.format.channelCount)
            let frameLength = Int(buffer.frameLength)

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

            // Write raw PCM float32 data to stdout
            FileHandle.standardOutput.write(data)
            fflush(stdout) // flush immediately
        }

        do {
            try audioEngine.start()
            
            // Add a small delay to allow audio engine to stabilize
            // This prevents noise in the first chunk
            Thread.sleep(forTimeInterval: 0.1)
            
            print("{\"status\":\"streaming_started\"}")
            RunLoop.main.run()
        } catch {
            print("{\"error\":\"Failed to start audio engine: \(error.localizedDescription)\"}")
            throw error
        }
    }

    func stopStreaming() {
        // On macOS, we don't need to manage AVAudioSession
        audioEngine.inputNode.removeTap(onBus: 0)
        audioEngine.stop()
        print("{\"status\":\"streaming_stopped\"}")
        exit(0)
    }
}

// Main CLI

let args = CommandLine.arguments
let recorder = StreamRecorder()

if args.count >= 2 {
    let command = args[1]

    if command == "start" {
        do {
            try recorder.startStreaming()
        } catch {
            print("{\"error\":\"\(error.localizedDescription)\"}")
            exit(1)
        }
    } else if command == "stop" {
        recorder.stopStreaming()
    } else {
        print("{\"error\":\"Invalid command\"}")
        exit(1)
    }
} else {
    print("{\"error\":\"No command provided\"}")
    exit(1)
}
