// Rune Weaver Core — Unix Domain Socket HTTP 1.1 client.

import Foundation

#if canImport(Darwin)
    import Darwin
#endif

/// Lightweight Unix Domain Socket HTTP client for communicating with local services like `llama-server`.
public enum UnixSocketHTTPClient {
    /// Sends an HTTP request over a Unix domain socket and returns the response body Data. -
    /// Parameters: - socketPath: Path to the AF_UNIX socket.
    public static func send(
        socketPath: String,
        method: String = "POST",
        path: String,
        body: Data? = nil,
        contentType: String? = "application/json",
        timeoutSeconds: Int = 15
    ) throws -> Data {
        #if canImport(Darwin)
            let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
            guard fd >= 0 else {
                throw EmbeddingsError.unavailable
            }
            defer { Darwin.close(fd) }

            var timeout = timeval(tv_sec: timeoutSeconds, tv_usec: 0)
            Darwin.setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
            Darwin.setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

            var addr = sockaddr_un()
            addr.sun_family = sa_family_t(AF_UNIX)
            let pathBytes = socketPath.utf8CString
            guard pathBytes.count <= MemoryLayout.size(ofValue: addr.sun_path) else {
                throw EmbeddingsError.unavailable
            }
            withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
                let rawPtr = UnsafeMutableRawPointer(ptr)
                pathBytes.withUnsafeBytes { src in
                    rawPtr.copyMemory(from: src.baseAddress!, byteCount: src.count)
                }
            }

            let connectResult = withUnsafePointer(to: &addr) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockAddr in
                    Darwin.connect(fd, sockAddr, socklen_t(MemoryLayout<sockaddr_un>.size))
                }
            }
            guard connectResult == 0 else {
                throw EmbeddingsError.unavailable
            }

            let bodyData = body ?? Data()
            var headerString = "\(method) \(path) HTTP/1.1\r\n"
            headerString += "Host: localhost\r\n"
            if let contentType, !bodyData.isEmpty {
                headerString += "Content-Type: \(contentType)\r\n"
            }
            if !bodyData.isEmpty || method == "POST" {
                headerString += "Content-Length: \(bodyData.count)\r\n"
            }
            headerString += "Connection: close\r\n\r\n"

            guard let headerData = headerString.data(using: .utf8) else {
                throw EmbeddingsError.invalidInput
            }

            var toSend = headerData
            toSend.append(bodyData)

            let totalToSend = toSend.count
            var sentSoFar = 0
            try toSend.withUnsafeBytes { buffer in
                while sentSoFar < totalToSend {
                    if Task.isCancelled {
                        throw CancellationError()
                    }
                    let chunk = Darwin.write(fd, buffer.baseAddress! + sentSoFar, totalToSend - sentSoFar)
                    if chunk <= 0 {
                        if errno == EINTR {
                            continue
                        }
                        if errno == EAGAIN || errno == EWOULDBLOCK || errno == ETIMEDOUT {
                            throw EmbeddingsError.unavailable
                        }
                        throw EmbeddingsError.embeddingFailed
                    }
                    sentSoFar += chunk
                }
            }

            // Read response until EOF
            var rawResponse = Data()
            var readBuffer = [UInt8](repeating: 0, count: 4096)
            while true {
                if Task.isCancelled {
                    throw CancellationError()
                }
                let bytesRead = Darwin.read(fd, &readBuffer, readBuffer.count)
                if bytesRead < 0 {
                    if errno == EINTR {
                        continue
                    }
                    if errno == EAGAIN || errno == EWOULDBLOCK || errno == ETIMEDOUT {
                        throw EmbeddingsError.unavailable
                    }
                    throw EmbeddingsError.embeddingFailed
                }
                if bytesRead == 0 {
                    break
                }
                rawResponse.append(readBuffer, count: bytesRead)
            }

            // Split HTTP headers and body (separated by \r\n\r\n)
            let separator = Data([0x0D, 0x0A, 0x0D, 0x0A])
            guard let range = rawResponse.range(of: separator) else {
                throw EmbeddingsError.embeddingFailed
            }

            let headerSubdata = rawResponse.subdata(in: 0 ..< range.lowerBound)
            let headerText = String(data: headerSubdata, encoding: .utf8) ?? ""
            let statusLine = headerText.components(separatedBy: "\r\n").first ?? ""
            if statusLine.contains(" 503 ") || statusLine.contains(" 500 ") {
                throw EmbeddingsError.unavailable
            }

            return rawResponse.subdata(in: range.upperBound ..< rawResponse.count)
        #else
            throw EmbeddingsError.unavailable
        #endif
    }

    /// Probes health of a service listening on a Unix domain socket.
    public static func probeHealth(socketPath: String, path: String = "/health") -> Bool {
        guard FileManager.default.fileExists(atPath: socketPath) else { return false }
        do {
            let data = try send(
                socketPath: socketPath,
                method: "GET",
                path: path,
                body: nil,
                contentType: nil,
                timeoutSeconds: 2
            )
            let responseString = String(data: data, encoding: .utf8) ?? ""
            return responseString.contains("\"ok\"") || responseString.contains("200") || !data.isEmpty
        } catch {
            return false
        }
    }
}
