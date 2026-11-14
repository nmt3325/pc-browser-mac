#!/usr/bin/env python3
"""Builds a small, fully synthetic card image that carries real H.264, PCM and GPS telemetry.

Nothing here comes from a real recording: the picture is a generated test pattern (see
fixtures/synthetic-h264.b64, 120 frames, 1280x540, H.264 Main) laid out with the packet and
metadata structure observed on the original cards. It lets CI and any Mac decode, export and
display media without private data.

usage: synthetic_media.py <new-image-path>
"""
import base64
import math
import re
import struct
import sys
from pathlib import Path

WIDTH, HEIGHT, FRAMES, FPS = 1280, 540, 120, 30
BLOCKS = 3
HERE = Path(__file__).resolve().parent
# Quadrant centres (picture pixels) and the colours the generated pattern puts there.
SAMPLES = {'front_top': (320, 135, (255, 0, 0)), 'rear_top': (960, 135, (0, 255, 0)),
           'front_bottom': (320, 405, (0, 0, 255)), 'rear_bottom': (960, 405, (255, 255, 255))}


def access_units():
    data = base64.b64decode((HERE / 'fixtures' / 'synthetic-h264.b64').read_text())
    starts = [m.start() for m in re.finditer(b'\x00\x00\x00\x01\x09', data)]
    assert len(starts) == FRAMES, len(starts)
    # Drop each access-unit delimiter (6 bytes); the decoder ignores them anyway.
    return [data[s + 6:(starts[i + 1] if i + 1 < len(starts) else len(data))] for i, s in enumerate(starts)]


def pcm_chunks():
    """8-bit unsigned mono PCM at 8000 Hz, split per frame so that the total is exactly 8000 * FRAMES / FPS."""
    chunks, done = [], 0
    for frame in range(FRAMES):
        upto = round((frame + 1) * 8000 / FPS)
        chunks.append(bytes(128 + int(40 * math.sin(2 * math.pi * 440 * n / 8000)) for n in range(done, upto)))
        done = upto
    return chunks


def put32(buf, offset, value):
    struct.pack_into('<I', buf, offset, value & 0xFFFFFFFF)


def build(blank_video=False):
    """`blank_video` keeps every header (clock, GPS, sensors, sizes) but leaves the video and audio areas zero-filled,
    like the continuous recordings of the sample card."""
    units, audio = access_units(), pcm_chunks()
    per_block = FRAMES // BLOCKS
    # Layout first: every frame is start header + video sectors + audio sectors + end header.
    layout, sector = [], 10
    for block in range(BLOCKS):
        record = sector
        sector += 2
        frames = []
        for frame in range(per_block):
            index = block * per_block + frame
            video, aux = len(units[index]), len(audio[index])
            payload = (video + 511) // 512 + (aux + 511) // 512
            frames.append((index, frame, sector, 2 + payload))
            sector += 2 + payload
        layout.append((record, frames))
    image = bytearray((sector + 64) * 512)
    image[510:512] = b'\x55\xaa'
    image[450] = 6
    put32(image, 454, 1)
    put32(image, 458, 7)
    marker = b'YP_FORMAT_1.01__\0'
    image[8 * 512 + 1:8 * 512 + 18] = marker
    image[8 * 512 + 0x1ec:8 * 512 + 0x1fd] = marker
    put32(image, 8 * 512 + 0x1be, 10)
    image[8 * 512 + 0x14] = 1
    all_frames = [f for _, frames in layout for f in frames]
    previous = {all_frames[i][2]: (all_frames[i - 1][2] if i else all_frames[-1][2]) for i in range(len(all_frames))}
    for block, (record, frames) in enumerate(layout):
        meta = bytearray(512)
        for offset, value in ((0, 0xFFFFD103 if block < 2 else 0xFFFFD105), (4, record + 1000), (0x1FC, record + 1000),
                              (0x1C4, 10), (0x1E0, record), (0x98, block * per_block), (0x9C, 7), (0x1F8, 68)):
            put32(meta, offset, value)
        meta[0x16], meta[0x18], meta[0x19] = 80, 1, 8      # 8000 Hz, 1 channel, 8 bit
        image[record * 512:(record + 1) * 512] = meta
        meta[0x70] = 1
        image[(record + 1) * 512:(record + 2) * 512] = meta
        for index, frame, start, span in frames:
            header = bytearray(512)
            video, aux = len(units[index]), len(audio[index])
            for offset, value in ((0, 0xFFFFD101), (4, frame), (0x1FC, frame), (0x1A6, video), (0x1AC, span), (0x1B0, start),
                                  (0x1B4, start + span - 1), (0x1B8, record), (0x1BC, aux), (0x1C0, previous[start]),
                                  (0x1D8, 68), (0x1DC, record + 1000), (0x1E8, 15)):
                put32(header, offset, value)
            header[8] = 1
            header[9] = 2 if units[index][:5] == b'\x00\x00\x00\x01\x67' else 3
            header[0x1D] = FPS
            header[10:17] = bytes((26, 11, 13, 10, 0, index // FPS, index % FPS))
            t = index / FPS
            header[0x26], header[0x27] = 8, 1
            struct.pack_into('<i', header, 0x28, round((35.6812 + 0.00002 * index) * 600000))
            struct.pack_into('<i', header, 0x2C, round((139.7671 + 0.00003 * index) * 600000))
            struct.pack_into('<h', header, 0x30, 25000)
            struct.pack_into('<I', header, 0x32, 800 + int(60 * math.sin(t)))
            for offset, value in ((0x46, int(1000 * math.sin(t))), (0x48, int(500 * math.cos(t))), (0x4A, 4096),
                                  (0x50, int(30 * math.sin(2 * t))), (0x52, int(20 * math.cos(2 * t))), (0x54, 5)):
                struct.pack_into('<h', header, offset, value)
            image[start * 512:(start + 1) * 512] = header
            video_start = (start + 1) * 512
            audio_start = video_start + (video + 511) // 512 * 512
            if not blank_video:
                image[video_start:video_start + video] = units[index]
                image[audio_start:audio_start + aux] = audio[index]
            put32(header, 0, 0xFFFFD102)
            end = start + span - 1
            image[end * 512:(end + 1) * 512] = header
    return bytes(image)


if __name__ == '__main__':
    out = Path(sys.argv[1])
    out.write_bytes(build())
    print(out, out.stat().st_size)
