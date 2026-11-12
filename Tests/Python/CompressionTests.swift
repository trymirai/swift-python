//
//  Created by Anton Spivak
//

import _NIOFileSystem
import Python
import Testing

@Test(.timeLimit(.minutes(1)))
func compressionUsesSessionFileAccess() async throws {
    try await withTemporaryDirectory { root in
        for name in ["allowed", "denied"] {
            try await FileSystem.shared.createDirectory(
                at: root.appending(name),
                withIntermediateDirectories: false,
            )
        }
        let delegate = FileAccessDelegate { request in
            !request.path.components.contains("denied")
        }
        let session = try await Python::Runtime().session(
            directory: root.string,
            delegate: delegate,
        )
        defer { await session.close() }
        try await session.set(root.string, forKey: "root")

        let result = try await session.evaluate("""
        import bz2, lzma
        from pathlib import Path

        payload = b'swift-python' * 1024
        for name, codec in [('bz2', bz2), ('xz', lzma)]:
            assert codec.decompress(codec.compress(payload)) == payload
            path = Path(root) / 'allowed' / name
            with codec.open(path, 'wb') as file:
                _ = file.write(payload)
            with codec.open(path, 'rb') as file:
                assert file.read() == payload
            try:
                codec.open(Path(root) / 'denied' / name, 'wb')
            except PermissionError:
                pass
            else:
                raise AssertionError('Compressed file bypassed file access')
        """)
        #expect(result.end == .finished)
    }
}

@Test(.timeLimit(.minutes(1)))
func compressionStateRemainsAfterFailure() async throws {
    let session = try await Python::Runtime().session()
    defer { await session.close() }

    _ = try await session.evaluate("""
    import bz2, lzma, gc

    bz = bz2.BZ2Compressor()
    xz = lzma.LZMACompressor()
    bz_header = bz.compress(b'original')
    xz_header = xz.compress(b'original')
    """)

    _ = try await #require(throws: Python::ExecutionError.self) {
        try await session.evaluate("""
        bz_tail = bz.flush()
        xz_tail = xz.flush()
        gc.collect()
        raise ValueError('compression state remains')
        """)
    }

    let result = try await session.evaluate("""
    assert bz2.decompress(bz_header + bz_tail) == b'original'
    assert lzma.decompress(xz_header + xz_tail) == b'original'
    for compressor in (bz, xz):
        try:
            compressor.flush()
        except (ValueError, lzma.LZMAError):
            pass
        else:
            raise AssertionError('A finished compressor was restored')
    """)
    #expect(result.end == .finished)
}
