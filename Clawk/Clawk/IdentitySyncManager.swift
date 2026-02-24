import Foundation
import Combine

// MARK: - Identity Sync Manager
/// Syncs agent identity from OpenClaw workspace files (IDENTITY.md, USER.md)
class IdentitySyncManager: ObservableObject {
    @Published var agentIdentity: AgentIdentity?
    @Published var userProfile: UserProfile?
    @Published var isSyncing = false
    @Published var lastError: String?
    
    private var cancellables = Set<AnyCancellable>()
    private let fileMonitor: FileMonitor
    
    // Paths to OpenClaw workspace files
    private let workspacePath: String
    
    init(workspacePath: String? = nil) {
        self.workspacePath = workspacePath ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".openclaw/workspace")
            .path
        
        self.fileMonitor = FileMonitor(paths: [
            self.workspacePath + "/IDENTITY.md",
            self.workspacePath + "/USER.md"
        ])
        
        // Auto-sync on file changes
        fileMonitor.fileChanged
            .sink { [weak self] path in
                self?.syncIdentity()
            }
            .store(in: &cancellables)
        
        // Initial sync
        syncIdentity()
    }
    
    // MARK: - Sync Methods
    
    func syncIdentity() {
        isSyncing = true
        lastError = nil
        
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self = self else { return }
            
            do {
                let identity = try self.parseIdentityFile()
                let user = try self.parseUserFile()
                
                DispatchQueue.main.async {
                    self.agentIdentity = identity
                    self.userProfile = user
                    self.isSyncing = false
                }
            } catch {
                DispatchQueue.main.async {
                    self.lastError = error.localizedDescription
                    self.isSyncing = false
                }
            }
        }
    }
    
    // MARK: - File Parsing
    
    private func parseIdentityFile() throws -> AgentIdentity {
        let identityPath = workspacePath + "/IDENTITY.md"
        
        guard FileManager.default.fileExists(atPath: identityPath) else {
            // Return default identity if file doesn't exist
            return AgentIdentity(
                name: "Assistant",
                creature: "AI",
                vibe: "Helpful and friendly",
                emoji: "🤖",
                color: "#6B7280"
            )
        }
        
        let content = try String(contentsOfFile: identityPath, encoding: .utf8)
        return parseIdentityMarkdown(content)
    }
    
    private func parseUserFile() throws -> UserProfile {
        let userPath = workspacePath + "/USER.md"
        
        guard FileManager.default.fileExists(atPath: userPath) else {
            return UserProfile(name: nil, preferences: [:])
        }
        
        let content = try String(contentsOfFile: userPath, encoding: .utf8)
        return parseUserMarkdown(content)
    }
    
    private func parseIdentityMarkdown(_ content: String) -> AgentIdentity {
        var name = "Assistant"
        var creature = "AI"
        var vibe: String?
        var emoji = "🤖"
        var color = "#6B7280"
        
        // Parse markdown for identity fields
        let lines = content.components(separatedBy: .newlines)
        
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            
            // Name: usually in first header or bold
            if trimmed.hasPrefix("# ") || trimmed.hasPrefix("**Name:**") {
                if let extracted = extractValue(from: trimmed, after: ["# ", "**Name:**"]) {
                    name = extracted
                }
            }
            
            // Creature
            if trimmed.contains("**Creature:**") || trimmed.contains("**Nature:**") {
                if let extracted = extractValue(from: trimmed, after: ["**Creature:**", "**Nature:**"]) {
                    creature = extracted
                }
            }
            
            // Vibe
            if trimmed.contains("**Vibe:**") || trimmed.contains("**Personality:**") {
                if let extracted = extractValue(from: trimmed, after: ["**Vibe:**", "**Personality:**"]) {
                    vibe = extracted
                }
            }
            
            // Emoji
            if trimmed.contains("**Emoji:**") {
                if let extracted = extractValue(from: trimmed, after: ["**Emoji:**"]) {
                    emoji = extracted
                }
            }
            
            // Color (hex)
            if trimmed.contains("**Color:**") {
                if let extracted = extractValue(from: trimmed, after: ["**Color:**"]),
                   extracted.hasPrefix("#") {
                    color = extracted
                }
            }
        }
        
        return AgentIdentity(
            name: name,
            creature: creature,
            vibe: vibe,
            emoji: emoji,
            color: color
        )
    }
    
    private func parseUserMarkdown(_ content: String) -> UserProfile {
        var name: String?
        var preferences: [String: String] = [:]
        
        let lines = content.components(separatedBy: .newlines)
        
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            
            // User name
            if trimmed.hasPrefix("# ") || trimmed.contains("**Name:**") {
                if let extracted = extractValue(from: trimmed, after: ["# ", "**Name:**"]) {
                    name = extracted
                }
            }
            
            // Preferences (key-value pairs)
            if trimmed.hasPrefix("- ") && trimmed.contains(":") {
                let clean = trimmed.dropFirst(2)
                let parts = clean.split(separator: ":", maxSplits: 1)
                if parts.count == 2 {
                    let key = parts[0].trimmingCharacters(in: .whitespaces)
                    let value = parts[1].trimmingCharacters(in: .whitespaces)
                    preferences[key] = value
                }
            }
        }
        
        return UserProfile(name: name, preferences: preferences)
    }
    
    private func extractValue(from line: String, after prefixes: [String]) -> String? {
        for prefix in prefixes {
            if let range = line.range(of: prefix) {
                var value = String(line[range.upperBound...])
                    .trimmingCharacters(in: .whitespaces)
                
                // Remove markdown bold markers
                value = value.replacingOccurrences(of: "**", with: "")
                value = value.replacingOccurrences(of: "*", with: "")
                
                return value.isEmpty ? nil : value
            }
        }
        return nil
    }
    
    // MARK: - Save Identity
    
    func saveIdentity(_ identity: AgentIdentity) throws {
        let identityPath = workspacePath + "/IDENTITY.md"
        
        let content = """
        # \(identity.name)
        
        **Creature:** \(identity.creature)
        **Vibe:** \(identity.vibe ?? "Helpful")
        **Emoji:** \(identity.emoji)
        **Color:** \(identity.color)
        """
        
        try content.write(toFile: identityPath, atomically: true, encoding: .utf8)
        
        // Trigger sync to update local state
        syncIdentity()
    }
}

// MARK: - File Monitor

class FileMonitor: ObservableObject {
    @Published var fileChanged: AnyPublisher<String, Never>
    
    private var fileObservers: [String: DispatchSourceFileSystemObject] = [:]
    private let fileChangedSubject = PassthroughSubject<String, Never>()
    
    init(paths: [String]) {
        self.fileChanged = fileChangedSubject.eraseToAnyPublisher()
        
        for path in paths {
            startMonitoring(path: path)
        }
    }
    
    private func startMonitoring(path: String) {
        guard FileManager.default.fileExists(atPath: path) else { return }
        
        let fileDescriptor = open(path, O_EVTONLY)
        guard fileDescriptor >= 0 else { return }
        
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fileDescriptor,
            eventMask: [.write, .extend],
            queue: DispatchQueue.global()
        )
        
        source.setEventHandler { [weak self] in
            self?.fileChangedSubject.send(path)
        }
        
        source.setCancelHandler {
            close(fileDescriptor)
        }
        
        source.resume()
        fileObservers[path] = source
    }
    
    deinit {
        for (_, source) in fileObservers {
            source.cancel()
        }
    }
}

// MARK: - Models

struct UserProfile {
    let name: String?
    let preferences: [String: String]
}
