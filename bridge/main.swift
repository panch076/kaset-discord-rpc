// kaset-discord-bridge
//
// Receives now-playing updates from the Kaset Discord Presence extension over
// loopback HTTP and forwards them to the Discord desktop client over its local
// IPC socket as Rich Presence.

import AppKit
import Darwin
import Foundation
import Network

// MARK: - Config

struct Config: Codable {
    var clientId: String
    var port: UInt16
    var token: String
    /// Clear the presence while playback is paused (otherwise show "Paused").
    var clearOnPause: Bool?
    /// What Discord shows after "Listening to": "name" (app name), "artist" or "title".
    var statusDisplay: String?
    /// Show the current synced lyric line (from LRCLIB) on the second line.
    var lyrics: Bool?
}

let supportDir = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Library/Application Support/KasetDiscordPresence")
let configURL = ProcessInfo.processInfo.environment["KASET_DP_CONFIG"].map { URL(fileURLWithPath: $0) }
    ?? supportDir.appendingPathComponent("config.json")

func log(_ message: String) {
    let stamp = ISO8601DateFormatter().string(from: Date())
    FileHandle.standardError.write("[\(stamp)] \(message)\n".data(using: .utf8)!)
}

func loadConfig() -> Config {
    guard let data = try? Data(contentsOf: configURL),
          let config = try? JSONDecoder().decode(Config.self, from: data),
          !config.clientId.isEmpty
    else {
        log("Missing or invalid config at \(configURL.path). Run install.sh.")
        exit(1)
    }
    return config
}

let config = loadConfig()

let queue = DispatchQueue(label: "kaset-discord-bridge")

// MARK: - Discord IPC

final class DiscordIPC {
    private let clientId: String
    private var fd: Int32 = -1
    private var readSource: DispatchSourceRead?
    private var inbound = Data()
    private(set) var isReady = false
    var onReady: (() -> Void)?

    init(clientId: String) {
        self.clientId = clientId
    }

    var isConnected: Bool { self.fd >= 0 }

    private static func socketDirectories() -> [String] {
        var dirs: [String] = []
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        if confstr(_CS_DARWIN_USER_TEMP_DIR, &buffer, buffer.count) > 0 {
            dirs.append(String(cString: buffer))
        }
        if let tmp = ProcessInfo.processInfo.environment["TMPDIR"] {
            dirs.append(tmp)
        }
        dirs.append("/tmp/")
        return dirs.map { $0.hasSuffix("/") ? $0 : $0 + "/" }
    }

    @discardableResult
    func connect() -> Bool {
        if self.isConnected { return true }
        for dir in Self.socketDirectories() {
            for index in 0..<10 {
                let path = "\(dir)discord-ipc-\(index)"
                guard FileManager.default.fileExists(atPath: path) else { continue }
                if let fd = Self.openSocket(path: path) {
                    self.fd = fd
                    self.startReading()
                    log("Connected to Discord at \(path)")
                    if self.send(opcode: 0, payload: ["v": 1, "client_id": self.clientId]) {
                        return true
                    }
                }
            }
        }
        return false
    }

    private static func openSocket(path: String) -> Int32? {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(path.utf8) + [0]
        guard pathBytes.count <= MemoryLayout.size(ofValue: addr.sun_path) else {
            close(fd)
            return nil
        }
        withUnsafeMutableBytes(of: &addr.sun_path) { $0.copyBytes(from: pathBytes) }
        addr.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        let result = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard result == 0 else {
            close(fd)
            return nil
        }
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        return fd
    }

    private func startReading() {
        let source = DispatchSource.makeReadSource(fileDescriptor: self.fd, queue: queue)
        source.setEventHandler { [weak self] in
            guard let self else { return }
            var buffer = [UInt8](repeating: 0, count: 16384)
            let count = read(self.fd, &buffer, buffer.count)
            if count <= 0 {
                log("Discord closed the connection")
                self.disconnect()
                return
            }
            self.inbound.append(contentsOf: buffer[0..<count])
            self.processInbound()
        }
        source.resume()
        self.readSource = source
    }

    private func processInbound() {
        while self.inbound.count >= 8 {
            let opcode = self.inbound.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 0, as: UInt32.self).littleEndian }
            let length = Int(self.inbound.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 4, as: UInt32.self).littleEndian })
            guard self.inbound.count >= 8 + length else { return }
            let body = self.inbound.subdata(in: 8..<(8 + length))
            self.inbound.removeSubrange(0..<(8 + length))
            let json = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] ?? [:]

            switch opcode {
            case 1: // FRAME
                if json["evt"] as? String == "READY" {
                    log("Discord handshake complete")
                    self.isReady = true
                    self.onReady?()
                } else if json["evt"] as? String == "ERROR" {
                    log("Discord error: \(String(data: body, encoding: .utf8) ?? "?")")
                }
            case 2: // CLOSE
                log("Discord rejected the connection: \(String(data: body, encoding: .utf8) ?? "?")")
                self.disconnect()
                return
            case 3: // PING
                self.send(opcode: 4, data: body)
            default:
                break
            }
        }
    }

    func disconnect() {
        self.readSource?.cancel()
        self.readSource = nil
        if self.fd >= 0 { close(self.fd) }
        self.fd = -1
        self.isReady = false
        self.inbound.removeAll()
    }

    @discardableResult
    func send(opcode: UInt32, payload: [String: Any]) -> Bool {
        guard let data = try? JSONSerialization.data(withJSONObject: payload) else { return false }
        return self.send(opcode: opcode, data: data)
    }

    @discardableResult
    private func send(opcode: UInt32, data: Data) -> Bool {
        guard self.isConnected else { return false }
        var frame = Data()
        withUnsafeBytes(of: opcode.littleEndian) { frame.append(contentsOf: $0) }
        withUnsafeBytes(of: UInt32(data.count).littleEndian) { frame.append(contentsOf: $0) }
        frame.append(data)
        let ok = frame.withUnsafeBytes { raw -> Bool in
            var offset = 0
            while offset < raw.count {
                let written = write(self.fd, raw.baseAddress! + offset, raw.count - offset)
                if written <= 0 { return false }
                offset += written
            }
            return true
        }
        if !ok {
            log("Write to Discord failed")
            self.disconnect()
        }
        return ok
    }

    @discardableResult
    func setActivity(_ activity: [String: Any]?) -> Bool {
        self.send(opcode: 1, payload: [
            "cmd": "SET_ACTIVITY",
            "args": ["pid": Int(getpid()), "activity": activity ?? NSNull()] as [String: Any],
            "nonce": UUID().uuidString,
        ])
    }
}

// MARK: - Presence

struct NowPlaying: Decodable {
    let token: String?
    let source: String
    let title: String
    let artist: String?
    let album: String?
    let artwork: String?
    let videoId: String?
    let playing: Bool
    let position: Double?
    let duration: Double?
}

// MARK: - Lyrics

/// Fetches time-synced lyrics from LRCLIB (https://lrclib.net) and caches them per track.
final class LyricsStore: @unchecked Sendable { // only mutated on `queue`
    struct Line {
        let time: Double
        let text: String
    }

    private var cache: [String: [Line]] = [:] // empty = no synced lyrics found
    private var inFlight: Set<String> = []
    var onLoaded: (() -> Void)?

    private static let bracketNoise = try! NSRegularExpression(
        pattern: #"\s*[\(\[][^\)\]]*\b(feat|ft|from|official|video|audio|lyrics?|remaster(ed)?|visualizer|explicit)\b[^\)\]]*[\)\]]"#,
        options: [.caseInsensitive]
    )
    private static let timeTag = try! NSRegularExpression(pattern: #"\[(\d+):(\d+(?:\.\d+)?)\]"#)

    /// Synced lyrics for the track, or nil if unavailable or still loading.
    func lines(for track: NowPlaying) -> [Line]? {
        let key = "\(track.title)\u{1F}\(track.artist ?? "")"
        if let lines = self.cache[key] { return lines.isEmpty ? nil : lines }
        if !self.inFlight.contains(key) {
            self.inFlight.insert(key)
            Task {
                let lines = await Self.fetch(track)
                queue.async {
                    self.inFlight.remove(key)
                    self.cache[key] = lines
                    log(lines.isEmpty ? "No synced lyrics for \(track.title)" : "Loaded \(lines.count) lyric lines for \(track.title)")
                    if !lines.isEmpty { self.onLoaded?() }
                }
            }
        }
        return nil
    }

    private static func cleanTitle(_ title: String) -> String {
        let range = NSRange(title.startIndex..., in: title)
        return bracketNoise.stringByReplacingMatches(in: title, range: range, withTemplate: "")
            .trimmingCharacters(in: .whitespaces)
    }

    private static func primaryArtist(_ artist: String) -> String {
        var result = artist
        for separator in [", ", " & ", " x ", " feat", " ft.", " ・ "] {
            if let range = result.range(of: separator, options: .caseInsensitive) {
                result = String(result[..<range.lowerBound])
            }
        }
        return result.trimmingCharacters(in: .whitespaces)
    }

    private static func request(_ path: String, _ query: [String: String]) async -> Any? {
        var components = URLComponents(string: "https://lrclib.net/api/\(path)")!
        components.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) }
        var request = URLRequest(url: components.url!, timeoutInterval: 10)
        request.setValue("KasetDiscordPresence/1.0 (https://github.com/sozercan/kaset)", forHTTPHeaderField: "User-Agent")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200
        else { return nil }
        return try? JSONSerialization.jsonObject(with: data)
    }

    static func fetch(_ track: NowPlaying) async -> [Line] {
        let title = cleanTitle(track.title)
        let artist = primaryArtist(track.artist ?? "")
        var query = ["track_name": title, "artist_name": artist]
        if let duration = track.duration, duration > 0 { query["duration"] = String(Int(duration.rounded())) }

        if let exact = await request("get", query) as? [String: Any],
           let synced = exact["syncedLyrics"] as? String {
            return parse(synced)
        }

        // Fall back to a search, preferring a result whose length matches.
        let results = await request("search", ["track_name": title, "artist_name": artist]) as? [[String: Any]] ?? []
        let synced = results.filter { $0["syncedLyrics"] is String }
        let match = synced.first { result in
            guard let duration = track.duration, duration > 0, let other = result["duration"] as? Double else { return false }
            return abs(other - duration) <= 3
        } ?? synced.first
        return (match?["syncedLyrics"] as? String).map(parse) ?? []
    }

    private static func parse(_ lrc: String) -> [Line] {
        var lines: [Line] = []
        for raw in lrc.components(separatedBy: .newlines) {
            let range = NSRange(raw.startIndex..., in: raw)
            let tags = timeTag.matches(in: raw, range: range)
            guard let last = tags.last, let textStart = Range(last.range, in: raw)?.upperBound else { continue }
            var text = raw[textStart...].trimmingCharacters(in: .whitespaces)
            if text.allSatisfy({ "♪♫♬".contains($0) }) { text = "" } // LRCLIB marks instrumental breaks with "♪"
            for tag in tags {
                guard let minutes = Range(tag.range(at: 1), in: raw).flatMap({ Double(raw[$0]) }),
                      let seconds = Range(tag.range(at: 2), in: raw).flatMap({ Double(raw[$0]) })
                else { continue }
                lines.append(Line(time: minutes * 60 + seconds, text: text))
            }
        }
        let sorted = lines.sorted { $0.time < $1.time }
        let skipped = skippedFraction(sorted)
        let fast = skipped > fastSongThreshold
        log(String(format: "Lyrics: %.0f%% of lines would be skipped one at a time — %@", skipped * 100,
                   fast ? "fast song, grouping lines" : "showing one line at a time"))
        return fast ? chunked(sorted) : sorted
    }

    /// Songs where more than this share of lines would be skipped one line at a time
    /// get grouped lines. Slower songs typically skip ≤13%, fast ones ≥35%.
    static let fastSongThreshold = 0.25

    /// Simulates showing one line per update under Discord's rate limit and returns
    /// the share of lines that would never be shown (the next line starts first).
    private static func skippedFraction(_ lines: [Line]) -> Double {
        var lastShown = -Double.infinity
        var total = 0
        var skipped = 0
        for (index, line) in lines.enumerated() {
            let next = index + 1 < lines.count ? lines[index + 1].time : .infinity
            let shownAt = max(line.time, lastShown + minimumChunkDuration)
            let isShown = shownAt < next
            if isShown { lastShown = shownAt }
            guard !line.text.isEmpty else { continue }
            total += 1
            if !isShown { skipped += 1 }
        }
        return total == 0 ? 0 : Double(skipped) / Double(total)
    }

    /// Minimum time each displayed chunk stays up; Discord allows ~5 updates per 20s.
    static let minimumChunkDuration: Double = 4

    /// Groups lines that come in quick succession so no line has to be skipped to
    /// stay under Discord's rate limit. A chunk is shown when its *newest* line
    /// starts, with the lines sung since the previous update before it
    /// ("earlier line / current line"), so text never appears before it's sung.
    private static func chunked(_ lines: [Line]) -> [Line] {
        var chunks: [Line] = []
        var pending: [Line] = []
        var lastShown = -Double.infinity

        func emit(_ group: [Line], at time: Double) {
            var texts = group.map(\.text).filter { !$0.isEmpty }
            // Leave room for "♪ " within Discord's 128-character limit; drop the
            // oldest (already sung) lines first.
            while texts.count > 1, texts.joined(separator: " / ").count > 124 {
                texts.removeFirst()
            }
            chunks.append(Line(time: time, text: texts.joined(separator: " / ")))
            lastShown = time
        }

        for line in lines {
            guard line.time - lastShown >= minimumChunkDuration else {
                pending.append(line)
                continue
            }
            if !pending.isEmpty, line.time - lastShown >= 2 * minimumChunkDuration {
                // Enough room to show the waiting lines on their own first, so they
                // aren't held back until this (much later) line.
                emit(pending, at: lastShown + minimumChunkDuration)
                pending = []
            }
            emit(pending + [line], at: line.time)
            pending = []
        }
        if !pending.isEmpty {
            emit(pending, at: lastShown + minimumChunkDuration)
        }
        return chunks
    }
}

// MARK: - Presence

final class PresenceController {
    private let ipc: DiscordIPC
    private let lyrics = LyricsStore()
    private var latest: [String: (track: NowPlaying, receivedAt: Date)] = [:]
    private var lastSignature: String?
    private var lastLyric: String?
    private var lastStart: Double?
    private var lastSentAt = Date.distantPast
    private var lastConnectAttempt = Date.distantPast
    private let staleAfter: TimeInterval = 30
    /// Discord rate-limits activity updates (~5 per 20s). Lyric chunks are already
    /// spaced ≥4s apart; this guard is slightly lower so tick jitter doesn't delay them.
    private let lyricInterval: TimeInterval = 3.5
    /// Show each lyric slightly early to make up for Discord's display latency.
    private let lyricLead: Double = 0.5

    init(ipc: DiscordIPC) {
        self.ipc = ipc
        ipc.onReady = { [weak self] in
            self?.lastSignature = nil
            self?.update()
        }
        self.lyrics.onLoaded = { [weak self] in self?.update() }
    }

    func receive(_ track: NowPlaying) {
        self.latest[track.source] = (track, Date())
        self.update()
    }

    private var kasetIsRunning: Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: "com.sertacozercan.Kaset").isEmpty
    }

    private func current() -> (NowPlaying, Date)? {
        guard self.kasetIsRunning else {
            self.latest.removeAll()
            return nil
        }
        let now = Date()
        let fresh = self.latest.values.filter { now.timeIntervalSince($0.receivedAt) < self.staleAfter }
        let byRecency = fresh.sorted { $0.receivedAt > $1.receivedAt }
        if let playing = byRecency.first(where: { $0.track.playing }) {
            return (playing.track, playing.receivedAt)
        }
        if config.clearOnPause == false, let paused = byRecency.first {
            return (paused.track, paused.receivedAt)
        }
        return nil
    }

    /// The lyric line at `position`: nil when there are no synced lyrics, "" before the first line.
    private func lyric(for track: NowPlaying, at position: Double) -> String? {
        guard config.lyrics != false, track.source == "music", track.playing,
              let lines = self.lyrics.lines(for: track)
        else { return nil }
        return lines.last { $0.time <= position + self.lyricLead }?.text ?? ""
    }

    func update() {
        if !self.ipc.isConnected {
            guard Date().timeIntervalSince(self.lastConnectAttempt) >= 5 else { return }
            self.lastConnectAttempt = Date()
            self.ipc.connect()
            return
        }
        guard self.ipc.isReady else { return }

        guard let (track, receivedAt) = self.current() else {
            if self.lastSignature != "none" {
                if self.ipc.setActivity(nil) {
                    self.lastSignature = "none"
                    self.lastStart = nil
                    log("Cleared presence")
                }
            }
            return
        }

        // Start time derived from the latest report; small drift is ignored so we
        // don't hit Discord's rate limit every heartbeat.
        let position = (track.position ?? 0) + (track.playing ? Date().timeIntervalSince(receivedAt) : 0)
        let start = Date().timeIntervalSince1970 - position
        let lyric = self.lyric(for: track, at: position)
        let signature = [track.source, track.title, track.artist ?? "", track.album ?? "",
                         track.artwork ?? "", String(track.playing), String(Int(track.duration ?? 0)),
                         String(lyric != nil)]
            .joined(separator: "\u{1F}")
        let trackChanged = signature != self.lastSignature
        let seeked = self.lastStart.map { abs($0 - start) >= 2 } ?? true
        let lyricChanged = lyric != self.lastLyric
        if !trackChanged, !seeked {
            guard lyricChanged, Date().timeIntervalSince(self.lastSentAt) >= self.lyricInterval else { return }
        }

        if self.ipc.setActivity(Self.activity(for: track, start: start, lyric: lyric)) {
            if trackChanged {
                log("Presence: \(track.playing ? "▶" : "⏸") \(track.title) — \(track.artist ?? "")")
            }
            self.lastSignature = signature
            self.lastLyric = lyric
            self.lastStart = start
            self.lastSentAt = Date()
        }
    }

    private static func field(_ value: String?) -> String? {
        guard var text = value?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        if text.count > 128 { text = String(text.prefix(127)) + "…" }
        if text.count < 2 { text += "\u{200B}" }
        return text
    }

    private static func activity(for track: NowPlaying, start: Double, lyric: String?) -> [String: Any] {
        let isMusic = track.source == "music"
        var activity: [String: Any] = [
            "type": isMusic ? 2 : 3, // 2 = Listening, 3 = Watching
            "status_display_type": ["artist": 1, "title": 2][config.statusDisplay ?? "", default: 0],
            "instance": false,
        ]
        if let lyric {
            // Lyrics take the second line, so the artist moves up next to the title.
            let artist = track.artist.map { " — \($0)" } ?? ""
            activity["details"] = field(track.title + artist)
            activity["state"] = field(lyric.isEmpty ? "♪" : "♪ \(lyric)")
        } else {
            activity["details"] = field(track.title)
            if let artist = field(track.artist) {
                activity["state"] = track.playing ? artist : field("Paused · \(artist)")
            } else if !track.playing {
                activity["state"] = "Paused"
            }
        }

        var assets: [String: Any] = [:]
        if let artwork = track.artwork, artwork.hasPrefix("https://"), artwork.count <= 256 {
            assets["large_image"] = artwork
        } else if let id = track.videoId {
            assets["large_image"] = "https://i.ytimg.com/vi/\(id)/hqdefault.jpg"
        }
        if let largeText = field(track.album) ?? field(track.title) {
            assets["large_text"] = largeText
        }
        if !assets.isEmpty { activity["assets"] = assets }

        if track.playing, let duration = track.duration, duration > 0 {
            let startMs = Int(start * 1000)
            activity["timestamps"] = ["start": startMs, "end": startMs + Int(duration * 1000)]
        }

        if let id = track.videoId, !id.isEmpty {
            activity["buttons"] = [[
                "label": isMusic ? "Listen on YouTube Music" : "Watch on YouTube",
                "url": isMusic ? "https://music.youtube.com/watch?v=\(id)" : "https://www.youtube.com/watch?v=\(id)",
            ]]
        }
        return activity
    }
}

// MARK: - Lyrics preview

// `kaset-discord-bridge --lyrics "<title>" "<artist>" [duration]` prints the lyric
// chunks that would be shown, for troubleshooting.
if CommandLine.arguments.count >= 4, CommandLine.arguments[1] == "--lyrics" {
    let args = CommandLine.arguments
    let track = NowPlaying(token: nil, source: "music", title: args[2], artist: args[3], album: nil,
                           artwork: nil, videoId: nil, playing: true, position: 0,
                           duration: args.count > 4 ? Double(args[4]) : nil)
    Task {
        let chunks = await LyricsStore.fetch(track)
        if chunks.isEmpty { print("No synced lyrics found") }
        for chunk in chunks {
            print(String(format: "%6.2f  ", chunk.time) + (chunk.text.isEmpty ? "♪" : "♪ \(chunk.text)"))
        }
        exit(0)
    }
    dispatchMain()
}

// MARK: - HTTP server

let ipc = DiscordIPC(clientId: config.clientId)
let presence = PresenceController(ipc: ipc)

func respond(_ connection: NWConnection, status: String, body: String = "") {
    let response = "HTTP/1.1 \(status)\r\n"
        + "Access-Control-Allow-Origin: *\r\n"
        + "Access-Control-Allow-Methods: GET, POST, OPTIONS\r\n"
        + "Access-Control-Allow-Headers: Content-Type\r\n"
        + "Content-Type: application/json\r\n"
        + "Content-Length: \(body.utf8.count)\r\n"
        + "Connection: close\r\n\r\n" + body
    connection.send(content: response.data(using: .utf8), completion: .contentProcessed { _ in connection.cancel() })
}

func handle(_ connection: NWConnection, method: String, path: String, body: Data) {
    switch (method, path) {
    case ("OPTIONS", _):
        respond(connection, status: "204 No Content")
    case ("GET", "/health"):
        respond(connection, status: "200 OK", body: "{\"ok\":true,\"discord\":\(ipc.isReady)}")
    case ("POST", "/presence"):
        guard let track = try? JSONDecoder().decode(NowPlaying.self, from: body) else {
            respond(connection, status: "400 Bad Request")
            return
        }
        guard track.token == config.token else {
            respond(connection, status: "403 Forbidden")
            return
        }
        presence.receive(track)
        respond(connection, status: "204 No Content")
    default:
        respond(connection, status: "404 Not Found")
    }
}

func receive(on connection: NWConnection, buffer: Data) {
    connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, isComplete, error in
        var buffer = buffer
        if let data { buffer.append(data) }
        if buffer.count > 1_000_000 {
            connection.cancel()
            return
        }
        if let headerEnd = buffer.range(of: Data("\r\n\r\n".utf8)) {
            let header = String(decoding: buffer[..<headerEnd.lowerBound], as: UTF8.self)
            let lines = header.components(separatedBy: "\r\n")
            let requestLine = lines.first?.split(separator: " ") ?? []
            let contentLength = lines.dropFirst().compactMap { line -> Int? in
                let parts = line.split(separator: ":", maxSplits: 1)
                guard parts.count == 2, parts[0].lowercased() == "content-length" else { return nil }
                return Int(parts[1].trimmingCharacters(in: .whitespaces))
            }.first ?? 0
            let body = buffer[headerEnd.upperBound...]
            if requestLine.count >= 2, body.count >= contentLength {
                let path = String(requestLine[1].split(separator: "?").first ?? "")
                handle(connection, method: String(requestLine[0]), path: path, body: Data(body.prefix(contentLength)))
                return
            }
        }
        if isComplete || error != nil {
            connection.cancel()
        } else {
            receive(on: connection, buffer: buffer)
        }
    }
}

let parameters = NWParameters.tcp
parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: config.port)!)
parameters.allowLocalEndpointReuse = true
let listener: NWListener
do {
    listener = try NWListener(using: parameters)
} catch {
    log("Could not listen on 127.0.0.1:\(config.port): \(error)")
    exit(1)
}
listener.newConnectionHandler = { connection in
    connection.start(queue: queue)
    receive(on: connection, buffer: Data())
}
listener.stateUpdateHandler = { state in
    switch state {
    case .ready: log("Listening on 127.0.0.1:\(config.port)")
    case let .failed(error):
        log("Listener failed: \(error)")
        exit(1)
    default: break
    }
}
listener.start(queue: queue)

let timer = DispatchSource.makeTimerSource(queue: queue)
timer.schedule(deadline: .now(), repeating: 1)
timer.setEventHandler { presence.update() }
timer.resume()

signal(SIGPIPE, SIG_IGN)
dispatchMain()
