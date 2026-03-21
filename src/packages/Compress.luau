--[[
	Compress — compression backends for the Buffer

	Three algorithms, automatically selected based on the data class:
		LZ4HC — pure Lua, fast encode, decent ratio. Preferred for numeric and spatial payloads (Vector3, CFrame arrays).
		Deflate — pure Lua, slower, better ratio. Preferred for text / mixed.
		Zstd — native via EncodingService, server-only. Best ratio and speed when available; silently falls back to LZ4HC on the client or when the service is unavailable.

	Wire format for every compressed payload: tag(u8) | origSize(u32) | compSize(u32) | adler32(u32) | compressed_bytes

	The Adler-32 checksum covers the compressed bytes only.  It catches
	accidental corruption; for tamper detection use a HMAC on the outer buffer.

	Author: @maneetoo
	License: Apache License 2.0 (see LICENSE.md)
--]]

--!strict
--!native
--!optimize 2

local Types = require("../Types")

local RunService = game:GetService("RunService")
local IS_SERVER = RunService:IsServer()	

local buf_create, buf_copy, buf_len, buf_writeu8, buf_writeu32, buf_readu8, buf_readu32 = buffer.create, buffer.copy, buffer.len, buffer.writeu8, buffer.writeu32, buffer.readu8, buffer.readu32
local lshift, rshift, band, bor = bit32.lshift, bit32.rshift, bit32.band, bit32.bor
local mmin, mmax, mfloor = math.min, math.max, math.floor


local function checkBounds(b: buffer, offset: number, need: number, ctx: string)
	local bLen = buf_len(b)
	if offset < 0 or need < 0 or offset + need > bLen then
		error(`[Compress] buffer access out of bounds in {ctx}: need {need} bytes at offset {offset}, buffer size {bLen}`)
	end
end

local function _safeReadu8(b: buffer, offset: number, ctx: string): number
	checkBounds(b, offset, 1, ctx)
	return buf_readu8(b, offset)
end

local function _safeReadu32(b: buffer, offset: number, ctx: string): number
	checkBounds(b, offset, 4, ctx)
	return buf_readu32(b, offset)
end


local T_LZ4 = 47
local T_DEFLATE = 49
local T_ZSTD = 50

--[[
	Header layout: tag(1) + origSize(4) + compSize(4) + adler32(4) = 13 bytes.
]]--
local HEADER_SIZE = 13

local LZ4_MIN_SIZE = 128   --// don't bother compressing tiny payloads
local AUTO_COMPRESS_THRESH = 512   --// auto mode skips compression below this
local DICT_MAX_SIZE = 32768 --// cap the Deflate dictionary to the LZ77 window size

--[[
	Tag ranges used to classify a Buffer-encoded payload from its first byte.
]]--
local NUMERIC_TAG_MIN = 2 --// T_U8
local NUMERIC_TAG_MAX = 9 --// T_F64
local STRING_TAG_MIN = 10 --// T_STR8
local STRING_TAG_MAX = 11 --// T_STR16
local SPATIAL_TAG_MIN = 12 --// T_VEC3
local SPATIAL_TAG_MAX = 15 --// T_COLOR3

--[[
	Data-class detection
	Reads only the first tag byte — O(1), no byte scanning.
]]--
local function detectFromTag(b: buffer): Types.DataHint
	if buf_len(b) == 0 then return "binary" end
	local tag = buf_readu8(b, 0)
	if tag == T_LZ4 or tag == T_DEFLATE or tag == T_ZSTD then return "already_compressed" end
	if tag >= NUMERIC_TAG_MIN and tag <= NUMERIC_TAG_MAX then return "numbers"  end
	if tag >= STRING_TAG_MIN  and tag <= STRING_TAG_MAX then return "text"     end
	if tag >= SPATIAL_TAG_MIN and tag <= SPATIAL_TAG_MAX then return "spatial"  end
	if tag == 18 or tag == 19 then return "numbers" end  --// T_ARRAY, T_ARRAY_RLE
	return "binary"
end

local function resolveHint(b: buffer, hint: Types.DataHint?): Types.DataHint
	if hint and hint ~= "auto" then return hint end
	return detectFromTag(b)
end

--[[
	Deflate dictionary
	
	When set, both encoder and decoder prepend this buffer to the LZ77 history
	window so the compressor can reference common patterns immediately.
	Both sides must use the same dictionary — this is the caller's responsibility.
]]--
local _dict: buffer? = nil
local _dictLen: number = 0

local function setDict(dict: buffer?)
	if not dict then _dict = nil; _dictLen = 0; return end
	local len = buf_len(dict)
	if len > DICT_MAX_SIZE then
		local trimmed = buf_create(DICT_MAX_SIZE)
		buf_copy(trimmed, 0, dict, len - DICT_MAX_SIZE, DICT_MAX_SIZE)
		_dict = trimmed; _dictLen = DICT_MAX_SIZE
	else
		_dict = dict; _dictLen = len
	end
end


--[[
	Adler-32 checksum
	
	Lightweight integrity check on the compressed payload.
	Not cryptographic; use HMAC-SHA256 (Security module) for tamper detection.
]]--
local function adler32(b: buffer, len: number): number
	local s1, s2 = 1, 0
	local bLen = buf_len(b)
	local safeLen = mmin(len, bLen)
	for i = 0, safeLen - 1 do
		s1 = (s1 + buf_readu8(b, i)) % 65521
		s2 = (s2 + s1) % 65521
	end
	return bor(lshift(s2, 16), s1)
end


local function packWrapper(tag: number, origSize: number, comp: buffer, compSize: number): buffer
	local cs = adler32(comp, compSize)
	local out = buf_create(HEADER_SIZE + compSize)
	buf_writeu8(out, 0, tag); buf_writeu32(out, 1, origSize)
	buf_writeu32(out, 5, compSize); buf_writeu8(out, 9, band(rshift(cs, 24), 0xFF))
	buf_writeu8(out, 10, band(rshift(cs, 16), 0xFF))
	buf_writeu8(out, 11, band(rshift(cs,  8), 0xFF))
	buf_writeu8(out, 12, band(cs, 0xFF)); buf_copy(out, HEADER_SIZE, comp, 0, compSize)
	return out
end


local EncodingService: EncodingService? = nil
if IS_SERVER then
	local ok, svc = pcall(function() return game:GetService("EncodingService") end)
	if ok and svc then EncodingService = svc end
end

local function tryZstd(raw: buffer): (buffer, boolean)
	if not EncodingService then return raw, false end
	local origSize = buf_len(raw)
	if origSize < LZ4_MIN_SIZE then return raw, false end
    -- Additional verification and compression attempt via EncodingService (https://create.roblox.com/docs/reference/engine/classes/EncodingService)
	local ok, comp = pcall(function()
		return (EncodingService :: EncodingService):CompressBuffer(raw, Enum.CompressionAlgorithm.Zstd)
	end)
	if not ok or not comp then return raw, false end
	local compSize = buf_len(comp :: buffer)
	if compSize + HEADER_SIZE >= origSize then return raw, false end
	return packWrapper(T_ZSTD, origSize, comp :: buffer, compSize), true
end

local function decompressZstd(payload: buffer, origSize: number): buffer
	if not EncodingService then
		error("[Compress] Zstd decompression is unavailable on the client")
	end
    -- Additional verification and compression attempt via EncodingService (https://create.roblox.com/docs/reference/engine/classes/EncodingService)
	local ok, result = pcall(function()
		return (EncodingService :: EncodingService):DecompressBuffer(payload, Enum.CompressionAlgorithm.Zstd)
	end)
	if not ok or not result then error(`[Compress] ZstdDecompress failed`) end

    if buf_len(result :: buffer) ~= origSize then
        error(`[Compress] Zstd decompressed size mismatch: expected {origSize}, got {buf_len(result :: buffer)}`)
    end
	return result :: buffer
end

--[[
	LZ4HC — High Compression variant of LZ4
]]--
local HC_HASH_SIZE = 4096
local HC_HASH_MASK = HC_HASH_SIZE - 1
local HC_MIN_MATCH = 4
local HC_CHAIN_DEPTH = 8

local function lz4hcCompress(src: buffer, srcLen: number): (buffer, number)
	--// Allocate output buffer with extra space for worst case
	local maxOutSize = srcLen + mfloor(srcLen / 255) + 16 + 64
	local dst = buf_create(maxOutSize)
	local hashHead: { number } = {}
	local hashNext: { [number]: number } = {}
	local sp, dp, litStart = 0, 0, 0

	local function flush(matchOffset: number, matchLen: number)
		local litLen = sp - litStart
		local litTok = if litLen  >= 15 then 15 else litLen
		local mTok = if matchLen > 0 then (if matchLen - 4 >= 15 then 15 else matchLen - 4) else 0

		--// Check output buffer space
		local neededSpace = 1 + (if litLen >= 15 then 1 + mfloor((litLen - 15) / 255) + 1 else 0) + litLen
		if matchLen > 0 then
			neededSpace += 2 + (if matchLen - 4 >= 15 then 1 + mfloor((matchLen - 4 - 15) / 255) + 1 else 0)
		end

		if dp + neededSpace > maxOutSize then
			error("[Compress] LZ4HC output buffer overflow")
		end

		buf_writeu8(dst, dp, bor(lshift(litTok, 4), mTok)); dp += 1
		if litLen >= 15 then
			local rem = litLen - 15
			while rem >= 255 do buf_writeu8(dst, dp, 255); dp += 1; rem -= 255 end
			buf_writeu8(dst, dp, rem); dp += 1
		end
		if litLen > 0 then buf_copy(dst, dp, src, litStart, litLen); dp += litLen end
		if matchLen > 0 then
			buf_writeu8(dst, dp, band(matchOffset, 0xFF))
			buf_writeu8(dst, dp + 1, rshift(matchOffset, 8))
			dp += 2
			if matchLen - 4 >= 15 then
				local rem = matchLen - 4 - 15
				while rem >= 255 do buf_writeu8(dst, dp, 255); dp += 1; rem -= 255 end
				buf_writeu8(dst, dp, rem); dp += 1
			end
		end
		litStart = sp
	end

	--// Need at least 12 bytes at end for last literal sequence
	local limit = if srcLen > 12 then srcLen - 12 else 0
	while sp < limit do
		if sp + 4 > srcLen then break end
		local b0 = buf_readu8(src, sp)
		local b1 = buf_readu8(src, sp + 1)
		local b2 = buf_readu8(src, sp + 2)
		local b3 = buf_readu8(src, sp + 3)
		local h = band(bor(lshift(b0, 8), bor(lshift(b1, 5), bor(lshift(b2, 3), b3))), HC_HASH_MASK)

		local bestLen, bestOff, steps = 0, 0, 0
		local pos = hashHead[h]
		while pos ~= nil and steps < HC_CHAIN_DEPTH do
			local dist = sp - pos
			if dist > 65535 then break end
			--// Bounds check before reading
			if pos + 3 < srcLen then
				if buf_readu8(src, pos) == b0
					and buf_readu8(src, pos + 1) == b1
					and buf_readu8(src, pos + 2) == b2
					and buf_readu8(src, pos + 3) == b3 then
					local mlen = HC_MIN_MATCH
					--// FIX: maxM should be min of remaining source and distance
					local maxM = mmin(srcLen - sp, 65535)
					while mlen < maxM and sp + mlen < srcLen and pos + mlen < srcLen 
						and buf_readu8(src, sp + mlen) == buf_readu8(src, pos + mlen) do
						mlen += 1
					end
					if mlen > bestLen then bestLen = mlen; bestOff = dist end
				end
			end
			pos = hashNext[pos]
			steps += 1
		end

		hashNext[sp] = hashHead[h]; hashHead[h] = sp
		if bestLen >= HC_MIN_MATCH then
			flush(bestOff, bestLen)
			--// Update hash for skipped positions
			for k = 1, bestLen - 1 do
				local skipPos = sp + k
				if skipPos + 4 <= srcLen then
					local sb0 = buf_readu8(src, skipPos)
					local sb1 = buf_readu8(src, skipPos + 1)
					local sb2 = buf_readu8(src, skipPos + 2)
					local sb3 = buf_readu8(src, skipPos + 3)
					local sh = band(bor(lshift(sb0, 8), bor(lshift(sb1, 5), bor(lshift(sb2, 3), sb3))), HC_HASH_MASK)
					hashNext[skipPos] = hashHead[sh]; hashHead[sh] = skipPos
				end
			end
			sp += bestLen
		else
			sp += 1
		end
	end

	--// Flush remaining literals
	sp = srcLen; flush(0, 0)
	return dst, dp
end

local function lz4Decompress(src: buffer, srcLen: number, origSize: number): buffer
	local dst = buf_create(origSize)
	local dstLen = origSize
	local sp, dp = 0, 0

	while sp < srcLen do
		--// Read token
		if sp >= srcLen then break end
		local tok = buf_readu8(src, sp); sp += 1
		local litLen = rshift(tok, 4)
		local mRaw = band(tok, 0x0F)

		--// Extended literal length
		if litLen == 15 then
			while sp < srcLen do
				local x = buf_readu8(src, sp); sp += 1
				litLen += x
				if x ~= 255 then break end
			end
		end

		--// Bounds check for literals
		if sp + litLen > srcLen then
			error(`[Compress] LZ4 corrupt: literal read out of bounds (need {litLen} at sp={sp}, srcLen={srcLen})`)
		end
		if dp + litLen > dstLen then
			error(`[Compress] LZ4 corrupt: literal write out of bounds (need {litLen} at dp={dp}, dstLen={dstLen})`)
		end

		--// Copy literals
		if litLen > 0 then
			buf_copy(dst, dp, src, sp, litLen)
			dp += litLen; sp += litLen
		end

		--// Check if we've reached the end (no match info after last literal)
		if sp >= srcLen then break end

		--// Read offset (2 bytes)
		if sp + 1 >= srcLen then
			error(`[Compress] LZ4 corrupt: offset read out of bounds at sp={sp}`)
		end
		local off = bor(buf_readu8(src, sp), lshift(buf_readu8(src, sp + 1), 8)); sp += 2

		--// Match length
		local mlen = mRaw + 4
		if mRaw == 15 then
			while sp < srcLen do
				local x = buf_readu8(src, sp); sp += 1
				mlen += x
				if x ~= 255 then break end
			end
		end

		--// Source position for match copy
		local ms = dp - off
		if ms < 0 then
			error(`[Compress] LZ4 corrupt: negative match offset at dp={dp}, off={off}`)
		end
		if dp + mlen > dstLen then
			error(`[Compress] LZ4 corrupt: match write out of bounds (need {mlen} at dp={dp}, dstLen={dstLen})`)
		end

		--// Copy match (byte-by-byte for overlapping support)
		for j = 0, mlen - 1 do
			if ms + j >= dp + j then
				error(`[Compress] LZ4 corrupt: match source out of bounds`)
			end
			buf_writeu8(dst, dp + j, buf_readu8(dst, ms + j))
		end
		dp += mlen
	end

	return dst
end

--[[
	Deflate — fixed Huffman (RFC 1951 block type 01)
]]--
local FIXED_LIT_LEN: { number } = {}
do
	for i = 0, 143 do FIXED_LIT_LEN[i] = 8 end
	for i = 144, 255 do FIXED_LIT_LEN[i] = 9 end
	for i = 256, 279 do FIXED_LIT_LEN[i] = 7 end
	for i = 280, 287 do FIXED_LIT_LEN[i] = 8 end
end

local function buildCodes(lengths: { number }): { number }
	local maxLen = 0
	for _, l in lengths do if l > maxLen then maxLen = l end end
	local blCount: { number } = {}
	for i = 0, maxLen do blCount[i] = 0 end
	for _, l in lengths do blCount[l] = (blCount[l] or 0) + 1 end
	local nextCode: { number } = {}; local code = 0; blCount[0] = 0
	for bits = 1, maxLen do
		code = lshift(code + (blCount[bits - 1] or 0), 1)
		nextCode[bits] = code
	end
	local codes: { number } = {}
	for sym, len in ipairs(lengths) do
		if len > 0 then codes[sym - 1] = nextCode[len]; nextCode[len] += 1 end
	end
	return codes
end

local FIXED_CODES = buildCodes(FIXED_LIT_LEN)

local LENGTH_BASE = {3,4,5,6,7,8,9,10,11,13,15,17,19,23,27,31,35,43,51,59,67,83,99,115,131,163,195,227,258}
local LENGTH_EXTRA = {0,0,0,0,0,0,0,0,1,1,1,1,2,2,2,2,3,3,3,3,4,4,4,4,5,5,5,5,0}
local DIST_BASE = {1,2,3,4,5,7,9,13,17,25,33,49,65,97,129,193,257,385,513,769,1025,1537,2049,3073,4097,6145,8193,12289,16385,24577}
local DIST_EXTRA = {0,0,0,0,1,1,2,2,3,3,4,4,5,5,6,6,7,7,8,8,9,9,10,10,11,11,12,12,13,13}

local function lenCode(l: number): (number, number, number)
	for i = #LENGTH_BASE, 1, -1 do
		if l >= LENGTH_BASE[i] then return 256 + i, LENGTH_EXTRA[i], l - LENGTH_BASE[i] end
	end
	return 257, 0, 0
end

local function distCode(d: number): (number, number, number)
	for i = #DIST_BASE, 1, -1 do
		if d >= DIST_BASE[i] then return i - 1, DIST_EXTRA[i], d - DIST_BASE[i] end
	end
	return 0, 0, 0
end

local function deflateCompress(src: buffer, srcLen: number): (buffer, number)
	local history: buffer, histLen: number, srcOffset: number
	if _dict and _dictLen > 0 then
		history = buf_create(_dictLen + srcLen)
		buf_copy(history, 0, _dict :: buffer, 0, _dictLen)
		buf_copy(history, _dictLen, src, 0, srcLen)
		histLen  = _dictLen + srcLen; srcOffset = _dictLen
	else
		history = src; histLen = srcLen; srcOffset = 0
	end

	--// Worst case output size
	local maxOutSize = srcLen + 128 + mfloor(srcLen / 10)
	local dst = buf_create(maxOutSize)
	local bitBuf, bitCount, pos = 0, 0, 0

	local function writeBits(val: number, n: number)
		bitBuf = bor(bitBuf, lshift(val, bitCount)); bitCount += n
		while bitCount >= 8 do
			if pos >= maxOutSize then error("[Compress] Deflate output buffer overflow") end
			buf_writeu8(dst, pos, band(bitBuf, 0xFF)); pos += 1
			bitBuf = rshift(bitBuf, 8); bitCount -= 8
		end
	end

	writeBits(1, 1); writeBits(1, 1); writeBits(0, 1)  --// BFINAL=1, BTYPE=01

	local hashAt: { number } = {}
	local HMASK, WIN_SIZE = 8191, 32768
	local sp = srcOffset

	while sp < histLen do
		if sp + 3 <= histLen then
			local b0 = buf_readu8(history, sp)
			local b1 = buf_readu8(history, sp + 1)
			local b2 = buf_readu8(history, sp + 2)
			local h = band(bor(lshift(b0, 4), bor(lshift(b1, 2), b2)), HMASK)
			local mp = hashAt[h]; hashAt[h] = sp

			if mp and (sp - mp) > 0 and (sp - mp) <= WIN_SIZE then
				local mlen = 0; local maxM = mmin(258, histLen - sp)
				while mlen < maxM and buf_readu8(history, sp + mlen) == buf_readu8(history, mp + mlen) do
					mlen += 1
				end
				if mlen >= 3 then
					local lc, le, lev = lenCode(mlen)
					writeBits(FIXED_CODES[lc] or 0, FIXED_LIT_LEN[lc + 1] or 8)
					if le > 0 then writeBits(lev, le) end
					local dc, de, dev = distCode(sp - mp)
					writeBits(dc, 5)
					if de > 0 then writeBits(dev, de) end
					sp += mlen; continue
				end
			end
		end
		local byte = buf_readu8(history, sp)
		writeBits(FIXED_CODES[byte] or 0, FIXED_LIT_LEN[byte + 1] or 8)
		sp += 1
	end

	writeBits(0, 7) --// end-of-block symbol 256
	if bitCount > 0 then 
		if pos >= maxOutSize then error("[Compress] Deflate output buffer overflow") end
		buf_writeu8(dst, pos, band(bitBuf, 0xFF)); pos += 1 
	end
	return dst, pos
end

local function deflateDecompress(src: buffer, srcLen: number, origSize: number): buffer
	local codeLookup: { [number]: { sym: number, len: number } } = {}
	for sym = 0, 287 do
		local c = FIXED_CODES[sym]; local l = FIXED_LIT_LEN[sym + 1] or 0
		if l > 0 then codeLookup[c] = { sym = sym, len = l } end
	end

	local dst: buffer, dp: number, dstLen: number
	if _dict and _dictLen > 0 then
		dst = buf_create(_dictLen + origSize)
		buf_copy(dst, 0, _dict :: buffer, 0, _dictLen)
		dp = _dictLen
		dstLen = _dictLen + origSize
	else
		dst = buf_create(origSize)
		dp = 0
		dstLen = origSize
	end

	local sp, bitBuf, bitCount = 0, 0, 0

	local function readBit(): number
		if bitCount == 0 then
			if sp >= srcLen then return 0 end
			bitBuf = buf_readu8(src, sp); sp += 1; bitCount = 8
		end
		local bit = band(bitBuf, 1); bitBuf = rshift(bitBuf, 1); bitCount -= 1
		return bit
	end

	local function readBits(n: number): number
		local val = 0
		for i = 0, n - 1 do val = bor(val, lshift(readBit(), i)) end
		return val
	end
	readBits(3)  --// skip BFINAL + BTYPE

	while true do
		local code = 0; local sym = -1
		for bitLen = 1, 9 do
			code = bor(code, lshift(readBit(), bitLen - 1))
			local mirrored = 0
			for b = 0, bitLen - 1 do
				mirrored = bor(mirrored, lshift(band(rshift(code, b), 1), bitLen - 1 - b))
			end
			local entry = codeLookup[mirrored]
			if entry and entry.len == bitLen then sym = entry.sym; break end
		end

		if sym < 0 then break end
		if sym == 256 then break end

		if sym < 256 then
			--// Literal byte
			if dp >= dstLen then
				error(`[Compress] Deflate corrupt: literal write out of bounds at dp={dp}`)
			end
			buf_writeu8(dst, dp, sym); dp += 1
		else
			--// Length/distance pair
			local li = sym - 256
			local extB = LENGTH_EXTRA[li] or 0
			local mlen = (LENGTH_BASE[li] or 3) + (if extB > 0 then readBits(extB) else 0)
			local dc = readBits(5)
			local dext = DIST_EXTRA[dc + 1] or 0
			local dist = (DIST_BASE[dc + 1] or 1) + (if dext > 0 then readBits(dext) else 0)
			local ms = dp - dist

			if ms < 0 then
				error(`[Compress] Deflate corrupt: negative back-reference at dp={dp}, dist={dist}`)
			end
			if dp + mlen > dstLen then
				error(`[Compress] Deflate corrupt: match write out of bounds (need {mlen} at dp={dp}, dstLen={dstLen})`)
			end

			for j = 0, mlen - 1 do 
				buf_writeu8(dst, dp + j, buf_readu8(dst, ms + j)) 
			end
			dp += mlen
		end
	end

	if _dict and _dictLen > 0 then
		local clean = buf_create(origSize)
		buf_copy(clean, 0, dst, _dictLen, origSize)
		return clean
	end
	return dst
end


local function tryLZ4HC(raw: buffer): (buffer, boolean)
	local origSize = buf_len(raw)
	if origSize < LZ4_MIN_SIZE then return raw, false end

	local ok, comp, compSize = pcall(lz4hcCompress, raw, origSize)
	if not ok then return raw, false end

	if compSize + HEADER_SIZE >= origSize then return raw, false end
	return packWrapper(T_LZ4, origSize, comp, compSize), true
end

local function tryDeflate(raw: buffer): (buffer, boolean)
	local origSize = buf_len(raw)
	if origSize < LZ4_MIN_SIZE then return raw, false end

	local ok, comp, compSize = pcall(deflateCompress, raw, origSize)
	if not ok then return raw, false end

	if compSize + HEADER_SIZE >= origSize then return raw, false end
	return packWrapper(T_DEFLATE, origSize, comp, compSize), true
end

local function tryAuto(raw: buffer, hint: Types.DataHint?): (buffer, boolean)
	local size = buf_len(raw)
	if size < AUTO_COMPRESS_THRESH then return raw, false end

	local cls = resolveHint(raw, hint)
	if cls == "already_compressed" then return raw, false end

	if IS_SERVER and EncodingService then
		local c, ok = tryZstd(raw)
		if ok then return c, true end
	end

	if cls == "text" then
		local c, ok = tryDeflate(raw)
		if ok then return c, true end
		return tryLZ4HC(raw)
	end

	if cls == "numbers" or cls == "spatial" then
		return tryLZ4HC(raw)
	end

	local lz4Out, lz4ok = tryLZ4HC(raw)
	if not lz4ok then return tryDeflate(raw) end
	if buf_len(lz4Out) / size > 0.80 then return tryDeflate(raw) end
	return lz4Out, true
end

--[[
	Progressive (chunked) compression
	
	Splits large buffers into 64 KB slices and compresses each independently.
	Output format: u32 chunkCount | (u32 chunkSize | compressed_chunk)...
]]--

local PROG_CHUNK = 65536

--// Forward declaration for compressors table
local Compress = {}

local function compressProgressive(raw: buffer, mode: string, hint: Types.DataHint?, onProgress: Types.ProgressFn?): buffer
	local total = buf_len(raw)

	if total <= PROG_CHUNK then
		local fn = Compress.compressors[mode] or tryAuto
		local out, _ = fn(raw, hint)
		if onProgress then onProgress(total, total) end
		return out
	end

	local parts: { buffer } = {}
	local done = 0

	while done < total do
		local sz = mmin(PROG_CHUNK, total - done)
		local chunk = buf_create(sz); buf_copy(chunk, 0, raw, done, sz)
		local fn = Compress.compressors[mode] or tryAuto
		local out, _ = fn(chunk, hint)
		parts[#parts + 1] = out; done += sz
		if onProgress then onProgress(done, total) end
	end

	local outSize = 4
	for _, p in parts do outSize += 4 + buf_len(p) end
	local joined = buf_create(outSize)
	buf_writeu32(joined, 0, #parts)
	local cursor = 4
	for _, p in parts do
		local sz = buf_len(p)
		buf_writeu32(joined, cursor, sz); cursor += 4
		buf_copy(joined, cursor, p, 0, sz); cursor += sz
	end
	return joined
end

local function decompressProgressive(joined: buffer): buffer
	local joinedLen = buf_len(joined)

	--// Bounds check for chunk count
	if joinedLen < 4 then
		error("[Compress] progressive buffer too short for chunk count")
	end

	local chunkCount = buf_readu32(joined, 0)
	local cursor = 4
	local parts: { buffer } = {}

	--// Sanity check on chunk count
	if chunkCount > 100000 then
		error(`[Compress] suspicious chunk count: {chunkCount}`)
	end

	for i = 1, chunkCount do
		--// Bounds check for chunk size
		if cursor + 4 > joinedLen then
			error(`[Compress] progressive buffer truncated at chunk {i} size`)
		end

		local sz = buf_readu32(joined, cursor); cursor += 4

		--// Bounds check for chunk data
		if cursor + sz > joinedLen then
			error(`[Compress] progressive buffer truncated at chunk {i} data (need {sz} bytes at {cursor}, have {joinedLen})`)
		end

		local chunk = buf_create(sz); buf_copy(chunk, 0, joined, cursor, sz); cursor += sz

		if sz > 0 then
			local tag = buf_readu8(chunk, 0)
			if tag == T_LZ4 or tag == T_DEFLATE or tag == T_ZSTD then
				local dec, _ = Compress.decompress(tag, chunk, 1)
				parts[#parts + 1] = dec
			else
				parts[#parts + 1] = chunk
			end
		else
			parts[#parts + 1] = chunk
		end
	end

	local totalOut = 0; for _, p in parts do totalOut += buf_len(p) end
	local out = buf_create(totalOut); local cur = 0
	for _, p in parts do local sz = buf_len(p); buf_copy(out, cur, p, 0, sz); cur += sz end
	return out
end

--[[
	Entropy visualisation
]]--

local ENTROPY_CHARS = { " ", ".", ":", "-", "=", "+", "*", "#" }
local function visualizeEntropy(b: buffer): string
	local total = buf_len(b)
	if total == 0 then return "[" .. string.rep(" ", 64) .. "]" end

	local segSize = mmax(1, mfloor(total / 64))
	local result: { string } = {}

	for i = 0, 63 do
		local startAt = i * segSize
		local count = mmin(segSize, total - startAt)
		if count <= 0 then result[i + 1] = " "; continue end

		local freq: { number } = {}; for j = 0, 255 do freq[j] = 0 end
		for j = 0, count - 1 do 
			local idx = startAt + j
			if idx < total then
				freq[buf_readu8(b, idx)] += 1 
			end
		end

		local ent = 0.0
		for _, fc in freq do
			if fc > 0 then local p = fc / count; ent -= p * math.log(p, 2) end
		end

		result[i + 1] = ENTROPY_CHARS[mfloor(mmin(ent / 8, 1) * 7) + 1]
	end

	return "[" .. table.concat(result) .. "]"
end


Compress.T_LZ4 = T_LZ4
Compress.T_DEFLATE = T_DEFLATE
Compress.T_ZSTD  = T_ZSTD
Compress.HEADER_SIZE = HEADER_SIZE

function Compress.SetDict(dict: buffer?) setDict(dict) end
function Compress.GetDict(): buffer?     return _dict  end

function Compress.Compress(raw: buffer, hint: Types.DataHint?): (buffer, boolean)
	return tryAuto(raw, hint)
end

function Compress.CompressMode(mode: string, raw: buffer, hint: Types.DataHint?): (buffer, boolean)
	local fn = Compress.compressors[mode]
	if fn then return fn(raw, hint) end
	return tryAuto(raw, hint)
end

function Compress.CompressProgressive(raw: buffer, mode: string, hint: Types.DataHint?, onProgress: Types.ProgressFn?): buffer
	return compressProgressive(raw, mode, hint, onProgress)
end

function Compress.DecompressProgressive(b: buffer): buffer
	return decompressProgressive(b)
end

function Compress.decompress(tag: number, src: buffer, offset: number): (buffer, number)
	local srcLen = buf_len(src)

	--// Bounds check for header
	if offset < 0 or offset + 12 > srcLen then
		error(`[Compress] buffer too short for decompress header: need 12 bytes at offset {offset}, have {srcLen}`)
	end

	local origSize = buf_readu32(src, offset)
	local compSize = buf_readu32(src, offset + 4)

	--// Sanity checks
	if origSize > 100_000_000 then
		error(`[Compress] suspicious origSize: {origSize}`)
	end
	if compSize > 100_000_000 then
		error(`[Compress] suspicious compSize: {compSize}`)
	end

	local storedCS = bor(
		lshift(buf_readu8(src, offset + 8),  24), 
		lshift(buf_readu8(src, offset + 9),  16), 
		lshift(buf_readu8(src, offset + 10),  8), 
		buf_readu8(src, offset + 11)
	)
	local payStart = offset + 12

	--// Bounds check for payload
	if payStart + compSize > srcLen then
		error(`[Compress] buffer too short for payload: need {compSize} bytes at {payStart}, have {srcLen - payStart}`)
	end

	local payload = buf_create(compSize)
	buf_copy(payload, 0, src, payStart, compSize)

	local computedCS = adler32(payload, compSize)
	if computedCS ~= storedCS then
		error(string.format("[Compress] checksum mismatch (tag=%d offset=%d): stored=0x%08X computed=0x%08X", tag, offset, storedCS, computedCS))
	end

	local result: buffer
	if tag == T_ZSTD then 
		result = decompressZstd(payload, origSize)
	elseif tag == T_LZ4 then 
		result = lz4Decompress(payload, compSize, origSize)
	else 
		result = deflateDecompress(payload, compSize, origSize) 
	end

	return result, payStart + compSize
end

function Compress.Adler32(b: buffer): number return adler32(b, buf_len(b)) end
function Compress.VisualizeEntropy(b: buffer): string return visualizeEntropy(b) end
function Compress.DetectClass(b: buffer): Types.DataHint return detectFromTag(b) end

--// Define compressors table after all functions are defined
Compress.compressors = {
	lz4     = function(b: buffer, _: Types.DataHint?) return tryLZ4HC(b)            end,
	deflate = function(b: buffer, _: Types.DataHint?) return tryDeflate(b)          end,
	auto    = function(b: buffer, h: Types.DataHint?) return tryAuto(b, h)          end,
	none    = function(b: buffer, _: Types.DataHint?) return b, false               end,
	text    = function(b: buffer, _: Types.DataHint?) return tryDeflate(b)          end,
	numbers = function(b: buffer, _: Types.DataHint?) return tryLZ4HC(b)            end,
	spatial = function(b: buffer, _: Types.DataHint?) return tryLZ4HC(b)            end,
	binary  = function(b: buffer, _: Types.DataHint?) return tryAuto(b, "binary")   end,
}

return Compress
