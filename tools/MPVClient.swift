// The socket half of talking to mpv: connecting, reading lines, sending
// commands. The messages themselves are MPV.swift's, which is tested on its
// own; this file is the plumbing around it.
//
// view.sh starts mpv with --input-ipc-server pointing at a socket in the cache
// directory. mpv creates the socket when it starts and drops it when it exits,
// and view.sh restarts mpv on its own for a reconnect, a reset or the settings
// window, so this keeps trying until it gets a connection and reconnects when
// one is lost. The viewer closing is what stops it.

import Foundation

final class MPVClient {
    private let path: String
    private let onMessage: (MPVMessage) -> Void
    private let onConnect: () -> Void

    private var fd: Int32 = -1
    private var reader: DispatchSourceRead?
    private var buffer = Data()
    private var nextID = 1
    private var stopped = false

    init(path: String, onConnect: @escaping () -> Void, onMessage: @escaping (MPVMessage) -> Void) {
        self.path = path
        self.onConnect = onConnect
        self.onMessage = onMessage
    }

    var isConnected: Bool { return fd >= 0 }

    // Tries now and keeps trying: mpv takes a moment to create the socket, and
    // makes a new one each time view.sh restarts it.
    func start() {
        stopped = false
        attempt()
    }

    func stop() {
        stopped = true
        disconnect()
    }

    private func attempt() {
        guard !stopped, fd < 0 else { return }
        if connect() {
            onConnect()
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { self.attempt() }
        }
    }

    private func connect() -> Bool {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let maxPath = MemoryLayout.size(ofValue: address.sun_path)
        guard path.utf8.count < maxPath else {
            NSLog("unifi-viewer: socket path too long: %@", path)
            return false
        }
        _ = withUnsafeMutablePointer(to: &address.sun_path) { raw in
            path.withCString { source in
                raw.withMemoryRebound(to: CChar.self, capacity: maxPath) { destination in
                    strncpy(destination, source, maxPath - 1)
                }
            }
        }

        let socketFD = socket(AF_UNIX, SOCK_STREAM, 0)
        guard socketFD >= 0 else { return false }
        let size = socklen_t(MemoryLayout<sockaddr_un>.size)
        let connected = withUnsafePointer(to: &address) { raw in
            raw.withMemoryRebound(to: sockaddr.self, capacity: 1) { generic in
                Darwin.connect(socketFD, generic, size) == 0
            }
        }
        guard connected else {
            close(socketFD)
            return false
        }

        // Writing to a socket whose other end has gone raises SIGPIPE, which
        // ends the process by default — the menu bar button vanished from
        // every screen when the viewer was moved to another one, because it
        // was still writing as that mpv exited. With this, such a write fails
        // and is handled instead.
        var on: Int32 = 1
        setsockopt(socketFD, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))

        fd = socketFD
        buffer.removeAll()
        let source = DispatchSource.makeReadSource(fileDescriptor: socketFD, queue: .main)
        source.setEventHandler { [weak self] in self?.readAvailable() }
        source.setCancelHandler { close(socketFD) }
        reader = source
        source.resume()
        return true
    }

    private func disconnect() {
        reader?.cancel()          // the cancel handler closes the descriptor
        reader = nil
        fd = -1
        buffer.removeAll()
    }

    private func readAvailable() {
        var chunk = [UInt8](repeating: 0, count: 16 * 1024)
        let count = read(fd, &chunk, chunk.count)
        if count <= 0 {
            // mpv has gone. If the viewer is still open it is restarting, so
            // wait for the new socket.
            disconnect()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { self.attempt() }
            return
        }
        buffer.append(contentsOf: chunk[0..<count])

        while let end = buffer.firstIndex(of: UInt8(ascii: "\n")) {
            let line = String(data: buffer[buffer.startIndex..<end], encoding: .utf8) ?? ""
            buffer.removeSubrange(buffer.startIndex...end)
            if let message = parseMPV(line) {
                onMessage(message)
            }
        }
    }

    // Commands are fire and forget: everything this app needs to know comes
    // back as an event, and a failed command is logged rather than waited for.
    @discardableResult
    func send(_ command: [Any]) -> Bool {
        guard fd >= 0, let line = mpvRequest(command, id: nextID) else { return false }
        nextID += 1
        return line.withCString { text -> Bool in
            let length = strlen(text)
            var sent = 0
            while sent < length {
                let n = write(fd, text + sent, length - sent)
                if n <= 0 { return false }
                sent += n
            }
            return true
        }
    }

    func observe(_ properties: [String]) {
        for (i, property) in properties.enumerated() {
            send(["observe_property", i + 1, property])
        }
    }
}
