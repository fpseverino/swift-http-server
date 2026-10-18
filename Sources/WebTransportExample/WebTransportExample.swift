//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift HTTP Server open source project
//
// Copyright (c) 2026 Apple Inc. and the Swift HTTP Server project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of Swift HTTP Server project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

#if UnstableWebTransport

import Foundation
import Logging
import NIOCore
import NIOHTTP3
import NIOHTTPServer
import NIOQUIC
import NIOQUICHelpers
import X509

@main
@available(anyAppleOS 27.0, *)
struct WebTransportExample {
    static func main() async throws {
        try await serve()
    }

    @concurrent
    static func serve() async throws {
        var rootLogger = Logger(label: "WebTransportExample")
        rootLogger.logLevel = .debug

        try await withLogger(rootLogger) { _ in
            let server = NIOHTTPServer(
                configuration: try .init(
                    bindTarget: .hostAndPort(host: "127.0.0.1", port: 12345),
                    supportedHTTPVersions: [.http3],
                    transportSecurity: .tls(credentials: .http3())
                )
            )

            try await server.serve { connection, requestContext in
                guard let webTransportStreamCreator = try await connection.webTransportStreamCreator else {
                    fatalError("QUIC stream creator is not available")
                }

                await connection.handleRequests { request, requestContext, reader, responseSender in
                    guard WebTransportHelper.isValidWebTransportRequest(request) else {
                        return try await responseSender.sendAndFinish(.init(status: .forbidden))
                    }

                    var streamReader = reader
                    guard let datagramReader = await streamReader.takeDatagramReader() else {
                        return try await responseSender.sendAndFinish(.init(status: .notImplemented))
                    }

                    // let streamReaderBox = RefBox(value: Disconnected(value: streamReader))
                    let datagramReaderBox = RefBox(value: Disconnected(value: datagramReader))

                    var streamWriter = try await responseSender.send(
                        WebTransportHelper.makeSuccessResponse(headerFields: request.headerFields)
                    )
                    let datagramWriter = await streamWriter.takeDatagramWriter()

                    // let streamWriterBox = RefBox(value: Disconnected(value: streamWriter))
                    let datagramWriterBox = RefBox(value: Disconnected(value: datagramWriter))

                    // Give some time for the response to be fully sent
                    try await Task.sleep(for: .seconds(1))

                    await withThrowingTaskGroup { group in
                        var unwrappedDatagramReader = datagramReaderBox.unbox().take()
                        var disconnectedDatagramWriter = datagramWriterBox.unbox()
                        if var unwrappedDatagramWriter = disconnectedDatagramWriter.swap(newValue: nil) {
                            group.addTask {
                                try await unwrappedDatagramReader.read { buffer, _ in
                                    try await unwrappedDatagramWriter.write(buffer: &buffer)
                                }
                            }
                        }

                        group.addTask {
                            try await webTransportStreamCreator.withUnidirectionalStream(
                                requestContext: requestContext
                            ) { outbound in
                                try await outbound.write(ByteBuffer(string: "opened"))
                            }
                        }

                        group.addTask {
                            try await webTransportStreamCreator.withBidirectionalStream(
                                requestContext: requestContext
                            ) { inbound, outbound in
                                try await outbound.write(ByteBuffer(string: "opened"))
                                for try await message in inbound {
                                    try await outbound.write(message)
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}

@available(anyAppleOS 27.0, *)
enum WebTransportHelper {
    /// Validate that `request` corresponds to a valid WebTransport over HTTP/3 request.
    static func isValidWebTransportRequest(_ request: HTTPRequest) -> Bool {
        guard request.method == .connect else {
            return false
        }

        // Support "webtransport" upgrade token for backward compatibility with older drafts.
        // TODO: remove support for "webtransport" upgrade token
        guard request.extendedConnectProtocol == "webtransport-h3" || request.extendedConnectProtocol == "webtransport"
        else {
            return false
        }

        return true
    }

    /// Returns a success response to accept the WebTransport session.
    static func makeSuccessResponse(headerFields: HTTPFields) -> HTTPResponse {
        let headers: HTTPFields =
            if let wtProtocol = headerFields[values: .webTransportAvailableProtocols].first {
                [.webTransportProtocol: wtProtocol]
            } else {
                [:]
            }
        return HTTPResponse(status: .ok, headerFields: headers)
    }
}

extension HTTPField.Name {
    /// WT-Protocol
    ///
    /// https://datatracker.ietf.org/doc/draft-ietf-webtrans-http3/
    static var webTransportProtocol: Self {
        Self("WT-Protocol")!
    }
    /// WT-Available-Protocols
    ///
    /// https://datatracker.ietf.org/doc/draft-ietf-webtrans-http3/
    static var webTransportAvailableProtocols: Self {
        Self("WT-Available-Protocols")!
    }
}

@available(anyAppleOS 27.0, *)
extension NIOHTTPServerConfiguration.TransportSecurity.TLSCredentials {
    /// PEM-file X.509 credentials supported by SwiftNIO HTTP/3.
    fileprivate static func http3() -> Self {
        guard
            let certificateURL = Bundle.module.url(forResource: "http3", withExtension: "crt"),
            let privateKeyURL = Bundle.module.url(forResource: "http3", withExtension: "key")
        else {
            fatalError("Failed to locate certificate or private key")
        }

        return .x509(.pemFile(certificateChainPath: certificateURL.path(), privateKeyPath: privateKeyURL.path()))
    }
}

// This is a helper type to move a non-Sendable value across isolation regions.
@usableFromInline
struct Disconnected<Value: ~Copyable>: ~Copyable, Sendable {
    // This is safe since we take the value as sending and take consumes it
    // and returns it as sending.
    private nonisolated(unsafe) var value: Value?

    @usableFromInline
    init(value: consuming sending Value) {
        unsafe self.value = .some(value)
    }

    @usableFromInline
    consuming func take() -> sending Value {
        nonisolated(unsafe) let value = unsafe self.value.take()!
        return unsafe value
    }

    @usableFromInline
    mutating func swap(newValue: consuming sending Value) -> sending Value {
        nonisolated(unsafe) let value = unsafe self.value.take()!
        unsafe self.value = consume newValue
        return unsafe value
    }
}

/// A Copyable, Sendable box for transferring a ~Copyable value across escaping
/// closure boundaries.
///
/// Store a ~Copyable value with ``init(value:)``, then retrieve it exactly once
/// with ``unbox()``.
// TODO: Remove RefBox once Swift gains "called once" closures (SE-0528 future direction).
// Until then, ~Copyable values cannot be captured by @escaping closures (like addTask),
// so this class provides a Copyable + Sendable wrapper for cross-task transfer.
final class RefBox<Value: ~Copyable> {
    private nonisolated(unsafe) var value: Value?

    public init(value: consuming Value) {
        unsafe self.value = consume value
    }

    public consuming func unbox() -> Value {
        unsafe value.take()!
    }
}
extension RefBox: Sendable where Value: Sendable & ~Copyable {}

#endif  // HTTP3 && UnstableHTTPDatagrams
