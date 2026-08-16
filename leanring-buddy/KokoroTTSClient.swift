//
//  KokoroTTSClient.swift
//  leanring-buddy
//
//  OpenAI-compatible client for Kokoro TTS server.
//  Requires a local Kokoro API server running on port 8880.
//

import AVFoundation
import Foundation

class KokoroTTSClient: NSObject, AVAudioPlayerDelegate, ObservableObject {
    @Published var isPlaying = false
    
    private var audioPlayer: AVAudioPlayer?
    
    // Using wav format as requested
    private let url = URL(string: "http://127.0.0.1:8880/v1/audio/speech")!
    
    func healthCheck() async -> Bool {
        guard let healthURL = URL(string: "http://127.0.0.1:8880/health") else { return false }
        var request = URLRequest(url: healthURL)
        request.httpMethod = "GET"
        request.timeoutInterval = 2.0
        
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 {
                return true
            }
            // Fallback: any HTTP response from base URL
            let baseRequest = URLRequest(url: URL(string: "http://127.0.0.1:8880")!, timeoutInterval: 2.0)
            let (_, baseResponse) = try await URLSession.shared.data(for: baseRequest)
            return (baseResponse as? HTTPURLResponse) != nil
        } catch {
            // Check fallback
            do {
                let baseRequest = URLRequest(url: URL(string: "http://127.0.0.1:8880")!, timeoutInterval: 2.0)
                let (_, baseResponse) = try await URLSession.shared.data(for: baseRequest)
                return (baseResponse as? HTTPURLResponse) != nil
            } catch {
                return false
            }
        }
    }
    
    func speakText(_ text: String) async -> Bool {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return true }
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")
        
        let payload: [String: Any] = [
            "input": text,
            "voice": "af_heart",
            "response_format": "wav"
        ]
        
        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: payload)
            let (data, response) = try await URLSession.shared.data(for: request)
            
            guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
                print("⚠️ Kokoro TTS API error: HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)")
                return false
            }
            
            var success = false
            await MainActor.run {
                do {
                    self.audioPlayer = try AVAudioPlayer(data: data)
                    self.audioPlayer?.delegate = self
                    self.audioPlayer?.play()
                    self.isPlaying = true
                    success = true
                } catch {
                    print("⚠️ Failed to play Kokoro TTS audio: \(error.localizedDescription)")
                }
            }
            return success
        } catch {
            print("⚠️ Kokoro TTS request failed: \(error.localizedDescription)")
            return false
        }
    }
    
    func stopPlayback() {
        audioPlayer?.stop()
        isPlaying = false
    }
    
    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        DispatchQueue.main.async {
            self.isPlaying = false
        }
    }
}
