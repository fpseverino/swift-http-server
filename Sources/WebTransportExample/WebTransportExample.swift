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

#if HTTP3 && UnstableHTTPDatagrams

import Crypto
import Foundation
import Logging
import NIOHTTP3
import NIOHTTPServer
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

            try await server.serve { request, requestContext, reader, responseSender in
                guard WebTransportHelper.isValidWebTransportRequest(request) else {
                    return try await responseSender.sendAndFinish(.init(status: .forbidden))
                }

                var streamReader = reader
                let maybeDatagramReader = await streamReader.takeDatagramReader()

                guard var datagramReader = maybeDatagramReader else {
                    return try await responseSender.sendAndFinish(.init(status: .notImplemented))
                }

                var streamWriter = try await responseSender.send(WebTransportHelper.makeSuccessResponse(headerFields: request.headerFields))
                if var datagramWriter = await streamWriter.takeDatagramWriter() {
                    try await datagramReader.read { buffer, _ in
                        try await datagramWriter.write(buffer: &buffer)
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
        guard request.extendedConnectProtocol == "webtransport-h3" || request.extendedConnectProtocol == "webtransport" else {
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

#endif  // HTTP3 && UnstableHTTPDatagrams
