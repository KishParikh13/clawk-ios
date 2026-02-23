import Foundation

enum Config {
    // Your Railway URL (or Tailscale IP if running locally)
    static let baseURL = "https://your-app.railway.app"
    
    // Or for Tailscale local:
    // static let baseURL = "http://100.x.x.x:3000"
    
    static var websocketURL: URL {
        var components = URLComponents(string: baseURL)!
        components.scheme = components.scheme == "https" ? "wss" : "ws"
        components.path = "/"
        components.queryItems = [URLQueryItem(name: "token", value: deviceToken)]
        return components.url!
    }
    
    static var apiURL: URL {
        URL(string: baseURL)!
    }
    
    // Generate once and store in Keychain (simplified here)
    static let deviceToken = UserDefaults.standard.string(forKey: "deviceToken") ?? {
        let token = UUID().uuidString
        UserDefaults.standard.set(token, forKey: "deviceToken")
        return token
    }()
}
