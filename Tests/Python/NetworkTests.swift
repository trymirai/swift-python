//
//  Created by Anton Spivak
//

import _NIOFileSystem
import Foundation
import Python
import SystemPackage
import Testing

@Test(.timeLimit(.minutes(1)))
func socketsPreserveStandardDescriptorAndCloseSemantics() async throws {
    let session = try await Python::Runtime().session()
    defer { await session.close() }
    _ = try await session.evaluate("""
    import socket

    left, right = socket.socketpair()
    left.setblocking(True)
    assert left.gettimeout() is None
    right.sendall(b'ping')
    assert left.recv(4) == b'ping'
    duplicate = left.dup()
    left.close()
    descriptor = duplicate.detach()
    assert duplicate.fileno() == -1
    transferred = socket.socket(fileno=descriptor)
    right.sendall(b'pong')
    assert transferred.recv(4) == b'pong'
    alias = socket.socket(fileno=transferred.fileno())
    assert transferred.fileno() == descriptor
    assert alias.detach() == descriptor
    native_duplicate = socket.dup(descriptor)
    socket.close(native_duplicate)
    transferred.setblocking(False)
    try:
        transferred.recv(1)
    except BlockingIOError:
        pass
    else:
        raise AssertionError('Nonblocking read waited for data')
    """)
    _ = try await #require(throws: Python::ExecutionError.self) {
        try await session.evaluate("transferred.close()\nraise ValueError('closed')")
    }
    let result = try await session.evaluate("""
    assert transferred.fileno() == -1
    assert right.recv(1) == b''
    right.close()
    """)
    #expect(result.end == .finished)
}

@Test(.timeLimit(.minutes(1)), arguments: [false, true])
func tcpSocketsConnectAcceptAndExchangeData(timeout: Bool) async throws {
    let session = try await Python::Runtime().session()
    defer { await session.close() }
    try await session.set(timeout, forKey: "use_timeout")
    let result = try await session.evaluate("""
    import socket

    listener = socket.socket()
    listener.bind(('127.0.0.1', 0))
    listener.listen()
    client = socket.create_connection(listener.getsockname(), timeout=5 if use_timeout else None)
    accepted, address = listener.accept()
    listener.close()
    client.sendall(b'ping')
    assert accepted.recv(4) == b'ping'
    accepted.sendall(b'pong')
    assert client.recv(4) == b'pong'
    client.close()
    accepted.close()
    """)
    #expect(result.end == .finished)
}

@Test(.timeLimit(.minutes(1)))
func socketsTransferDescriptorsUsingStandardAncillaryData() async throws {
    let session = try await Python::Runtime().session()
    defer { await session.close() }
    let result = try await session.evaluate("""
    import socket

    left, right = socket.socketpair()
    sender, receiver = socket.socketpair()
    with left, right, sender, receiver:
        assert socket.send_fds(sender, [b'x'], [left.fileno()]) == 1
        message, descriptors, flags, address = socket.recv_fds(receiver, 1, 1)
        assert message == b'x' and len(descriptors) == 1
        with socket.socket(fileno=descriptors[0]) as transferred:
            right.sendall(b'ping')
            assert transferred.recv(4) == b'ping'
    """)
    #expect(result.end == .finished)
}

@Test(.timeLimit(.minutes(1)), arguments: [false, true])
func socketWaitsObserveInterruption(timeout: Bool) async throws {
    let session = try await Python::Runtime().session()
    defer { await session.close() }
    _ = try await session.evaluate("import socket; left, right = socket.socketpair()")
    try await expectReadInterruption(
        in: session,
        source: "print('waiting'); left.recv(1)",
        timeout: timeout,
    )
    let result = try await session
        .evaluate("right.sendall(b'x'); assert left.recv(1) == b'x'; left.close(); right.close()")
    #expect(result.end == .finished)
}

@Test(.timeLimit(.minutes(1)))
func tlsConnectionsKeepTheirActualStateAfterErrors() async throws {
    try await withTemporaryDirectory { root in
        let runtime = try await Python::Runtime()
        let server = try await runtime.session(delegate: FileAccessDelegate { _ in false })
        let client = try await runtime.session()
        defer {
            await client.close()
            await server.close()
        }
        let (port, serving) = try await startTLSServer(in: server, directory: root)
        defer { serving.cancel() }
        try await connectTLSClient(in: client, port: port)

        _ = try await #require(throws: Python::ExecutionError.self) {
            try await client
                .evaluate(
                    "connection.sendall(b'ping'); assert connection.recv(4) == b'PING'; marker = 42; raise ValueError('state remains')",
                )
        }
        _ = try await client
            .evaluate(
                "assert marker == 42; connection.sendall(b'pong'); assert connection.recv(4) == b'PONG'",
            )
        _ = try await #require(throws: Python::ExecutionError.self) {
            try await client.evaluate("connection.close(); raise ValueError('closed')")
        }
        let closed = try await client
            .evaluate("assert connection.fileno() == -1; assert connection._sslobj is None")
        #expect(closed.end == .finished)
        #expect(try await serving.value.end == .finished)
        try await client.reset()
        #expect(try await client.evaluate("assert 'connection' not in globals()").end == .finished)
    }
}

@Test(.timeLimit(.minutes(1)), arguments: [false, true])
func tlsReadsObserveInterruption(timeout: Bool) async throws {
    try await withTemporaryDirectory { root in
        let runtime = try await Python::Runtime()
        let server = try await runtime.session()
        let client = try await runtime.session()
        defer {
            await client.close()
            await server.close()
        }
        let (port, serving) = try await startTLSServer(in: server, directory: root)
        defer { serving.cancel() }
        try await connectTLSClient(in: client, port: port)

        try await expectReadInterruption(
            in: client,
            source: "connection.settimeout(None); print('waiting'); connection.recv(1)",
            timeout: timeout,
        )
        _ = try await client.evaluate("connection.close()")
        #expect(try await serving.value.end == .finished)
    }
}

private func expectReadInterruption(
    in session: Python::Session,
    source: String,
    timeout: Bool,
    sourceLocation: SourceLocation = #_sourceLocation,
) async throws {
    let started = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
    defer { started.continuation.finish() }

    let task = Task {
        try await session.evaluate(source, timeout: timeout ? .seconds(1) : nil) { stream, text in
            if stream == .stdout, text.contains("waiting") {
                started.continuation.yield(())
            }
        }
    }
    defer { task.cancel() }

    _ = try await #require(nextSignal(from: started.stream), sourceLocation: sourceLocation)
    if !timeout {
        task.cancel()
    }
    #expect(
        try await task.value.end == (timeout ? .timedOut : .stopped),
        sourceLocation: sourceLocation,
    )
}

private func connectTLSClient(in session: Python::Session, port: Int) async throws {
    try await session.set(port, forKey: "port")
    try await session.set(networkCertificate, forKey: "certificate")
    _ = try await session.evaluate(tlsClientSource)
}

private func startTLSServer(
    in session: Python::Session,
    directory: FilePath,
) async throws -> (Int, Task<Python::Execution, any Error>) {
    let certificate = directory.appending("certificate.pem")
    let key = directory.appending("key.pem")
    try await (networkCertificate + "\n").write(toFileAt: certificate)
    try await (networkPrivateKey + "\n").write(toFileAt: key)
    try await session.set(certificate.string, forKey: "certificate_path")
    try await session.set(key.string, forKey: "key_path")

    let started = AsyncStream<Int>.makeStream(bufferingPolicy: .bufferingNewest(1))
    let task = Task {
        defer { started.continuation.finish() }
        return try await session.evaluate("""
        import socket, ssl

        context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        context.load_cert_chain(certificate_path, key_path)
        listener = socket.socket()
        listener.settimeout(10)
        listener.bind(('127.0.0.1', 0))
        listener.listen()
        print(listener.getsockname()[1])
        raw, address = listener.accept()
        listener.close()
        raw.settimeout(10)
        connection = context.wrap_socket(raw, server_side=True)
        while True:
            data = connection.recv(4)
            if not data:
                break
            connection.sendall(data.upper())
        connection.close()
        """, timeout: .seconds(15)) { stream, text in
            guard stream == .stdout else {
                return
            }
            let line = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if let port = Int(line) {
                started.continuation.yield(port)
            }
        }
    }
    do {
        var iterator = started.stream.makeAsyncIterator()
        let value = await iterator.next()
        let port = try #require(value)
        return (port, task)
    } catch {
        task.cancel()
        _ = try? await task.value
        throw error
    }
}

private let tlsClientSource = """
import socket, ssl

context = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
context.load_verify_locations(cadata=certificate)
raw = socket.create_connection(('127.0.0.1', port), timeout=5)
connection = context.wrap_socket(raw, server_hostname='localhost')
"""

private let networkCertificate = """
-----BEGIN CERTIFICATE-----
MIIDQzCCAiugAwIBAgIJAOp7Wht/4YJ1MA0GCSqGSIb3DQEBCwUAMBQxEjAQBgNV
BAMMCWxvY2FsaG9zdDAgFw0yNjExMTIxNjA5MDlaGA8yMTI2MTAxOTE2MDkwOVow
FDESMBAGA1UEAwwJbG9jYWxob3N0MIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIB
CgKCAQEA2wqwrTZu9bE6n4UErmWKgSDsZTfwMHdaFzi8TBEEKNTAa3n7/LkrR2Ux
PHU347A5O+5W2WTqEIYOwB4LztHBI6X1aOiNahH33KgjUdDH+6aEWRmuEU34Ijo4
6dEpfl3+1xZyxUxN4ffpkKF7nxWRIP10AazO7VckneSQ5pIj3WH2+1ZzoBGqVNtX
iy/w3jFqQ3VkjvKATyBuujyIGXmWe7aZbF7oy4ir/Ohcw6wv2Hoax/pZ8juYcHWe
a6Xi5E56GoqkPyNEZhW1aCLbZc4DUJdXa34YC5qfOkZbMdZEauyVrznx1UJGGNIH
J+xB/7IKueYnN0WRpW5GgkbM1qMGfwIDAQABo4GVMIGSMBoGA1UdEQQTMBGCCWxv
Y2FsaG9zdIcEfwAAATAPBgNVHRMBAf8EBTADAQH/MA4GA1UdDwEB/wQEAwICpDAT
BgNVHSUEDDAKBggrBgEFBQcDATAdBgNVHQ4EFgQUt9cP0uidrQVLGf0yI74e+rqd
pUkwHwYDVR0jBBgwFoAUt9cP0uidrQVLGf0yI74e+rqdpUkwDQYJKoZIhvcNAQEL
BQADggEBACRxIOEQ0HP7B0Lp2QAdSsyk5F+kq9rZIat8JL/A6gTtbAtSTZAlrJRE
8wBUNActZS4eNhMv6W6rJKzRdtwEGgUgL4ERFKA2SeiLrTG547GsWo6O5oMEgPw6
6CsTIy1FZvJh6BYcDk+6W9ol+idTIV7iPZKo7Q/sklMvoQZ2/0bqyNJe9QZpF6/N
AGZZ/JwFuvFI9yV0BRo7msXox6WPpJOJUo+oZ3B8htaUcIeS0vXpJBRTFTeRpXZZ
EBtmfosVCsicUgzYrx2Ofc24iuQxuvgi2IgnMWEaL9bDxHkfIVc/gNCwDQGSA0lu
L9a0rh+iN5dilWnjVsBdbTucHKZfyNc=
-----END CERTIFICATE-----
"""

private let networkPrivateKey = """
-----BEGIN PRIVATE KEY-----
MIIEvQIBADANBgkqhkiG9w0BAQEFAASCBKcwggSjAgEAAoIBAQDbCrCtNm71sTqf
hQSuZYqBIOxlN/Awd1oXOLxMEQQo1MBrefv8uStHZTE8dTfjsDk77lbZZOoQhg7A
HgvO0cEjpfVo6I1qEffcqCNR0Mf7poRZGa4RTfgiOjjp0Sl+Xf7XFnLFTE3h9+mQ
oXufFZEg/XQBrM7tVySd5JDmkiPdYfb7VnOgEapU21eLL/DeMWpDdWSO8oBPIG66
PIgZeZZ7tplsXujLiKv86FzDrC/YehrH+lnyO5hwdZ5rpeLkTnoaiqQ/I0RmFbVo
IttlzgNQl1drfhgLmp86Rlsx1kRq7JWvOfHVQkYY0gcn7EH/sgq55ic3RZGlbkaC
RszWowZ/AgMBAAECggEAe5VceV3s3NJRsQ7rxTmlG5XnynP1IGM2gUOReZlgL2lZ
50m70qrmsDF3xhSco+oZYKboeV9mcEwyplJNdzMBNYu9GqOape3dWrHCu7aAHouk
wGCsxTaoeSdAVSudrZ562f/gYVDb4FJvhRqXFPqmF2bovMkzNtWj4zHCT1TEx3Ij
EPNNR2pbguqNrfaGtwFw9x/ejJJAlfV9K2q/fzgipcqjMXMo0zuIxcTVzKNDQd1J
nX0QpSwuwauj7Cz2cMDe1j3WkfueWGcvmhuGncHrcsX4n/VHD+aTnAiyCpzFTbaI
QDO7J9VefhHp/NBJcO94ByT2Nn4cRF4fNlkCGRKjgQKBgQDyDfyuwdtqce5bp1dY
/Wu8ouOi2weJOR0BY80qIIWmRlY3ehrFzNfn91hRpy65RL3SXLh5LHWDNB6nqiwr
eGugX/ASsy9Tzrqc9Q+UFYGUE7/Nl5gYqAJGhfuhxOJxMwYfho/4Grwle3ML4Lv6
G6cp8M8BkmO00e0Ix8H7bm3g5QKBgQDnqUp+kBAfcsemF3AZuQ70r2hJpdgK25fX
5YA9ck8XxPWIoj4xy18nC4+hiG67HG1xVLlOUCc0fS5+EXLUkincHeF8gDIVAhqu
GNPpF00lbee+SzeXAOlMY+UoSbv+ynva6sTQqXYFc37ULvf2y5xDVD59hQ9fMNDc
/dAWEqgnkwKBgAoPksUgwaH3AlVE61iDkArTKmsGd5W4jgAUyd5KY8O5gLPlm19F
WGQH39/k9wg0Vz97Ix/GPUwqymtlo1hbNP4BftUIJZtyKEeF2BProOsqtvowpt2/
ffi4cPEUYeUandKJoUpKsi9MpkeEG8wVgik4HSKPlx1Y7GVFCEcPG/oRAoGAQveU
Okvo7T5f6mqCFF2DrkX6jrerYVAjb9y/GoQtywA7vjiwY/KXWhEkfxySbfKEzKsi
Ojo/axP42aavnDV4dlII+dWRJLOMBOHWeF4tBfHkeQUDV9qClnuWJfRSrQ/Zh+ov
5OXn4SGG+01sjuJDFM+IlP5e+DSDXC7e9VKFW5MCgYEAqrwZH79f1P7IIpCE+ZLH
5LwYzodVg6GOnD9eoYk1NEFGCWESfyEIB0jvxmkJkQrR3vOaABAOlZRc2StJ6kTz
u8PPRUoH8bzFk5vgvNJH2Ea1a5+YPgugq2lyoUCExj8hEy3h9Sc2LwRJhNENbCix
28B7oxi1ZcDL7AjMJNTB4f8=
-----END PRIVATE KEY-----
"""
