//
//  Created by Anton Spivak
//

import _NIOFileSystem
import Python
import Testing

@Test
func xmlParsersUseSessionFileAccess() async throws {
    try await withTemporaryDirectory { root in
        let allowed = root.appending("allowed")
        let source = allowed.appending("document.xml")
        let denied = root.appending("denied.xml")
        try await FileSystem.shared.createDirectory(at: allowed, withIntermediateDirectories: false)
        try await "<document><value>42</value></document>".write(toFileAt: source)
        try await "<protected/>".write(toFileAt: denied)

        let runtime = try await Python::Runtime()
        let session = try await runtime.session(
            directory: allowed.string,
        )
        defer { await session.close() }
        try await session.set(source.string, forKey: "source")
        try await session.set(denied.string, forKey: "denied")

        let result = try await session.evaluate("""
        import _elementtree
        import xml.dom.minidom as dom
        import xml.etree.ElementTree as tree
        from xml.parsers import expat

        assert tree.XMLParser is _elementtree.XMLParser
        assert tree.parse(source).getroot().findtext('value') == '42'
        assert dom.parse(source).documentElement.tagName == 'document'
        with open(source, 'rb') as file:
            assert expat.ParserCreate().ParseFile(file) == 1

        for read in (tree.parse, dom.parse, lambda path: expat.ParserCreate().ParseFile(open(path, 'rb'))):
            try:
                read(denied)
            except PermissionError:
                pass
            else:
                raise AssertionError('XML read bypassed file access')
        """)
        #expect(result.end == .finished)
    }
}

@Test
func xmlParserStateRemainsAfterFailure() async throws {
    let runtime = try await Python::Runtime()
    let session = try await runtime.session()
    defer { await session.close() }

    _ = try await session.evaluate("""
    import gc
    import xml.etree.ElementTree as tree
    from xml.parsers import expat

    element = tree.Element('root', {'value': 'original'})
    alias = element
    parser = tree.XMLParser()
    parser.feed('<root>')
    events = []
    raw = expat.ParserCreate()
    raw.StartElementHandler = lambda name, attributes: events.append(name)
    raw.Parse('<root>', False)
    """)

    _ = try await #require(throws: Python::ExecutionError.self) {
        try await session.evaluate("""
        element.set('value', 'changed')
        tree.SubElement(element, 'discarded')
        parser.feed('<discarded/></root>')
        parsed = parser.close()
        raw.Parse('<discarded/></root>', True)
        gc.collect()
        raise ValueError('XML state remains')
        """)
    }

    let result = try await session.evaluate("""
    assert element is alias
    assert element.attrib == {'value': 'changed'} and element[0].tag == 'discarded'
    assert parsed[0].tag == 'discarded'
    assert events == ['root', 'discarded']
    try:
        raw.Parse('<retained/>', True)
    except expat.ExpatError:
        pass
    else:
        raise AssertionError('A finished parser was restored')
    assert tree.fromstring('<next/>').tag == 'next'
    """)
    #expect(result.end == .finished)
}
