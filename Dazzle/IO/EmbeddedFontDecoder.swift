import Foundation

/// Turns a font a presentation carries (`ppt/fonts/*.fntdata`) into plain
/// TrueType or OpenType that CoreText can load.
///
/// PowerPoint writes Embedded OpenType: a header describing the font, then
/// the font itself, nearly always squeezed with MicroType Express. Google
/// Slides and others store the TrueType or OpenType file as it is.
enum EmbeddedFontDecoder {
    /// The font file inside `data`, or nil when it is in no form Dazzle reads.
    static func sfnt(from data: Data) -> Data? {
        let bytes = [UInt8](data)
        if isSFNT(bytes[...]) { return data }
        guard let font = try? embeddedOpenType(bytes), isSFNT(font[...]) else { return nil }
        return Data(font)
    }

    private static func isSFNT(_ bytes: ArraySlice<UInt8>) -> Bool {
        guard bytes.count >= 12 else { return false }
        let tag = bytes.prefix(4).reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
        return [0x0001_0000, 0x4F54_544F /* OTTO */, 0x7472_7565 /* true */].contains(tag)
    }

    // MARK: - Embedded OpenType

    private static let compressedFlag: UInt32 = 0x4
    private static let xorFlag: UInt32 = 0x1000_0000

    /// The font out of an EOT. Its data is always the last `FontDataSize`
    /// bytes, whatever the header version puts before it.
    private static func embeddedOpenType(_ bytes: [UInt8]) throws -> [UInt8] {
        func littleEndian32(_ offset: Int) -> UInt32 {
            (0..<4).reduce(UInt32(0)) { $0 | UInt32(bytes[offset + $1]) << (8 * $1) }
        }
        guard bytes.count >= 36, bytes[34] == 0x4C, bytes[35] == 0x50 else { throw FontDecodeError.malformed }
        let totalSize = Int(littleEndian32(0)), fontSize = Int(littleEndian32(4)), flags = littleEndian32(12)
        guard totalSize <= bytes.count, fontSize <= totalSize, totalSize - fontSize >= 36 else {
            throw FontDecodeError.malformed
        }
        var font = Array(bytes[(totalSize - fontSize)..<totalSize])
        if flags & xorFlag != 0 {
            for index in font.indices { font[index] ^= 0x50 }
        }
        return flags & compressedFlag != 0 ? try MicroTypeExpress.decompress(font) : font
    }
}

enum FontDecodeError: Error {
    case truncated
    case malformed
}

// MARK: - MicroType Express

/// MicroType Express, as the W3C submission describes it: three LZCOMP
/// blocks that together hold the font in Compact Table Format.
private enum MicroTypeExpress {
    static func decompress(_ bytes: [UInt8]) throws -> [UInt8] {
        var header = ByteReader(bytes[...])
        let version = try header.uint8()
        _ = try header.uint24() // copy limit, which only the compressor needs
        let second = Int(try header.uint24()), third = Int(try header.uint24())
        guard 10 <= second, second <= third, third <= bytes.count else { throw FontDecodeError.malformed }
        let blocks = try [bytes[10..<second], bytes[second..<third], bytes[third...]].map {
            try LZCOMP.decompress($0, version: version)
        }
        return try CompactTableFormat.font(tables: blocks[0], pushData: blocks[1], instructions: blocks[2])
    }
}

/// LZ77 with three adaptive Huffman coders and a preloaded history.
private enum LZCOMP {
    private static let preload: [UInt8] = {
        var bytes: [UInt8] = []
        for high in 0..<32 {
            for low in 0..<96 { bytes += [UInt8(high), UInt8(low)] }
        }
        for value in 0...255 { bytes += Array(repeating: UInt8(value), count: 4) }
        return bytes
    }()
    private static let longCopyDistance = 512
    private static let maximumLength = 1 << 24

    static func decompress(_ input: ArraySlice<UInt8>, version: UInt8) throws -> [UInt8] {
        var bits = BitReader(bytes: input)
        let usesRunLength = version == 1 ? false : try bits.bit()
        var distanceCoder = AdaptiveHuffman(range: 8)
        var lengthCoder = AdaptiveHuffman(range: 8)
        let length = try bits.value(width: 24)

        var distanceRanges = 1
        while 1 << (3 * distanceRanges) < length { distanceRanges += 1 }
        let dup2 = 256 + 8 * distanceRanges, dup4 = dup2 + 1, dup6 = dup2 + 2
        var symbolCoder = AdaptiveHuffman(range: dup6 + 1)

        var window = preload
        window.reserveCapacity(preload.count + length)
        let end = preload.count + length
        while window.count < end {
            let symbol = try symbolCoder.read(&bits)
            switch symbol {
            case 0..<256:
                window.append(UInt8(symbol))
            case dup2, dup4, dup6:
                window.append(window[window.count - 2 * (symbol - dup2 + 1)])
            default:
                var code = symbol - 256
                let ranges = code / 8 + 1
                guard ranges <= distanceRanges else { throw FontDecodeError.malformed }
                code %= 8
                var copyLength = 0
                while true {
                    copyLength = copyLength << 2 | (code & 3)
                    if code & 4 == 0 { break }
                    code = try lengthCoder.read(&bits)
                    guard copyLength < maximumLength else { throw FontDecodeError.malformed }
                }
                copyLength += 2
                var distance = 0
                for _ in 0..<ranges { distance = distance << 3 | (try distanceCoder.read(&bits)) }
                distance += 1
                if distance >= longCopyDistance { copyLength += 1 }
                let start = window.count - distance - copyLength + 1
                guard start >= 0, window.count + copyLength <= end else { throw FontDecodeError.malformed }
                for offset in 0..<copyLength { window.append(window[start + offset]) }
            }
        }
        let output = window[preload.count...]
        return usesRunLength ? try expandRuns(output) : Array(output)
    }

    /// Undoes the run-length pass: the first byte names an escape, and an
    /// escape is followed by a count (zero for the escape itself) and a byte.
    private static func expandRuns(_ bytes: ArraySlice<UInt8>) throws -> [UInt8] {
        guard let escape = bytes.first else { return [] }
        var output: [UInt8] = []
        output.reserveCapacity(bytes.count)
        var index = bytes.startIndex + 1
        while index < bytes.endIndex {
            let value = bytes[index]
            index += 1
            guard value == escape else {
                output.append(value)
                continue
            }
            guard index < bytes.endIndex else { throw FontDecodeError.truncated }
            let count = Int(bytes[index])
            index += 1
            if count == 0 {
                output.append(escape)
            } else {
                guard index < bytes.endIndex else { throw FontDecodeError.truncated }
                output += repeatElement(bytes[index], count: count)
                index += 1
            }
        }
        return output
    }
}

/// The adaptive Huffman coder LZCOMP uses. Its starting weights have to
/// match the compressor's exactly, or every symbol after the first is wrong.
private struct AdaptiveHuffman {
    private struct Node {
        var up = 0, left = -1, right = -1, code = -1
        var weight = 0
    }

    private static let root = 1
    private var tree: [Node]
    private var symbolIndex: [Int]

    init(range: Int) {
        tree = Array(repeating: Node(), count: 2 * range)
        symbolIndex = Array(range..<(2 * range))
        // Never matched by any real weight, so a search for equal weights stops here.
        tree[0].weight = .max
        for index in 2..<(2 * range) {
            tree[index].up = index / 2
            tree[index].weight = 1
        }
        for index in 1..<range {
            tree[index].left = 2 * index
            tree[index].right = 2 * index + 1
        }
        for symbol in 0..<range { tree[range + symbol].code = symbol }
        for index in stride(from: range - 1, through: 1, by: -1) {
            tree[index].weight = tree[2 * index].weight + tree[2 * index + 1].weight
        }

        if range > 256 && range < 512 {
            // The symbol coder: favour the first copy codes and the single-byte copies.
            update(symbolIndex[256])
            update(symbolIndex[257])
            for _ in 0..<12 { update(symbolIndex[range - 3]) }
            for _ in 0..<6 { update(symbolIndex[range - 2]) }
        } else {
            for _ in 0..<2 {
                for symbol in 0..<range { update(symbolIndex[symbol]) }
            }
        }
    }

    mutating func read(_ bits: inout BitReader) throws -> Int {
        var node = Self.root
        repeat {
            node = try bits.bit() ? tree[node].right : tree[node].left
        } while tree[node].code < 0
        let symbol = tree[node].code
        update(node)
        return symbol
    }

    private mutating func update(_ start: Int) {
        var node = start
        while node != Self.root {
            let weight = tree[node].weight
            if tree[node - 1].weight == weight {
                var leader = node - 1
                while tree[leader - 1].weight == weight { leader -= 1 }
                if leader > Self.root {
                    swap(node, leader)
                    node = leader
                }
            }
            tree[node].weight = weight + 1
            node = tree[node].up
        }
        tree[Self.root].weight += 1
    }

    private mutating func swap(_ a: Int, _ b: Int) {
        let upA = tree[a].up, upB = tree[b].up
        tree.swapAt(a, b)
        tree[a].up = upA
        tree[b].up = upB
        for index in [a, b] {
            if tree[index].code < 0 {
                tree[tree[index].left].up = index
                tree[tree[index].right].up = index
            } else {
                symbolIndex[tree[index].code] = index
            }
        }
    }
}

/// Bits most significant first.
private struct BitReader {
    let bytes: ArraySlice<UInt8>
    private var index: Int
    private var bitsLeft = 0
    private var current: UInt8 = 0

    init(bytes: ArraySlice<UInt8>) {
        self.bytes = bytes
        index = bytes.startIndex
    }

    mutating func bit() throws -> Bool {
        if bitsLeft == 0 {
            guard index < bytes.endIndex else { throw FontDecodeError.truncated }
            current = bytes[index]
            index += 1
            bitsLeft = 8
        }
        bitsLeft -= 1
        return current >> bitsLeft & 1 == 1
    }

    mutating func value(width: Int) throws -> Int {
        var value = 0
        for _ in 0..<width { value = value << 1 | (try bit() ? 1 : 0) }
        return value
    }
}

// MARK: - Compact Table Format

/// Rebuilds a TrueType font from MicroType Express's Compact Table Format:
/// `glyf` re-encoded with its hinting split out, `loca` left to be
/// recomputed, and `cvt ` delta-coded. `hdmx` and `VDMX` are left out:
/// they only cache hinted widths, and CoreText neither needs nor reads them.
private enum CompactTableFormat {
    private struct Table {
        let tag: UInt32
        var data: [UInt8]
    }

    private static func tag(_ string: StaticString) -> UInt32 {
        string.withUTF8Buffer { $0.reduce(UInt32(0)) { $0 << 8 | UInt32($1) } }
    }

    static func font(tables block: [UInt8], pushData: [UInt8], instructions: [UInt8]) throws -> [UInt8] {
        var reader = ByteReader(block[...])
        let version = try reader.uint32()
        let count = Int(try reader.uint16())
        reader.position += 6
        var entries: [(tag: UInt32, offset: Int, length: Int)] = []
        for _ in 0..<count {
            let tag = try reader.uint32()
            _ = try reader.uint32() // checksum, recomputed below
            entries.append((tag, Int(try reader.uint32()), Int(try reader.uint32())))
        }
        func contents(_ entry: (tag: UInt32, offset: Int, length: Int)) throws -> [UInt8] {
            guard entry.offset >= 0, entry.length >= 0, entry.offset + entry.length <= block.count else {
                throw FontDecodeError.truncated
            }
            return Array(block[entry.offset..<(entry.offset + entry.length)])
        }

        var tables: [Table] = []
        var glyphEntry: (tag: UInt32, offset: Int, length: Int)?
        for entry in entries {
            switch entry.tag {
            case tag("hdmx"), tag("VDMX"), tag("loca"):
                continue
            case tag("glyf"):
                glyphEntry = entry
            case tag("cvt "):
                tables.append(Table(tag: entry.tag, data: try controlValues(block, at: entry.offset)))
            default:
                tables.append(Table(tag: entry.tag, data: try contents(entry)))
            }
        }

        if let glyphEntry {
            guard let headIndex = tables.firstIndex(where: { $0.tag == tag("head") }), tables[headIndex].data.count >= 54,
                  let maxp = tables.first(where: { $0.tag == tag("maxp") })?.data, maxp.count >= 6 else {
                throw FontDecodeError.malformed
            }
            let glyphCount = Int(maxp[4]) << 8 | Int(maxp[5])
            var glyphs = GlyphDecoder(
                outlines: ByteReader(block[...], position: glyphEntry.offset),
                pushData: ByteReader(pushData[...]), instructions: ByteReader(instructions[...])
            )
            let (glyf, offsets) = try glyphs.table(glyphCount: glyphCount)
            var head = tables[headIndex].data
            let short = (head[50] == 0 && head[51] == 0) && glyf.count <= 0x1FFFE
            head[50] = 0
            head[51] = short ? 0 : 1
            tables[headIndex].data = head
            var loca = ByteWriter()
            for offset in offsets {
                if short { loca.uint16(offset / 2) } else { loca.uint32(offset) }
            }
            tables.append(Table(tag: tag("glyf"), data: glyf))
            tables.append(Table(tag: tag("loca"), data: loca.bytes))
        }
        return assemble(version: version, tables: tables)
    }

    /// `cvt `: a count, then each value as a small delta from the one before.
    private static func controlValues(_ block: [UInt8], at offset: Int) throws -> [UInt8] {
        var reader = ByteReader(block[...], position: offset)
        var output = ByteWriter()
        var value: Int16 = 0
        for _ in 0..<Int(try reader.uint16()) {
            let code = Int(try reader.uint8())
            let delta: Int16
            switch code {
            case 248...: delta = Int16(238 * (code - 247) + Int(try reader.uint8()))
            case 239...: delta = -Int16(238 * (code - 239) + Int(try reader.uint8()))
            case 238: delta = try reader.int16()
            default: delta = Int16(code)
            }
            value &+= delta
            output.int16(Int(value))
        }
        return output.bytes
    }

    /// A font file around the tables, with the directory and checksums it needs.
    private static func assemble(version: UInt32, tables: [Table]) -> [UInt8] {
        let tables = tables.sorted { $0.tag < $1.tag }
        var power = 1, exponent = 0
        while power * 2 <= tables.count {
            power *= 2
            exponent += 1
        }
        var output = ByteWriter()
        output.uint32(Int(version))
        output.uint16(tables.count)
        output.uint16(power * 16)
        output.uint16(exponent)
        output.uint16(tables.count * 16 - power * 16)
        var offset = 12 + 16 * tables.count
        for table in tables {
            output.uint32(Int(table.tag))
            output.uint32(Int(checksum(table.data)))
            output.uint32(offset)
            output.uint32(table.data.count)
            offset += (table.data.count + 3) & ~3
        }
        var headOffset: Int?
        for table in tables {
            if table.tag == tag("head") { headOffset = output.bytes.count }
            output.bytes += table.data
            output.bytes += repeatElement(0, count: (4 - table.data.count % 4) % 4)
        }
        if let headOffset, output.bytes.count >= headOffset + 12 {
            for index in 8..<12 { output.bytes[headOffset + index] = 0 }
            let adjustment = 0xB1B0_AFBA &- checksum(output.bytes)
            for index in 0..<4 { output.bytes[headOffset + 8 + index] = UInt8(truncatingIfNeeded: adjustment >> (24 - 8 * index)) }
        }
        return output.bytes
    }

    private static func checksum(_ bytes: [UInt8]) -> UInt32 {
        var sum: UInt32 = 0
        var index = 0
        while index < bytes.count {
            var word: UInt32 = 0
            for offset in 0..<4 {
                word = word << 8 | UInt32(index + offset < bytes.count ? bytes[index + offset] : 0)
            }
            sum &+= word
            index += 4
        }
        return sum
    }
}

/// Reads CTF glyphs one by one, drawing each one's hinting from the push
/// data and instruction blocks, and writes them as TrueType `glyf` records.
private struct GlyphDecoder {
    var outlines: ByteReader
    var pushData: ByteReader
    var instructions: ByteReader

    private static let explicitBoundsFlag = 0x7FFF

    /// The `glyf` table, and each glyph's offset into it plus the end.
    mutating func table(glyphCount: Int) throws -> ([UInt8], [Int]) {
        var output = ByteWriter()
        var offsets: [Int] = []
        offsets.reserveCapacity(glyphCount + 1)
        for _ in 0..<glyphCount {
            offsets.append(output.bytes.count)
            try glyph(into: &output)
            if output.bytes.count % 2 == 1 { output.bytes.append(0) }
        }
        offsets.append(output.bytes.count)
        return (output.bytes, offsets)
    }

    private mutating func glyph(into output: inout ByteWriter) throws {
        var contours = Int(try outlines.int16())
        if contours < 0 { return try composite(into: &output) }
        var bounds: [Int]?
        if contours == Self.explicitBoundsFlag {
            contours = Int(try outlines.int16())
            bounds = try (0..<4).map { _ in Int(try outlines.int16()) }
        }
        // An empty glyph, such as the space, has nothing at all.
        guard contours > 0 else { return }

        var endPoints: [Int] = []
        var points = 0
        for index in 0..<contours {
            let value = try outlines.ushort255()
            points = index == 0 ? value + 1 : points + value
            endPoints.append(points - 1)
        }
        let flags = try outlines.bytes(points)
        var xs: [Int] = [], ys: [Int] = []
        xs.reserveCapacity(points)
        ys.reserveCapacity(points)
        var x = 0, y = 0
        var minX = Int.max, minY = Int.max, maxX = Int.min, maxY = Int.min
        for flag in flags {
            let (dx, dy) = try triplet(Int(flag & 0x7F))
            xs.append(dx)
            ys.append(dy)
            x += dx
            y += dy
            minX = min(minX, x); maxX = max(maxX, x)
            minY = min(minY, y); maxY = max(maxY, y)
        }
        let hinting = try program()

        output.int16(contours)
        for value in bounds ?? [minX, minY, maxX, maxY] { output.int16(value) }
        for end in endPoints { output.uint16(end) }
        output.uint16(hinting.count)
        output.bytes += hinting

        var xBytes = ByteWriter(), yBytes = ByteWriter()
        for (index, flag) in flags.enumerated() {
            var outFlag: UInt8 = flag & 0x80 == 0 ? 0x01 : 0
            outFlag |= Self.coordinate(xs[index], into: &xBytes, short: 0x02, same: 0x10)
            outFlag |= Self.coordinate(ys[index], into: &yBytes, short: 0x04, same: 0x20)
            output.bytes.append(outFlag)
        }
        output.bytes += xBytes.bytes
        output.bytes += yBytes.bytes
    }

    /// Writes one relative coordinate in the smallest TrueType form, and
    /// returns the flag bits that say which.
    private static func coordinate(_ delta: Int, into output: inout ByteWriter, short: UInt8, same: UInt8) -> UInt8 {
        if delta == 0 { return same }
        if abs(delta) < 256 {
            output.bytes.append(UInt8(abs(delta)))
            return delta > 0 ? short | same : short
        }
        output.int16(delta)
        return 0
    }

    private mutating func composite(into output: inout ByteWriter) throws {
        output.int16(-1)
        for _ in 0..<4 { output.int16(Int(try outlines.int16())) }
        var flags = 0
        repeat {
            flags = Int(try outlines.uint16())
            output.uint16(flags)
            var length = 2 + (flags & 0x0001 != 0 ? 4 : 2)
            if flags & 0x0080 != 0 { length += 8 } else if flags & 0x0040 != 0 { length += 4 } else if flags & 0x0008 != 0 { length += 2 }
            output.bytes += try outlines.bytes(length)
        } while flags & 0x0020 != 0
        if flags & 0x0100 != 0 {
            let hinting = try program()
            output.uint16(hinting.count)
            output.bytes += hinting
        }
    }

    /// A glyph's instructions: its initial pushes, rebuilt as TrueType push
    /// instructions, then the rest of its program.
    private mutating func program() throws -> [UInt8] {
        let pushCount = try outlines.ushort255()
        var values: [Int] = []
        while values.count < pushCount {
            let code = try pushData.peek()
            if code == 251 || code == 252 {
                guard values.count >= 2 else { throw FontDecodeError.malformed }
                pushData.position += 1
                let repeated = values[values.count - 2]
                values += [repeated, try pushData.short255(), repeated]
                if code == 252 { values += [try pushData.short255(), repeated] }
            } else {
                values.append(try pushData.short255())
            }
        }
        guard values.count == pushCount else { throw FontDecodeError.malformed }
        let code = try instructions.bytes(try outlines.ushort255())
        return Self.pushes(values) + code
    }

    private static func pushes(_ values: [Int]) -> [UInt8] {
        var output = ByteWriter()
        var start = 0
        while start < values.count {
            let isByte = (0...255).contains(values[start])
            var end = start
            while end < values.count, end - start < 255, (0...255).contains(values[end]) == isByte { end += 1 }
            let count = end - start
            if count <= 8 {
                output.bytes.append(UInt8((isByte ? 0xB0 : 0xB8) + count - 1)) // PUSHB, PUSHW
            } else {
                output.bytes += [isByte ? 0x40 : 0x41, UInt8(count)] // NPUSHB, NPUSHW
            }
            for value in values[start..<end] {
                if isByte { output.bytes.append(UInt8(value)) } else { output.int16(value) }
            }
            start = end
        }
        return output.bytes
    }

    /// One point's move from the last, from its flag and the bytes after it.
    /// The same triplet coding WOFF 2 later adopted.
    private mutating func triplet(_ flag: Int) throws -> (Int, Int) {
        func signed(_ bit: Int, _ value: Int) -> Int { bit & 1 == 1 ? value : -value }
        switch flag {
        case ..<10:
            return (0, signed(flag, (flag & 14) << 7 + Int(try outlines.uint8())))
        case ..<20:
            return (signed(flag, ((flag - 10) & 14) << 7 + Int(try outlines.uint8())), 0)
        case ..<84:
            let base = flag - 20, byte = Int(try outlines.uint8())
            return (signed(flag, 1 + (base & 0x30) + byte >> 4), signed(flag >> 1, 1 + (base & 0x0C) << 2 + byte & 0x0F))
        case ..<120:
            let base = flag - 84, first = Int(try outlines.uint8()), second = Int(try outlines.uint8())
            return (signed(flag, 1 + (base / 12) << 8 + first), signed(flag >> 1, 1 + ((base % 12) >> 2) << 8 + second))
        case ..<124:
            let bytes = try outlines.bytes(3).map(Int.init)
            return (signed(flag, bytes[0] << 4 + bytes[1] >> 4), signed(flag >> 1, (bytes[1] & 0x0F) << 8 + bytes[2]))
        default:
            let bytes = try outlines.bytes(4).map(Int.init)
            return (signed(flag, bytes[0] << 8 + bytes[1]), signed(flag >> 1, bytes[2] << 8 + bytes[3]))
        }
    }
}

// MARK: - Byte access

private struct ByteReader {
    let bytes: ArraySlice<UInt8>
    var position: Int

    init(_ bytes: ArraySlice<UInt8>, position: Int = 0) {
        self.bytes = bytes
        self.position = bytes.startIndex + position
    }

    func peek() throws -> UInt8 {
        guard position >= bytes.startIndex, position < bytes.endIndex else { throw FontDecodeError.truncated }
        return bytes[position]
    }

    mutating func uint8() throws -> UInt8 {
        let value = try peek()
        position += 1
        return value
    }

    mutating func bytes(_ count: Int) throws -> [UInt8] {
        guard count >= 0, position >= bytes.startIndex, position + count <= bytes.endIndex else {
            throw FontDecodeError.truncated
        }
        defer { position += count }
        return Array(bytes[position..<(position + count)])
    }

    mutating func uint16() throws -> UInt16 { UInt16(try uint8()) << 8 | UInt16(try uint8()) }
    mutating func int16() throws -> Int16 { Int16(bitPattern: try uint16()) }
    mutating func uint24() throws -> UInt32 { UInt32(try uint16()) << 8 | UInt32(try uint8()) }
    mutating func uint32() throws -> UInt32 { UInt32(try uint16()) << 16 | UInt32(try uint16()) }

    /// MTX's 255USHORT: one byte, or a marker and one or two more.
    mutating func ushort255() throws -> Int {
        switch try uint8() {
        case 253: return Int(try uint16())
        case 254: return 506 + Int(try uint8())
        case 255: return 253 + Int(try uint8())
        case let code: return Int(code)
        }
    }

    /// MTX's 255SHORT, which adds a sign marker to 255USHORT's scheme.
    mutating func short255() throws -> Int {
        var code = try uint8()
        if code == 253 { return Int(try int16()) }
        var sign = 1
        if code == 250 {
            sign = -1
            code = try uint8()
        }
        switch code {
        case 255: return sign * (250 + Int(try uint8()))
        case 254: return sign * (500 + Int(try uint8()))
        default: return sign * Int(code)
        }
    }
}

private struct ByteWriter {
    var bytes: [UInt8] = []

    mutating func uint16(_ value: Int) {
        bytes += [UInt8(truncatingIfNeeded: value >> 8), UInt8(truncatingIfNeeded: value)]
    }

    mutating func int16(_ value: Int) { uint16(value) }

    mutating func uint32(_ value: Int) {
        bytes += [24, 16, 8, 0].map { UInt8(truncatingIfNeeded: value >> $0) }
    }
}
