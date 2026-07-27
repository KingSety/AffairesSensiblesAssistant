//
//  Network.swift
//  PodcastTranslate
//
//  Created by Sety Tekeu on 7/27/26.
//

import Foundation

struct AIResponse: Decodable {
    let reply: String
}

class Network {
    private let backendURL = URL(string: "https://yourdomain.com")!
    
    /// Sends a prompt to your own backend server rather than OpenAI directly
    func fetchAIResponse(for prompt: String, userToken: String) async throws -> String {
        var request = URLRequest(url: backendURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        
        // 1. Authenticate the iOS client against your backend
        request.setValue("Bearer \(userToken)", forHTTPHeaderField: "Authorization")
        
        let body: [String: Any] = ["prompt": prompt]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        
        // 2. Perform the network request with native TLS validation
        let (data, response) = try await URLSession.shared.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse, (200...299).contains(httpResponse.statusCode) else {
            throw NSError(domain: "NetworkError", code: 0, userInfo: [NSLocalizedDescriptionKey: "Server error"])
        }
        
        // 3. Decode the filtered response from your server
        let decoded = try JSONDecoder().decode(AIResponse.self, from: data)
        return decoded.reply
    }
}
