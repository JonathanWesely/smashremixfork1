#!/usr/bin/env python3
"""
Self-contained Nintendo VADPCM (AIFF-C "VAPC" / "VADPCM ~4-1") codec for Smash Remix.

Smash Remix's `add_sound` macro (src/FGM.asm) reads a FIXED .aifc layout:
    0x04  FORM total size (big-endian word)
    0x70  VADPCMCODES predictor codebook, 0x80 bytes (order 2, 4 predictors)
    0xF4  SSND chunk size (frame_data_bytes + 8)
    0x100 raw VADPCM frame data (9 bytes / 16 samples)
So a generated file MUST byte-match the reference framing (Twelve_Character_Battle.aifc / KoTH.aifc).

This module can:
  decode  - decode a reference VADPCM .aifc to PCM (used to validate the codec convention)
  encode  - encode a mono 16-bit PCM WAV into a VADPCM .aifc with the reference framing

VADPCM decode convention (verified empirically against the shipped reference sounds):
  Each predictor `p` has order=2 rows of 8 Q11 coefficients. The SECOND stored row is the impulse
  response to the most-recent sample l1, the FIRST stored row the response to l2:
  pred1 = book[p][1] (l1), pred2 = book[p][0] (l2). (Confirmed: this ordering decodes the shipped
  reference sounds with 0% saturation and smooth output; the other ordering saturates and is rougher.)
  Per 9-byte frame: byte0 = (shift<<4 | predictor); then 16 signed 4-bit residuals.
  For each of two 8-sample sub-blocks (l1 = last decoded sample, l2 = 2nd-last):
      for j in 0..7:
          acc  = pred1[j]*l1 + pred2[j]*l2
          acc += sum_{k<j} ix[k] * pred1[j-1-k]     # ix already <<shift
          acc += ix[j] << 11
          out[j] = clamp16(acc >> 11)
      l1 = out[7]; l2 = out[6]
"""

import struct
import sys
import wave


# ----------------------------------------------------------------------------- AIFF-C parsing
def _read_chunks(data):
    """Yield (id, offset_of_data, size) for top-level chunks in a FORM."""
    assert data[0:4] == b"FORM", "not an AIFF/AIFF-C FORM file"
    assert data[8:12] in (b"AIFC", b"AIFF"), "not AIFC/AIFF"
    pos = 12
    while pos + 8 <= len(data):
        cid = data[pos:pos + 4]
        (size,) = struct.unpack(">I", data[pos + 4:pos + 8])
        yield cid, pos + 8, size
        pos += 8 + size + (size & 1)  # chunks are padded to even length


def parse_aifc(path):
    """Return (book[npred][order][8], frames bytes, num_frames, sample_rate_hz)."""
    with open(path, "rb") as f:
        data = f.read()
    book = None
    order = npred = None
    frames = None
    num_frames = None
    rate = None
    for cid, off, size in _read_chunks(data):
        if cid == b"COMM":
            (num_frames,) = struct.unpack(">I", data[off + 2:off + 6])
            rate = _read_extended80(data[off + 8:off + 18])
        elif cid == b"APPL":
            body = data[off:off + size]
            i = body.find(b"VADPCMCODES")
            if i >= 0:
                p = i + len(b"VADPCMCODES")
                _ver, order, npred = struct.unpack(">hhh", body[p:p + 6])
                p += 6
                vals = struct.unpack(">%dh" % (order * npred * 8), body[p:p + order * npred * 8 * 2])
                book = []
                vi = 0
                for _ in range(npred):
                    rows = []
                    for _ in range(order):
                        rows.append(list(vals[vi:vi + 8]))
                        vi += 8
                    book.append(rows)
        elif cid == b"SSND":
            # SSND: 4 bytes offset + 4 bytes blockSize, then sample data
            frames = data[off + 8:off + size]
    return book, frames, num_frames, rate


def _read_extended80(b):
    """Decode an 80-bit IEEE 754 extended float (AIFF sample rate)."""
    sign = b[0] >> 7
    exp = ((b[0] & 0x7F) << 8) | b[1]
    mant = int.from_bytes(b[2:10], "big")
    if exp == 0 and mant == 0:
        return 0.0
    val = mant * 2.0 ** (exp - 16383 - 63)
    return -val if sign else val


def _write_extended80(value):
    """Encode a positive number as an 80-bit IEEE 754 extended float."""
    if value == 0:
        return b"\x00" * 10
    import math
    m, e = math.frexp(value)          # value = m * 2**e, 0.5<=m<1
    exp = e - 1 + 16383               # unbiased exponent of leading 1
    mant = int(m * 2.0 ** 64)         # 64-bit mantissa with explicit leading 1
    if mant >> 64:                    # rounding overflow
        mant >>= 1
        exp += 1
    return struct.pack(">H", exp & 0x7FFF) + struct.pack(">Q", mant & 0xFFFFFFFFFFFFFFFF)


# ----------------------------------------------------------------------------- codec core
def _clamp16(x):
    return -32768 if x < -32768 else (32767 if x > 32767 else x)


def decode(book, frames):
    """Decode VADPCM frame bytes -> list of int16 samples."""
    out = []
    l1 = 0
    l2 = 0
    npred = len(book)
    n = len(frames) // 9
    for fi in range(n):
        base = fi * 9
        header = frames[base]
        shift = header >> 4
        pidx = header & 0x0F
        if pidx >= npred:
            pidx = 0
        pred1, pred2 = book[pidx][1], book[pidx][0]  # l1-response, l2-response
        ix = [0] * 16
        for k in range(16):
            byte = frames[base + 1 + (k >> 1)]
            nib = (byte >> 4) if (k & 1) == 0 else (byte & 0x0F)
            if nib >= 8:
                nib -= 16
            ix[k] = nib << shift
        for sub in range(2):
            s = sub * 8
            dec = [0] * 8
            for j in range(8):
                acc = pred1[j] * l1 + pred2[j] * l2
                for k in range(j):
                    acc += ix[s + k] * pred1[j - 1 - k]
                acc += ix[s + j] << 11
                val = _clamp16(acc >> 11)
                dec[j] = val
            out.extend(dec)
            l1 = dec[7]
            l2 = dec[6]
    return out


def _encode_frame(target16, l1, l2, book):
    """Pick (predictor, shift, residuals) minimizing squared error for one 16-sample frame.
    Returns (frame_bytes(9), decoded16, new_l1, new_l2)."""
    best = None
    npred = len(book)
    for pidx in range(npred):
        pred1, pred2 = book[pidx][1], book[pidx][0]  # l1-response, l2-response
        for shift in range(13):  # 0..12
            scale = 1 << shift
            ix = [0] * 16
            dec = [0] * 16
            cl1, cl2 = l1, l2
            err = 0
            for sub in range(2):
                s = sub * 8
                for j in range(8):
                    # prediction from history + already-chosen residuals in this sub-block
                    pacc = pred1[j] * cl1 + pred2[j] * cl2
                    for k in range(j):
                        pacc += ix[s + k] * pred1[j - 1 - k]
                    # desired current residual term (Q11): target*2048 - pacc
                    resid_q11 = (target16[s + j] << 11) - pacc
                    # ix value (4-bit) ~ resid_q11 / 2048 / scale
                    q = int(round(resid_q11 / (2048.0 * scale)))
                    if q < -8:
                        q = -8
                    elif q > 7:
                        q = 7
                    ix[s + j] = q * scale
                    acc = pacc + (ix[s + j] << 11)
                    val = _clamp16(acc >> 11)
                    dec[s + j] = val
                    d = val - target16[s + j]
                    err += d * d
                cl1 = dec[s + 7]
                cl2 = dec[s + 6]
            if best is None or err < best[0]:
                # pack nibbles
                nibs = []
                for sub in range(2):
                    for j in range(8):
                        nibs.append((ix[sub * 8 + j] >> shift) & 0x0F)
                fb = bytearray(9)
                fb[0] = (shift << 4) | pidx
                for k in range(8):
                    fb[1 + k] = (nibs[2 * k] << 4) | nibs[2 * k + 1]
                best = (err, bytes(fb), list(dec), cl1, cl2)
    return best[1], best[2], best[3], best[4]


def encode(samples, book):
    """Encode int16 samples (multiple of 16; padded with zeros if not) -> frame bytes."""
    samples = list(samples)
    if len(samples) % 16:
        samples += [0] * (16 - len(samples) % 16)
    frames = bytearray()
    l1 = l2 = 0
    for fi in range(len(samples) // 16):
        chunk = samples[fi * 16:fi * 16 + 16]
        fb, dec, l1, l2 = _encode_frame(chunk, l1, l2, book)
        frames += fb
    return bytes(frames), len(samples)


# ----------------------------------------------------------------------------- .aifc writer
def build_aifc(book, frames, num_samples, rate_hz):
    """Assemble a VADPCM .aifc matching the reference framing exactly."""
    npred = len(book)
    order = len(book[0])

    comm = struct.pack(">h", 1)                     # channels
    comm += struct.pack(">I", num_samples)          # numSampleFrames
    comm += struct.pack(">h", 16)                   # sampleSize
    comm += _write_extended80(float(rate_hz))       # 80-bit sample rate
    comm += b"VAPC"
    comm += bytes([11]) + b"VADPCM ~4-1"            # pascal-string compression name
    comm_chunk = b"COMM" + struct.pack(">I", len(comm)) + comm

    inst_body = b"\x00" * 20
    inst_chunk = b"INST" + struct.pack(">I", len(inst_body)) + inst_body

    codes = bytes([11]) + b"VADPCMCODES"
    codes += struct.pack(">hhh", 1, order, npred)   # version, order, npredictors
    for p in range(npred):
        for r in range(order):
            for v in book[p][r]:
                codes += struct.pack(">h", v)
    appl_body = b"stoc" + codes
    appl_chunk = b"APPL" + struct.pack(">I", len(appl_body)) + appl_body

    ssnd_body = struct.pack(">II", 0, 0) + frames   # offset, blockSize, data
    ssnd_chunk = b"SSND" + struct.pack(">I", len(ssnd_body)) + ssnd_body

    body = b"AIFC" + comm_chunk + inst_chunk + appl_chunk + ssnd_chunk
    return b"FORM" + struct.pack(">I", len(body)) + body


def _expect_offsets(aifc):
    """Sanity-check the macro's hard-coded offsets land on the right fields."""
    assert aifc[0:4] == b"FORM"
    assert aifc[8:12] == b"AIFC"
    # codebook must start at 0x70
    i = aifc.find(b"VADPCMCODES")
    assert i >= 0 and i + len(b"VADPCMCODES") + 6 == 0x70, \
        "codebook does not start at 0x70 (got 0x%X)" % (i + len(b"VADPCMCODES") + 6)
    j = aifc.find(b"SSND")
    assert j + 4 == 0xF4, "SSND size word not at 0xF4 (got 0x%X)" % (j + 4)
    assert j + 16 == 0x100, "SSND data not at 0x100 (got 0x%X)" % (j + 16)


# ----------------------------------------------------------------------------- WAV input
def read_wav_mono16(path):
    w = wave.open(path, "rb")
    assert w.getsampwidth() == 2, "need 16-bit PCM"
    nch = w.getnchannels()
    rate = w.getframerate()
    raw = w.readframes(w.getnframes())
    w.close()
    vals = list(struct.unpack("<%dh" % (len(raw) // 2), raw))
    if nch == 2:                                    # downmix to mono
        vals = [(vals[i] + vals[i + 1]) >> 1 for i in range(0, len(vals), 2)]
    return vals, rate


def snr_db(orig, dec):
    n = min(len(orig), len(dec))
    sig = sum(orig[i] * orig[i] for i in range(n))
    noise = sum((orig[i] - dec[i]) ** 2 for i in range(n))
    if noise == 0:
        return float("inf")
    import math
    return 10.0 * math.log10(sig / noise) if sig else 0.0


# ----------------------------------------------------------------------------- CLI
def cmd_decode(args):
    book, frames, nframes, rate = parse_aifc(args[0])
    samples = decode(book, frames)
    print("predictors=%d order=%d frames=%d samples=%d rate=%.0f"
          % (len(book), len(book[0]), len(frames) // 9, len(samples), rate))
    lo, hi = min(samples), max(samples)
    print("sample range: %d .. %d" % (lo, hi))
    if len(args) > 1:
        w = wave.open(args[1], "wb")
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(int(round(rate)) or 16000)
        w.writeframes(struct.pack("<%dh" % len(samples), *(_clamp16(s) for s in samples)))
        w.close()
        print("wrote", args[1])


def soft_limit(samples, drive):
    """tanh soft limiter: raises body loudness while compressing peaks to full scale.
    Small-signal gain ~= drive/tanh(drive); a full-scale input maps to full scale (no hard clip)."""
    import math
    norm = 32767.0 / math.tanh(drive)
    out = []
    for x in samples:
        y = int(round(norm * math.tanh(drive * x / 32767.0)))
        out.append(_clamp16(y))
    return out


def cmd_louder(args):
    """Decode an existing .aifc, apply a tanh soft-limiter, re-encode with the given codebook."""
    import math
    in_aifc, book_aifc, out_path = args[0], args[1], args[2]
    drive = float(args[3]) if len(args) > 3 else 1.6
    book, frames, _nf, rate = parse_aifc(in_aifc)
    src = decode(book, frames)
    n = len(src)
    rms0 = (sum(x * x for x in src) / n) ** 0.5

    cb, _f, _nf2, _r = parse_aifc(book_aifc)
    proc = soft_limit(src, drive)
    rms1 = (sum(x * x for x in proc) / n) ** 0.5
    peak1 = max(abs(x) for x in proc)
    print("drive=%.2f  body gain ~%.2fx (+%.1f dB small-signal)"
          % (drive, drive / math.tanh(drive), 20 * math.log10(drive / math.tanh(drive))))
    print("RMS %.0f (%.1f dBFS) -> %.0f (%.1f dBFS), delta +%.1f dB;  new peak=%d"
          % (rms0, 20 * math.log10(rms0 / 32768), rms1, 20 * math.log10(rms1 / 32768),
             20 * math.log10(rms1 / rms0), peak1))

    new_frames, padded = encode(proc, cb)
    redec = decode(cb, new_frames)
    print("round-trip SNR (vs processed): %.2f dB" % snr_db(proc, redec))
    aifc = build_aifc(cb, new_frames, padded, rate)
    _expect_offsets(aifc)
    with open(out_path, "wb") as f:
        f.write(aifc)
    print("wrote %s (%d bytes, %d frames, %.0f Hz)" % (out_path, len(aifc), len(new_frames) // 9, rate))


def cmd_encode(args):
    wav_path, book_aifc, out_path = args[0], args[1], args[2]
    rate_override = int(args[3]) if len(args) > 3 else None
    samples, rate = read_wav_mono16(wav_path)
    if rate_override:
        rate = rate_override
    book, _f, _nf, _r = parse_aifc(book_aifc)
    print("source: %d samples @ %d Hz; using codebook from %s (%d predictors)"
          % (len(samples), rate, book_aifc, len(book)))
    frames, padded = encode(samples, book)
    redec = decode(book, frames)
    print("round-trip SNR: %.2f dB" % snr_db(samples, redec))
    aifc = build_aifc(book, frames, padded, rate)
    _expect_offsets(aifc)
    with open(out_path, "wb") as f:
        f.write(aifc)
    print("wrote %s (%d bytes, %d frames)" % (out_path, len(aifc), len(frames) // 9))
    print("header check: FORM size=0x%X, codebook@0x70 ok, SSND size@0xF4 ok, data@0x100 ok"
          % struct.unpack(">I", aifc[4:8]))


def main():
    if len(sys.argv) < 2:
        print(__doc__)
        print("usage:\n  vadpcm_encode.py decode in.aifc [out.wav]"
              "\n  vadpcm_encode.py encode in.wav codebook.aifc out.aifc [rate_hz]"
              "\n  vadpcm_encode.py louder in.aifc codebook.aifc out.aifc [drive=1.6]")
        return
    cmd = sys.argv[1]
    if cmd == "decode":
        cmd_decode(sys.argv[2:])
    elif cmd == "encode":
        cmd_encode(sys.argv[2:])
    elif cmd == "louder":
        cmd_louder(sys.argv[2:])
    else:
        print("unknown command:", cmd)


if __name__ == "__main__":
    main()
