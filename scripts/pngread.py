import struct
import zlib


def read_png(path):
    """Minimal PNG reader (8/16-bit, grey/RGB/RGBA/grey+alpha, non-interlaced). Returns width, height, row accessor."""
    data = open(path, 'rb').read()
    assert data[:8] == b'\x89PNG\r\n\x1a\n', 'not a PNG'
    pos, header, idat = 8, None, []
    while pos < len(data):
        length, kind = struct.unpack('>I4s', data[pos:pos + 8])
        body = data[pos + 8:pos + 8 + length]
        pos += 12 + length
        if kind == b'IHDR':
            header = struct.unpack('>IIBBBBB', body)
        elif kind == b'IDAT':
            idat.append(body)
        elif kind == b'IEND':
            break
    width, height, depth, colour, _, _, interlace = header
    assert interlace == 0 and depth in (8, 16) and colour in (0, 2, 4, 6), header
    channels = {0: 1, 2: 3, 4: 2, 6: 4}[colour]
    bpp = channels * depth // 8
    stride = width * bpp
    raw = zlib.decompress(b''.join(idat))
    assert len(raw) == height * (stride + 1), (len(raw), height, stride)
    rows, previous = [], bytearray(stride)
    for y in range(height):
        base = y * (stride + 1)
        kind, line = raw[base], bytearray(raw[base + 1:base + 1 + stride])
        if kind == 1:
            for i in range(bpp, stride):
                line[i] = (line[i] + line[i - bpp]) & 255
        elif kind == 2:
            for i in range(stride):
                line[i] = (line[i] + previous[i]) & 255
        elif kind == 3:
            for i in range(stride):
                left = line[i - bpp] if i >= bpp else 0
                line[i] = (line[i] + ((left + previous[i]) >> 1)) & 255
        elif kind == 4:
            for i in range(stride):
                a = line[i - bpp] if i >= bpp else 0
                b, c = previous[i], (previous[i - bpp] if i >= bpp else 0)
                p = a + b - c
                pa, pb, pc = abs(p - a), abs(p - b), abs(p - c)
                line[i] = (line[i] + (a if pa <= pb and pa <= pc else b if pb <= pc else c)) & 255
        else:
            assert kind == 0, kind
        rows.append(line)
        previous = line

    def pixel(x, y):
        line, step = rows[y], depth // 8
        if colour in (0, 4):
            value = line[x * bpp]
            return (value, value, value)
        return tuple(line[x * bpp + c * step] for c in range(3))
    return width, height, pixel
