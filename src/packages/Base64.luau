--[[
	Base64 — Encode and decode buffers using standard or URL-safe base64

	Supports both RFC 4648 §4 (standard, with `=` padding) and
	RFC 4648 §5 (URL-safe, `-_` instead of `+/`, no padding).
	The decoder auto-detects the alphabet from the input.

	For large buffers (> ~100 KB) prefer CreateEncoderStream, which processes
	data in 48 KB chunks and avoids one large intermediate string allocation.

	Features:
	• O(n) encoding and decoding
	• Streaming encoder for large data
	• Auto-detection of standard vs URL-safe alphabet
	• Comprehensive error messages for invalid input
	• Zero external dependencies (uses only Roblox APIs & t - A Runtime Typechecker for Roblox)

	Author: @maneetoo
	GitRepo: https://github.com/maneetoo/Buffer
	License: Apache License 2.0 (see LICENSE.md)
--]]

--!strict
--!native

local t = require("../t")

export type EncoderStream = {
	write: (self: EncoderStream, b: buffer, offset: number?, length: number?) -> (boolean, string?),
	finalize: (self: EncoderStream) -> (string?, string?),
	cancel: (self: EncoderStream) -> (),
}

local STD_CHARS = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
local URL_CHARS = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_"

--[[
	How many source bytes are encoded per stream chunk.
	48,000 is chosen because:
	• It is a multiple of 3 (no inter-chunk carry for main loop)
	• Encodes to exactly 64,000 base64 characters
	• Well inside a single 1 MB scratch buffer
]]
local STREAM_CHUNK = 48_000


--[[
	Build forward (index → char) and reverse (byte → index) lookup tables
	for one alphabet. Done once at require-time for performance.
]]
local function buildTables(chars: string): ({ [number]: string }, { [number]: number })
	local enc: { [number]: string } = {}
	local dec: { [number]: number } = {}
	for i = 0, 63 do
		local char = string.sub(chars, i + 1, i + 1)
		enc[i] = char
		dec[string.byte(char)] = i
	end
	return enc, dec
end

local STD_ENC, STD_DEC = buildTables(STD_CHARS)
local URL_ENC, URL_DEC = buildTables(URL_CHARS)


local buf_create, buf_len, buf_readu8, buf_writeu8, buf_copy = buffer.create, buffer.len, buffer.readu8, buffer.writeu8, buffer.copy
local lshift, rshift, band, bor = bit32.lshift, bit32.rshift, bit32.band, bit32.bor
local mfloor, mmin, tconcat, tcreate, sbyte, smatch, sgsub = math.floor, math.min, table.concat, table.create, string.byte, string.match, string.gsub
local tBuffer, tString = t.buffer, t.string



--[[
	Encode a buffer to base64 string.
	
	@param b The buffer to encode
	@param enc The encoding table (STD_ENC or URL_ENC)
	@param urlSafe Whether to omit padding (for URL-safe encoding)
	@return The base64 encoded string
]]
local function encodeBuffer(b: buffer, enc: { [number]: string }, urlSafe: boolean): string
	local len = buf_len(b)
	if len == 0 then
		return ""
	end

	-- Pre-allocate output array
	local outputLen = mfloor((len + 2) / 3) * 4
	if urlSafe then
		-- URL-safe encoding doesn't use padding
		local rem = len % 3
		if rem == 1 then
			outputLen -= 2
		elseif rem == 2 then
			outputLen -= 1
		end
	end

	local chunks = tcreate(outputLen)
	local ci, i = 0, 0

	-- Process complete 3-byte groups
	while i + 2 < len do
		local b0 = buf_readu8(b, i)
		local b1 = buf_readu8(b, i + 1)
		local b2 = buf_readu8(b, i + 2)

		ci += 1; chunks[ci] = enc[rshift(b0, 2)]
		ci += 1; chunks[ci] = enc[bor(lshift(band(b0, 3), 4), rshift(b1, 4))]
		ci += 1; chunks[ci] = enc[bor(lshift(band(b1, 15), 2), rshift(b2, 6))]
		ci += 1; chunks[ci] = enc[band(b2, 63)]
		i += 3
	end

	-- Handle remaining bytes (0, 1, or 2)
	local rem = len - i
	if rem == 1 then
		local b0 = buf_readu8(b, i)
		ci += 1; chunks[ci] = enc[rshift(b0, 2)]
		ci += 1; chunks[ci] = enc[lshift(band(b0, 3), 4)]
		if not urlSafe then
			ci += 1; chunks[ci] = "="
			ci += 1; chunks[ci] = "="
		end
	elseif rem == 2 then
		local b0 = buf_readu8(b, i)
		local b1 = buf_readu8(b, i + 1)
		ci += 1; chunks[ci] = enc[rshift(b0, 2)]
		ci += 1; chunks[ci] = enc[bor(lshift(band(b0, 3), 4), rshift(b1, 4))]
		ci += 1; chunks[ci] = enc[lshift(band(b1, 15), 2)]
		if not urlSafe then
			ci += 1; chunks[ci] = "="
		end
	end

	return tconcat(chunks)
end


--[[
	Decode a base64 string to a buffer.
	
	@param s The base64 string to decode
	@param dec The decoding table (STD_DEC or URL_DEC)
	@return (buffer, nil) on success, (nil, errorMsg) on failure
]]
local function decodeString(s: string, dec: { [number]: number }): (buffer?, string?)
	-- Strip padding and whitespace
	local clean = sgsub(s, "[=%s]", "")
	local slen = #clean

	if slen == 0 then
		return buf_create(0), nil
	end

	-- Validate length
	local rem = slen % 4
	if rem == 1 then
		-- A single leftover character is never valid base64
		-- (6 bits is not enough to form even one byte)
		return nil, "[Base64] invalid input: length mod 4 == 1 after stripping padding"
	end

	-- Calculate output length
	-- Each group of 4 base64 chars encodes 3 bytes
	-- Trailing groups of 2 or 3 chars encode 1 or 2 bytes
	local outLen = mfloor(slen / 4) * 3
	if rem == 2 then
		outLen += 1
	elseif rem == 3 then
		outLen += 2
	end

	local b = buf_create(outLen)
	local bi, i = 0, 1

	-- Process complete 4-character groups
	while i + 3 <= slen do
		local byte0 = sbyte(clean, i)
		local byte1 = sbyte(clean, i + 1)
		local byte2 = sbyte(clean, i + 2)
		local byte3 = sbyte(clean, i + 3)

		local c0 = dec[byte0]
		local c1 = dec[byte1]
		local c2 = dec[byte2]
		local c3 = dec[byte3]

		-- Reject characters not in the alphabet
		if not c0 then
			return nil, string.format("[Base64] invalid character '%s' (0x%02X) at position %d", 
				string.char(byte0), byte0, i)
		end
		if not c1 then
			return nil, string.format("[Base64] invalid character '%s' (0x%02X) at position %d", 
				string.char(byte1), byte1, i + 1)
		end
		if not c2 then
			return nil, string.format("[Base64] invalid character '%s' (0x%02X) at position %d", 
				string.char(byte2), byte2, i + 2)
		end
		if not c3 then
			return nil, string.format("[Base64] invalid character '%s' (0x%02X) at position %d", 
				string.char(byte3), byte3, i + 3)
		end

		buf_writeu8(b, bi, bor(lshift(c0, 2), rshift(c1, 4)))
		buf_writeu8(b, bi + 1, band(bor(lshift(c1, 4), rshift(c2, 2)), 0xFF))
		buf_writeu8(b, bi + 2, band(bor(lshift(c2, 6), c3), 0xFF))
		bi += 3
		i += 4
	end

	-- Handle trailing 2 or 3 character group
	if rem == 2 then
		local byte0 = sbyte(clean, i)
		local byte1 = sbyte(clean, i + 1)
		local c0 = dec[byte0]
		local c1 = dec[byte1]

		if not c0 or not c1 then
			local badByte = not c0 and byte0 or byte1
			local badPos = not c0 and i or i + 1
			return nil, string.format("[Base64] invalid character '%s' (0x%02X) in trailing group at position %d",
				string.char(badByte), badByte, badPos)
		end

		buf_writeu8(b, bi, bor(lshift(c0, 2), rshift(c1, 4)))
	elseif rem == 3 then
		local byte0 = sbyte(clean, i)
		local byte1 = sbyte(clean, i + 1)
		local byte2 = sbyte(clean, i + 2)
		local c0 = dec[byte0]
		local c1 = dec[byte1]
		local c2 = dec[byte2]

		if not c0 or not c1 or not c2 then
			local badByte = not c0 and byte0 or (not c1 and byte1 or byte2)
			local badPos = not c0 and i or (not c1 and i + 1 or i + 2)
			return nil, string.format("[Base64] invalid character '%s' (0x%02X) in trailing group at position %d",
				string.char(badByte), badByte, badPos)
		end

		buf_writeu8(b, bi, bor(lshift(c0, 2), rshift(c1, 4)))
		buf_writeu8(b, bi + 1, band(bor(lshift(c1, 4), rshift(c2, 2)), 0xFF))
	end

	return b, nil
end

--[[
	Pick the right decode table based on the presence of URL-safe characters.
]]
local function pickDec(s: string): { [number]: number }
	return if smatch(s, "[-_]") then URL_DEC else STD_DEC
end


--[[
	Create a streaming encoder for processing large buffers in chunks.
	
	@param enc The encoding table
	@param urlSafe Whether to use URL-safe encoding
	@return An EncoderStream instance
]]
local function createEncoderStream(enc: { [number]: string }, urlSafe: boolean): EncoderStream
	local parts: { string } = {}
	local pendingBuf: buffer? = nil
	local pendingLen = 0
	local sealed = false
	local cancelled = false

	local stream = {} :: EncoderStream

	function stream:write(b: buffer, offset: number?, length: number?): (boolean, string?)
		if sealed then
			return false, "[Base64.Stream] stream already finalised"
		end
		if cancelled then
			return false, "[Base64.Stream] stream cancelled"
		end

		local startAt = offset or 0
		local count = length or (buf_len(b) - startAt)

		if count <= 0 then
			return true, nil
		end

		-- Validate bounds
		if startAt < 0 or startAt + count > buf_len(b) then
			return false, "[Base64.Stream] offset/length out of bounds"
		end

		-- Merge leftover bytes from previous write with new data
		local src: buffer
		if pendingLen > 0 and pendingBuf then
			src = buf_create(pendingLen + count)
			buf_copy(src, 0, pendingBuf, 0, pendingLen)
			buf_copy(src, pendingLen, b, startAt, count)
			pendingBuf = nil
			pendingLen = 0
		else
			src = buf_create(count)
			buf_copy(src, 0, b, startAt, count)
		end

		local total = buf_len(src)

		-- Only encode whole triplets; carry over 1 or 2 leftover bytes
		local aligned = total - (total % 3)

		local pos = 0
		while pos < aligned do
			local sz = mmin(STREAM_CHUNK, aligned - pos)
			local chunk = buf_create(sz)
			buf_copy(chunk, 0, src, pos, sz)
			parts[#parts + 1] = encodeBuffer(chunk, enc, urlSafe)
			pos += sz
		end

		local leftover = total - aligned
		if leftover > 0 then
			pendingBuf = buf_create(leftover)
			buf_copy(pendingBuf:: buffer, 0, src, aligned, leftover)
			pendingLen = leftover
		end

		return true, nil
	end

	function stream:finalize(): (string?, string?)
		if cancelled then
			return nil, "[Base64.Stream] stream cancelled"
		end
		if sealed then
			return nil, "[Base64.Stream] stream already finalised"
		end
		sealed = true

		-- Encode any trailing bytes (1 or 2), adding padding if needed
		if pendingLen > 0 and pendingBuf then
			local tail = buf_create(pendingLen)
			buf_copy(tail, 0, pendingBuf, 0, pendingLen)
			parts[#parts + 1] = encodeBuffer(tail, enc, urlSafe)
			pendingBuf = nil
			pendingLen = 0
		end

		return tconcat(parts), nil
	end

	function stream:cancel()
		if not sealed and not cancelled then
			cancelled = true
			pendingBuf = nil
			pendingLen = 0
			table.clear(parts)
		end
	end

	return stream
end


--[[
	Check if a string is valid base64 (without decoding).
	
	@param s The string to validate
	@return true if valid, false otherwise
]]
local function isValidBase64(s: string): boolean
	if type(s) ~= "string" then
		return false
	end

	-- Strip padding and whitespace
	local clean = sgsub(s, "[=%s]", "")
	local slen = #clean

	if slen == 0 then
		return true
	end

	-- Check length
	local rem = slen % 4
	if rem == 1 then
		return false
	end

	-- Check all characters are valid
	local dec = pickDec(s)
	for i = 1, slen do
		if not dec[sbyte(clean, i)] then
			return false
		end
	end

	return true
end

--[[
	Calculate the encoded size of a buffer without actually encoding.
	
	@param inputSize Size of the input buffer in bytes
	@param urlSafe Whether URL-safe encoding (no padding) will be used
	@return The size of the encoded string in characters
]]
local function calculateEncodedSize(inputSize: number, urlSafe: boolean?): number
	if inputSize == 0 then
		return 0
	end

	local outputLen = mfloor((inputSize + 2) / 3) * 4

	if urlSafe then
		local rem = inputSize % 3
		if rem == 1 then
			outputLen -= 2
		elseif rem == 2 then
			outputLen -= 1
		end
	end

	return outputLen
end

--[[
	Calculate the decoded size from a base64 string without decoding.
	
	@param s The base64 string
	@return The size of the decoded buffer in bytes, or nil if invalid
]]
local function calculateDecodedSize(s: string): number?
	if type(s) ~= "string" then
		return nil
	end

	local clean = sgsub(s, "[=%s]", "")
	local slen = #clean

	if slen == 0 then
		return 0
	end

	local rem = slen % 4
	if rem == 1 then
		return nil  -- Invalid
	end

	local outLen = mfloor(slen / 4) * 3
	if rem == 2 then
		outLen += 1
	elseif rem == 3 then
		outLen += 2
	end

	return outLen
end


local Base64 = {}

--[[
	Encode a buffer to standard base64 (RFC 4648 §4).
	Output includes `=` padding and uses the `+/` alphabet.
	Safe for DataStore string fields and JSON.
	
	@param b The buffer to encode
	@return The base64 encoded string
	
	Example:
		local encoded = Base64.Encode(myBuffer)
]]
function Base64.Encode(b: buffer): string
	assert(tBuffer(b), "[Base64.Encode] expected buffer")
	return encodeBuffer(b, STD_ENC, false)
end

--[[
	Encode a buffer to URL-safe base64 (RFC 4648 §5).
	Uses `-_` instead of `+/` and omits `=` padding.
	Safe for URL path segments, filenames, and HTTP headers.
	
	@param b The buffer to encode
	@return The URL-safe base64 encoded string
	
	Example:
		local encoded = Base64.EncodeURL(myBuffer)
]]
function Base64.EncodeURL(b: buffer): string
	assert(tBuffer(b), "[Base64.EncodeURL] expected buffer")
	return encodeBuffer(b, URL_ENC, true)
end

--[[
	Decode a base64 string safely.
	Accepts both standard and URL-safe alphabets.
	Handles padding transparently.
	
	@param s The base64 string to decode
	@return (buffer, nil) on success, (nil, errorMsg) on failure
	
	Unlike Decode, this version does not throw on invalid input.
	Use this when decoding data from untrusted sources.
	
	Example:
		local buf, err = Base64.SafeDecode(encodedString)
		if not buf then
			warn("Decode failed:", err)
		end
]]
function Base64.SafeDecode(s: string): (buffer?, string?)
	if not tString(s) then
		return nil, "[Base64.SafeDecode] expected string, got " .. typeof(s)
	end
	return decodeString(s, pickDec(s))
end

--[[
	Decode a base64 string.
	Accepts both standard and URL-safe alphabets.
	
	@param s The base64 string to decode
	@return The decoded buffer
	@throws On invalid input
	
	Use SafeDecode when the input is untrusted.
	
	Example:
		local buf = Base64.Decode(encodedString)
]]
function Base64.Decode(s: string): buffer
	assert(tString(s), "[Base64.Decode] expected string")
	local result, err = decodeString(s, pickDec(s))
	if not result then
		error(err :: string, 2)
	end
	return result
end

--[[
	Create a streaming encoder for large buffers.
	Process data incrementally with :write(), then seal with :finalize().
	
	@param urlSafe Whether to use URL-safe encoding (default: false)
	@return An EncoderStream instance
	
	Example:
		local stream = Base64.CreateEncoderStream(true)
		stream:write(chunk1)
		stream:write(chunk2)
		local result, err = stream:finalize()
]]
function Base64.CreateEncoderStream(urlSafe: boolean?): EncoderStream
	local safe = urlSafe == true
	return createEncoderStream(if safe then URL_ENC else STD_ENC, safe)
end

--[[
	Check if a string is valid base64 without decoding.
	
	@param s The string to validate
	@return true if valid base64, false otherwise
	
	Example:
		if Base64.IsValid(maybeBase64) then
			local buf = Base64.Decode(maybeBase64)
		end
]]
function Base64.IsValid(s: string): boolean
	return isValidBase64(s)
end

--[[
	Calculate the encoded size of a buffer without encoding.
	
	@param inputSize Size of the input in bytes
	@param urlSafe Whether URL-safe encoding will be used
	@return The size of the encoded output in characters
	
	Example:
		local size = Base64.GetEncodedSize(buffer.len(myBuffer))
]]
function Base64.GetEncodedSize(inputSize: number, urlSafe: boolean?): number
	return calculateEncodedSize(inputSize, urlSafe)
end

--[[
	Calculate the decoded size from a base64 string without decoding.
	
	@param s The base64 string
	@return The size of the decoded output in bytes, or nil if invalid
	
	Example:
		local size = Base64.GetDecodedSize(encodedString)
		if size then
			print("Will decode to", size, "bytes")
		end
]]
function Base64.GetDecodedSize(s: string): number?
	return calculateDecodedSize(s)
end

return Base64
