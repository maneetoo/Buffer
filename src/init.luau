--[[
	Buffer

	Next-Gen Binary Serialiser for Roblox (Luau).
	Encodes almost every Roblox/Lua value type into a binary buffer with tags.

	Author: @maneetoo
	GitRepo: https://github.com/maneetoo/Buffer
	License: Apache 2.0 (see LICENSE)
	Version: 1.0.0

	──────────────────────────────────────────────────────────────────────────

	Wiki: https://maneetoo.github.io/Buffer/

	──────────────────────────────────────────────────────────────────────────

	SUPPORTED TYPES

		Primitives    boolean · number (u8 → f64, auto-sized) · string (≤ 65535 bytes)
		Math          Vector2/3 · Vector2/3int16 · CFrame · UDim/UDim2 · Ray · Rect
		Color         Color3 · BrickColor · ColorSequence · ColorSequenceKeypoint
		Sequences     NumberSequence · NumberSequenceKeypoint
		Roblox misc   EnumItem · Font · Content · DateTime · Region3 · Region3int16
		              PhysicalProperties · Axes · Faces · TweenInfo
		Containers    table (dict) · array (with RLE for repetitive data)
		Special       Instance (registered u32 reference) · custom registered types
	
--]]--


--!strict
--!native
--!optimize 2

local Buffer = {}

local Cache = require(script.classes.Cache)
local Base64 = require(script.packages.Base64)
local Trove = require(script.classes.Trove)
local Compress = require(script.packages.Compress)
local TypeDefs = require(script.Types)
local t = require(script.t)


export type EncodeResult = TypeDefs.EncodeResult
export type DecodeResult = TypeDefs.DecodeResult
export type Priority = TypeDefs.Priority
export type CachePolicy = TypeDefs.CachePolicy
export type CompressionMode = TypeDefs.CompressionMode
export type Schema = TypeDefs.Schema
export type SchemaField = TypeDefs.SchemaField
export type CustomType = TypeDefs.CustomType
export type CustomEncoder = TypeDefs.CustomEncoder
export type CustomDecoder = TypeDefs.CustomDecoder
export type Stream = TypeDefs.Stream
export type AsyncHandle = TypeDefs.AsyncHandle
export type SchemaType = TypeDefs.SchemaType
export type MigrationStep = TypeDefs.MigrationStep
export type MigrationMap = TypeDefs.MigrationMap
export type EncoderStream = TypeDefs.EncoderStream
export type ProgressFn = TypeDefs.ProgressFn
export type BufferModule = TypeDefs.BufferModule
export type DataHint = TypeDefs.DataHint
export type CompiledSchema = TypeDefs.CompiledSchema
export type CompiledField = TypeDefs.CompiledField


local T_NIL, T_BOOL = 0, 1
local T_U8, T_U16, T_U32, T_I8, T_I16, T_I32, T_F32, T_F64 = 2, 3, 4, 5, 6, 7, 8, 9
local T_STR8, T_STR16 = 10, 11
local T_VEC3, T_CF_LOSSY, T_CF_FULL, T_COLOR3 = 12, 13, 14, 15
local T_TABLE, T_ARRAY, T_ARRAY_RLE = 17, 18, 19
local T_VEC2, T_UDIM2, T_RAY = 20, 21, 22
local T_NRANGE, T_BRICKCLR, T_ENUM, T_DELTA = 23, 24, 25, 26
local T_UDIM, T_RECT = 27, 28
local T_COLORSEQ, T_NUMSEQ = 29, 30
local T_FONT, T_CONTENT = 31, 32
local T_VEC3INT16, T_VEC2INT16 = 33, 34
local T_PHYSPROP, T_PHYSPROP_DEFAULT = 35, 36
local T_DATETIME, T_REGION3, T_REGION3INT16 = 38, 39, 40
local T_CUSTOM = 41
local T_AXES, T_FACES, T_TWEENINFO = 42, 43, 44
local T_COLORSEQKP, T_NUMBERSEQKP = 45, 46
local T_INSTANCE = 48
local T_LZ4, T_DEFLATE, T_ZSTD = 47, 49, 50


local MAX_DEPTH = 32
local RLE_MIN_LEN = 64
local RLE_MIN_RUN = 3
local STR_CACHE_MAX = 1000
local SCRATCH_SIZE = 1_000_000
local SCRATCH_POOL_SIZE = 2
local CHUNK_FIELD_MAX = 4096
local ASYNC_FIELDS_PER_STEP = 256


local buf_create, buf_copy, buf_len = buffer.create, buffer.copy, buffer.len
local buf_writeu8, buf_writeu16, buf_writeu32 = buffer.writeu8, buffer.writeu16, buffer.writeu32
local buf_writei8, buf_writei16, buf_writei32 = buffer.writei8, buffer.writei16, buffer.writei32
local buf_writef32, buf_writef64 = buffer.writef32, buffer.writef64
local buf_readu8, buf_readu16, buf_readu32 = buffer.readu8, buffer.readu16, buffer.readu32
local buf_readi8, buf_readi16, buf_readi32 = buffer.readi8, buffer.readi16, buffer.readi32
local buf_readf32, buf_readf64 = buffer.readf32, buffer.readf64
local buf_writestring, buf_readstring = buffer.writestring, buffer.readstring

local mfloor, mround, mabs = math.floor, math.round, math.abs
local tconcat, tcreate, tunpack = table.concat, table.create, table.unpack
local lshift, _rshift, band, bor = bit32.lshift, bit32.rshift, bit32.band, bit32.bor

--[[
	Used only for the f32 round-trip check in numTag.
	Never held across a yield — safe as a module-level singleton.
]]--
local F32_TMP = buf_create(4)

--[[
	Pre-allocated singletons.

	Encode(true) / Encode(false) / Encode(0) return these
	directly, so they do zero heap allocations.
]]--
local TRUE_BUF = buf_create(2); buf_writeu8(TRUE_BUF,  0, T_BOOL); buf_writeu8(TRUE_BUF,  1, 1)
local FALSE_BUF = buf_create(2); buf_writeu8(FALSE_BUF, 0, T_BOOL); buf_writeu8(FALSE_BUF, 1, 0)
local ZERO_BUF = buf_create(2); buf_writeu8(ZERO_BUF,  0, T_U8); buf_writeu8(ZERO_BUF,  1, 0)

--[[
	Scratch-buffer pool.

	Luau is cooperative, but two coroutines can interleave at any yield point.
	encodeInto never yields, so a single call is safe. The risk is a second
	coroutine calling Encode before the first has released its scratch buffer.
	We keep SCRATCH_POOL_SIZE pre-allocated slots; if all are busy a transient
	buffer is allocated and discarded after the call.
]]--
local _pool: { buffer } = {}
local _inUse: { [buffer]: true } = {}
for _ = 1, SCRATCH_POOL_SIZE do
	local b = buf_create(SCRATCH_SIZE)
	_pool[#_pool + 1] = b
end

local function acquireScratch(): buffer
	for _, b in _pool do
		if not _inUse[b] then _inUse[b] = true; return b end
	end
	local b = buf_create(SCRATCH_SIZE); _inUse[b] = true; return b
end

local function releaseScratch(b: buffer)
	_inUse[b] = nil
end

local function joinBuffers(parts: { buffer }): buffer
	local total = 0
	for _, p in parts do total += buf_len(p) end
	local out = buf_create(total); local cur = 0
	for _, p in parts do
		local sz = buf_len(p); buf_copy(out, cur, p, 0, sz); cur += sz
	end
	return out
end

--[[
	Instance registry.

	Instances are encoded as a u32 reference id.
	The receiver must call RegisterInstance with the same id before decoding.
	Trove watches each Instance's Destroying signal to auto-unregister.
]]--
local _instanceToId: { [Instance]: number } = {}
local _idToInstance: { [number]:   Instance } = {}
local _instanceTroves: { [Instance]: typeof(Trove.new()) } = {}

local Caches = {
	hot = Cache.new(100),
	warm = Cache.new(500),
	cold = Cache.new(2000),
}

local function getCache(priority: Priority) return Caches[priority] end
local function isCacheable(value: any): boolean
	local vt = typeof(value)
	if vt == "table" then return false end
	if vt == "Instance" then return false end
	if vt == "string" and #(value :: string) > STR_CACHE_MAX then return false end
	return true
end

--[[
	djb2-variant content hash used by EncodeWithPolicy("always" | "if-shallow").
	Fast, not cryptographic.
]]--
local _hashCache = Cache.new(256)
local function quickHash(value: { [any]: any }): string
	local parts: { string } = {}
	for k, v in pairs(value) do
		parts[#parts + 1] = tostring(k) .. "=" .. typeof(v) .. ":" .. tostring(v)
	end
	table.sort(parts)
	return table.concat(parts, "|")
end


local CustomRegistry: { [number]: CustomType } = {}
local CustomByType: { [string]: { id: number, ct: CustomType } } = {}


local tEncodable = t.union(
	t.boolean, t.number, t.string,
	t.Vector3, t.Vector2, t.Vector3int16, t.Vector2int16,
	t.CFrame, t.Color3, t.ColorSequence, t.ColorSequenceKeypoint,
	t.UDim, t.UDim2, t.Ray, t.NumberRange, t.NumberSequence, t.NumberSequenceKeypoint,
	t.BrickColor, t.EnumItem, t.table,
	t.Rect, t.Font, t.PhysicalProperties,
	t.DateTime, t.Region3, t.Region3int16,
	t.Axes, t.Faces, t.TweenInfo, t.Instance
)

local tBuf, tEnumType = t.buffer, t.Enum
local tPriority = t.literal("hot", "warm", "cold")

--[[
	Number tag selection.

	Picks the smallest integer tag that encodes n without loss.
	Falls back to f32 when n round-trips through a 32-bit float, else f64.
]]--
local function numTag(n: number): number
	if n ~= n or n == math.huge or n == -math.huge then return T_F64 end
	if n == mfloor(n) then
		if n >= 0 then
			if n <= 0xFF then return T_U8  end
			if n <= 0xFFFF then return T_U16 end
			if n <= 0xFFFFFFFF then return T_U32 end
		else
			if n >= -128 and n <= 127 then return T_I8  end
			if n >= -32768 and n <= 32767 then return T_I16 end
			if n >= -2147483648 and n <= 2147483647 then return T_I32 end
		end
		return T_F64
	end
	buf_writef32(F32_TMP, 0, n)
	return if buf_readf32(F32_TMP, 0) == n then T_F32 else T_F64
end


local function checkBounds(b: buffer, offset: number, need: number, ctx: string)
	if offset < 0 or offset + need > buf_len(b) then
		error(`[Buffer] underflow in {ctx}: need {need} at offset {offset}, have {buf_len(b) - offset}`)
	end
end

local function safeReadString(b: buffer, offset: number, len: number, ctx: string): string
	checkBounds(b, offset, len, ctx)
	return buf_readstring(b, offset, len)
end


local function checkArray(tbl: { [any]: any }): (boolean, number)
	local maxKey = 0; local count = 0
	for k in pairs(tbl) do
		count += 1
		if type(k) ~= "number" or k ~= mfloor(k) or k < 1 then return false, 0 end
		if (k :: number) > maxKey then maxKey = k :: number end
	end
	return maxKey == count, count
end

local function shouldRLE(arr: { any }, count: number): boolean
	if count < RLE_MIN_LEN then return false end
	local net = 0; local i = 1
	while i <= count do
		local run = 1
		while (i + run) <= count and arr[i + run] == arr[i] do run += 1 end
		if run >= RLE_MIN_RUN then net += (run - 1) * 2 - 2 end
		i += run
	end
	return net > 0
end

--[[
	tableKeyToString converts a table key to the string that will be written
	on the wire and restored on decode.

	Rules:
	  · string keys  — used as-is.
	  · number keys  — converted with tostring() preserving the full value
	    (e.g. 1.5 → "1.5", -0.5 → "-0.5"). mfloor is intentionally NOT used
	    here: rounding would cause 1 and 1.5 to both become "1", silently
	    clobbering one entry.
	  · any other key type (boolean, function, userdata, thread …) — rejected
	    with an error because these cannot be represented as wire keys.

	Known limitation: integer key 1 (number) and string key "1" both become
	"1" on the wire and will collide. This is a wire-format constraint and is
	documented. If you need to distinguish them, use a prefix convention in
	your own data layer.
]]--
local function tableKeyToString(k: any): (string?, string?)
	local kt = type(k)
	if kt == "string" then
		return k :: string, nil
	end
	if kt == "number" then
		---// NaN keys are allowed by Lua but produce a non-roundtrippable string.
		--// Reject them explicitly.
		if k ~= k then return nil, `table key is NaN — not encodable` end
		return tostring(k :: number), nil
	end
	return nil, `table key of type "{kt}" is not supported — only string and number keys are encodable`
end


local encodeInto: (BB: buffer, value: any, offset: number, depth: number) -> (number?, string?)
local decodeFrom: (b: buffer, offset: number) -> (any, number)

local function writeNumber(BB: buffer, tag: number, n: number, offset: number): number
	buf_writeu8(BB, offset, tag); offset += 1
	if tag == T_U8  then buf_writeu8 (BB, offset, n); return offset + 1 end
	if tag == T_U16 then buf_writeu16(BB, offset, n); return offset + 2 end
	if tag == T_U32 then buf_writeu32(BB, offset, n); return offset + 4 end
	if tag == T_I8  then buf_writei8 (BB, offset, n); return offset + 1 end
	if tag == T_I16 then buf_writei16(BB, offset, n); return offset + 2 end
	if tag == T_I32 then buf_writei32(BB, offset, n); return offset + 4 end
	if tag == T_F32 then buf_writef32(BB, offset, n); return offset + 4 end
	buf_writef64(BB, offset, n); return offset + 8
end

local function encodeRLE(BB: buffer, arr: { any }, count: number, offset: number, depth: number): (number?, string?)
	buf_writeu8(BB, offset, T_ARRAY_RLE); buf_writeu16(BB, offset + 1, count)
	offset += 3; local i = 1
	while i <= count do
		local run = 1
		while (i + run) <= count and arr[i + run] == arr[i] do run += 1 end
		buf_writeu16(BB, offset, run); offset += 2
		local next, err = encodeInto(BB, arr[i], offset, depth + 1)
		if not next then return nil, err end
		offset = next :: number
		i += run
	end
	return offset, nil
end

--[[
	Large dicts are encoded in CHUNK_FIELD_MAX-field batches to avoid
	overflowing the 1 MB scratch buffer.
]]--
local function encodeLargeTable(value: { [any]: any }, depth: number): (buffer?, string?)
	local keys: { any } = {}; local fieldCount = 0
	for k in pairs(value) do fieldCount += 1; keys[fieldCount] = k end
	if fieldCount > 65535 then return nil, `table too large ({fieldCount} fields)` end

	local header = buf_create(3)
	buf_writeu8(header, 0, T_TABLE)
	buf_writeu16(header, 1, fieldCount)
	local parts: { buffer } = { header }

	local i = 1
	while i <= fieldCount do
		local chunkEnd = math.min(i + CHUNK_FIELD_MAX - 1, fieldCount)
		local scratch = acquireScratch(); local offset = 0
		local encErr: string? = nil

		for j = i, chunkEnd do
			local k = keys[j]
			local key, keyErr = tableKeyToString(k)
			if not key then encErr = keyErr; break end
			local kl = #(key :: string)
			if kl > 255 then encErr = `key too long: "{key}"`; break end
			buf_writeu8(scratch, offset, kl); buf_writestring(scratch, offset + 1, key :: string)
			offset += 1 + kl
			local next, err = encodeInto(scratch, value[k], offset, depth + 1)
			if not next then encErr = err; break end
			offset = next :: number
		end

		if encErr then releaseScratch(scratch); return nil, encErr end
		local chunk = buf_create(offset); buf_copy(chunk, 0, scratch, 0, offset)
		releaseScratch(scratch); parts[#parts + 1] = chunk
		i = chunkEnd + 1
	end

	return joinBuffers(parts), nil
end

encodeInto = function(BB: buffer, value: any, offset: number, depth: number): (number?, string?)
	if depth > MAX_DEPTH then
		return nil, "max recursion depth — consider flattening deeply nested tables"
	end

	if value == nil then buf_writeu8(BB, offset, T_NIL); return offset + 1, nil end
	if value == true then buf_writeu8(BB, offset, T_BOOL); buf_writeu8(BB, offset+1, 1); return offset+2, nil end
	if value == false then buf_writeu8(BB, offset, T_BOOL); buf_writeu8(BB, offset+1, 0); return offset+2, nil end
	if value == 0 then buf_writeu8(BB, offset, T_U8);   buf_writeu8(BB, offset+1, 0); return offset+2, nil end

	local vt = typeof(value)
	if vt == "number" then return writeNumber(BB, numTag(value), value, offset), nil end

	if vt == "string" then
		local len = #value
		if len <= 255 then
			buf_writeu8(BB, offset, T_STR8); buf_writeu8(BB, offset+1, len)
			buf_writestring(BB, offset+2, value); return offset+2+len, nil
		elseif len <= 65535 then
			buf_writeu8(BB, offset, T_STR16); buf_writeu16(BB, offset+1, len)
			buf_writestring(BB, offset+3, value); return offset+3+len, nil
		end
		return nil, `string too long ({len} bytes, max 65535)`
	end

	if vt == "Instance" then
		local id = _instanceToId[value :: Instance]
		if not id then
			return nil, `Instance "{(value :: Instance):GetFullName()}" not registered — call Buffer.RegisterInstance first`
		end
		buf_writeu8(BB, offset, T_INSTANCE); buf_writeu32(BB, offset+1, id)
		return offset+5, nil
	end

	if vt == "Vector3" then
		buf_writeu8(BB, offset, T_VEC3)
		buf_writef32(BB, offset+1, value.X); buf_writef32(BB, offset+5, value.Y); buf_writef32(BB, offset+9, value.Z)
		return offset+13, nil
	end
	if vt == "Vector2" then
		buf_writeu8(BB, offset, T_VEC2)
		buf_writef32(BB, offset+1, value.X); buf_writef32(BB, offset+5, value.Y)
		return offset+9, nil
	end
	if vt == "Vector3int16" then
		buf_writeu8(BB, offset, T_VEC3INT16)
		buf_writei16(BB, offset+1, value.X); buf_writei16(BB, offset+3, value.Y); buf_writei16(BB, offset+5, value.Z)
		return offset+7, nil
	end
	if vt == "Vector2int16" then
		buf_writeu8(BB, offset, T_VEC2INT16)
		buf_writei16(BB, offset+1, value.X); buf_writei16(BB, offset+3, value.Y)
		return offset+5, nil
	end

	if vt == "CFrame" then
		--[[
			Prefer axis-angle (7 floats, 29 bytes) when it round-trips within 1 mm.
			Fall back to the full 12-component form for shear / non-standard CFrames.
		]]--
		local axis, angle = value:ToAxisAngle()
		local restored = CFrame.fromAxisAngle(axis, angle) + value.Position
		--// Check both position and rotation matrix elements for accuracy
		local r00, r01, r02, r10, r11, r12, r20, r21, r22 = value:GetComponents()
		local n00, n01, n02, n10, n11, n12, n20, n21, n22 = restored:GetComponents()
		local posOk = mabs(value.X - restored.X) < 0.001 and mabs(value.Y - restored.Y) < 0.001 and mabs(value.Z - restored.Z) < 0.001
		local rotOk = mabs(r00-n00) < 0.0001 and mabs(r01-n01) < 0.0001 and mabs(r02-n02) < 0.0001
			and mabs(r10-n10) < 0.0001 and mabs(r11-n11) < 0.0001 and mabs(r12-n12) < 0.0001
			and mabs(r20-n20) < 0.0001 and mabs(r21-n21) < 0.0001 and mabs(r22-n22) < 0.0001

		if posOk and rotOk then
			buf_writeu8(BB, offset, T_CF_LOSSY)
			buf_writef32(BB, offset+1,  value.X); buf_writef32(BB, offset+5,  value.Y); buf_writef32(BB, offset+9,  value.Z)
			buf_writef32(BB, offset+13, axis.X);  buf_writef32(BB, offset+17, axis.Y);  buf_writef32(BB, offset+21, axis.Z)
			buf_writef32(BB, offset+25, angle); return offset+29, nil
		else
			buf_writeu8(BB, offset, T_CF_FULL)
			local c0,c1,c2,c3,c4,c5,c6,c7,c8,c9,c10,c11 = value:GetComponents()
			buf_writef32(BB, offset+1, c0); buf_writef32(BB, offset+5, c1)
			buf_writef32(BB, offset+9, c2); buf_writef32(BB, offset+13, c3)
			buf_writef32(BB, offset+17, c4); buf_writef32(BB, offset+21, c5)
			buf_writef32(BB, offset+25, c6); buf_writef32(BB, offset+29, c7)
			buf_writef32(BB, offset+33, c8); buf_writef32(BB, offset+37, c9)
			buf_writef32(BB, offset+41, c10); buf_writef32(BB, offset+45, c11)
			return offset+49, nil
		end
	end

	if vt == "Color3" then
		buf_writeu8(BB, offset, T_COLOR3)
		buf_writeu8(BB, offset+1, mround(value.R*255))
		buf_writeu8(BB, offset+2, mround(value.G*255))
		buf_writeu8(BB, offset+3, mround(value.B*255))
		return offset+4, nil
	end
	if vt == "UDim2" then
		buf_writeu8(BB, offset, T_UDIM2)
		buf_writef32(BB, offset+1, value.X.Scale); buf_writei32(BB, offset+5, value.X.Offset)
		buf_writef32(BB, offset+9, value.Y.Scale); buf_writei32(BB, offset+13, value.Y.Offset)
		return offset+17, nil
	end
	if vt == "UDim" then
		buf_writeu8(BB, offset, T_UDIM)
		buf_writef32(BB, offset+1, value.Scale); buf_writei32(BB, offset+5, value.Offset)
		return offset+9, nil
	end
	if vt == "Ray" then
		buf_writeu8(BB, offset, T_RAY)
		buf_writef32(BB, offset+1,  value.Origin.X);    buf_writef32(BB, offset+5,  value.Origin.Y);    buf_writef32(BB, offset+9,  value.Origin.Z)
		buf_writef32(BB, offset+13, value.Direction.X); buf_writef32(BB, offset+17, value.Direction.Y); buf_writef32(BB, offset+21, value.Direction.Z)
		return offset+25, nil
	end
	if vt == "NumberRange" then
		buf_writeu8(BB, offset, T_NRANGE)
		if value.Min == value.Max then
			buf_writeu8(BB, offset+1, 0); buf_writef32(BB, offset+2, value.Min); return offset+6, nil
		end
		buf_writeu8(BB, offset+1, 1); buf_writef32(BB, offset+2, value.Min); buf_writef32(BB, offset+6, value.Max)
		return offset+10, nil
	end
	if vt == "BrickColor" then
		buf_writeu8(BB, offset, T_BRICKCLR); buf_writeu16(BB, offset+1, value.Number); return offset+3, nil
	end
	if vt == "Rect" then
		buf_writeu8(BB, offset, T_RECT)
		buf_writef32(BB, offset+1, value.Min.X); buf_writef32(BB, offset+5,  value.Min.Y)
		buf_writef32(BB, offset+9, value.Max.X); buf_writef32(BB, offset+13, value.Max.Y)
		return offset+17, nil
	end
	if vt == "EnumItem" then
		local name = tostring(value.EnumType); local nl = #name
		if nl > 255 then return nil, `EnumType name too long ({nl})` end
		buf_writeu8(BB, offset, T_ENUM); buf_writeu8(BB, offset+1, nl)
		buf_writestring(BB, offset+2, name); buf_writeu16(BB, offset+2+nl, value.Value)
		return offset+4+nl, nil
	end
	if vt == "ColorSequence" then
		local kps = value.Keypoints; local kc = #kps
		if kc > 255 then return nil, `ColorSequence: too many keypoints ({kc})` end
		buf_writeu8(BB, offset, T_COLORSEQ); buf_writeu8(BB, offset+1, kc); offset += 2
		for i = 1, kc do
			local kp = kps[i]; local c = kp.Value
			buf_writef32(BB, offset, kp.Time)
			buf_writeu8(BB, offset+4, mround(c.R*255)); buf_writeu8(BB, offset+5, mround(c.G*255)); buf_writeu8(BB, offset+6, mround(c.B*255))
			offset += 7
		end
		return offset, nil
	end
	if vt == "ColorSequenceKeypoint" then
		local c = value.Value
		buf_writeu8(BB, offset, T_COLORSEQKP); buf_writef32(BB, offset+1, value.Time)
		buf_writeu8(BB, offset+5, mround(c.R*255)); buf_writeu8(BB, offset+6, mround(c.G*255)); buf_writeu8(BB, offset+7, mround(c.B*255))
		return offset+8, nil
	end
	if vt == "NumberSequence" then
		local kps = value.Keypoints; local kc = #kps
		if kc > 255 then return nil, `NumberSequence: too many keypoints ({kc})` end
		buf_writeu8(BB, offset, T_NUMSEQ); buf_writeu8(BB, offset+1, kc); offset += 2
		for i = 1, kc do
			local kp = kps[i]
			buf_writef32(BB, offset, kp.Time); buf_writef32(BB, offset+4, kp.Value); buf_writef32(BB, offset+8, kp.Envelope)
			offset += 12
		end
		return offset, nil
	end
	if vt == "NumberSequenceKeypoint" then
		buf_writeu8(BB, offset, T_NUMBERSEQKP)
		buf_writef32(BB, offset+1, value.Time); buf_writef32(BB, offset+5, value.Value); buf_writef32(BB, offset+9, value.Envelope)
		return offset+13, nil
	end
	if vt == "Font" then
		local family = value.Family; local fl = #family
		if fl > 255 then return nil, `Font.Family too long ({fl})` end
		buf_writeu8(BB, offset, T_FONT); buf_writeu8(BB, offset+1, fl); buf_writestring(BB, offset+2, family)
		offset += 2+fl; buf_writeu16(BB, offset, value.Weight.Value); buf_writeu8(BB, offset+2, value.Style.Value)
		return offset+3, nil
	end
	if vt == "Content" then
		local uri = tostring(value); local ul = #uri
		buf_writeu8(BB, offset, T_CONTENT)
		if ul <= 254 then
			buf_writeu8(BB, offset+1, ul); buf_writestring(BB, offset+2, uri); return offset+2+ul, nil
		elseif ul <= 65535 then
			buf_writeu8(BB, offset+1, 0xFF); buf_writeu16(BB, offset+2, ul); buf_writestring(BB, offset+4, uri); return offset+4+ul, nil
		end
		return nil, `Content URI too long ({ul} bytes)`
	end
	if vt == "DateTime" then
		buf_writeu8(BB, offset, T_DATETIME); buf_writef64(BB, offset+1, value.UnixTimestampMillis); return offset+9, nil
	end
	if vt == "Region3" then
		local cf = value.CFrame; local hs = value.Size * 0.5
		buf_writeu8(BB, offset, T_REGION3)
		buf_writef32(BB, offset+1, cf.X); buf_writef32(BB, offset+5, cf.Y); buf_writef32(BB, offset+9, cf.Z)
		buf_writef32(BB, offset+13, hs.X); buf_writef32(BB, offset+17, hs.Y); buf_writef32(BB, offset+21, hs.Z)
		return offset+25, nil
	end
	if vt == "Region3int16" then
		local mn = value.Min; local mx = value.Max
		buf_writeu8(BB, offset, T_REGION3INT16)
		buf_writei16(BB, offset+1, mn.X); buf_writei16(BB, offset+3, mn.Y); buf_writei16(BB, offset+5, mn.Z)
		buf_writei16(BB, offset+7, mx.X); buf_writei16(BB, offset+9, mx.Y); buf_writei16(BB, offset+11, mx.Z)
		return offset+13, nil
	end
	if vt == "PhysicalProperties" then
		--// Compare by components since PhysicalProperties doesn't have == operator
		local defaultProps = PhysicalProperties.new(Enum.Material.Plastic)
		if value.Density == defaultProps.Density 
			and value.Friction == defaultProps.Friction 
			and value.Elasticity == defaultProps.Elasticity
			and value.FrictionWeight == defaultProps.FrictionWeight
			and value.ElasticityWeight == defaultProps.ElasticityWeight then
			buf_writeu8(BB, offset, T_PHYSPROP_DEFAULT); return offset+1, nil
		end
		buf_writeu8(BB, offset, T_PHYSPROP)
		buf_writef32(BB, offset+1, value.Density); buf_writef32(BB, offset+5, value.Friction)
		buf_writef32(BB, offset+9, value.Elasticity); buf_writef32(BB, offset+13, value.FrictionWeight); buf_writef32(BB, offset+17, value.ElasticityWeight)
		return offset+21, nil
	end
	if vt == "Axes" then
		local bits = 0
		if value.X then bits = bor(bits,1) end; if value.Y then bits = bor(bits,2) end; if value.Z then bits = bor(bits,4) end
		buf_writeu8(BB, offset, T_AXES); buf_writeu8(BB, offset+1, bits); return offset+2, nil
	end
	if vt == "Faces" then
		local bits = 0
		if value.Top    then bits = bor(bits,1)  end; if value.Bottom then bits = bor(bits,2)  end
		if value.Left   then bits = bor(bits,4)  end; if value.Right  then bits = bor(bits,8)  end
		if value.Front  then bits = bor(bits,16) end; if value.Back   then bits = bor(bits,32) end
		buf_writeu8(BB, offset, T_FACES); buf_writeu8(BB, offset+1, bits); return offset+2, nil
	end
	if vt == "TweenInfo" then
		buf_writeu8(BB, offset, T_TWEENINFO); buf_writef32(BB, offset+1, value.Time)
		buf_writeu8(BB, offset+5, value.EasingStyle.Value); buf_writeu8(BB, offset+6, value.EasingDirection.Value)
		buf_writei32(BB, offset+7, value.RepeatCount); buf_writeu8(BB, offset+11, if value.Reverses then 1 else 0)
		buf_writef32(BB, offset+12, value.DelayTime); return offset+16, nil
	end

	local custom = CustomByType[vt]
	if custom then
		buf_writeu8(BB, offset, T_CUSTOM); buf_writeu8(BB, offset+1, custom.id)
		local next, err = custom.ct.encode(BB, value, offset+2)
		if not next then return nil, err end
		return next, nil
	end

	if vt == "table" then
		local isArr, count = checkArray(value)
		if isArr then
			if count > 65535 then return nil, `array too large ({count})` end
			if shouldRLE(value, count) then return encodeRLE(BB, value, count, offset, depth) end
			buf_writeu8(BB, offset, T_ARRAY); buf_writeu16(BB, offset+1, count); offset += 3
			for i = 1, count do
				local next, err = encodeInto(BB, value[i], offset, depth+1)
				if not next then return nil, err end
				offset = next :: number
			end
			return offset, nil
		else
			local fc = 0; for _ in pairs(value) do fc += 1 end
			if fc > 65535 then return nil, `table too large ({fc} fields)` end
			buf_writeu8(BB, offset, T_TABLE); buf_writeu16(BB, offset+1, fc); offset += 3
			for k, v in pairs(value) do
				local key, keyErr = tableKeyToString(k)
				if not key then return nil, keyErr end
				local kl = #(key :: string)
				if kl > 255 then return nil, `key too long: "{key}"` end
				buf_writeu8(BB, offset, kl); buf_writestring(BB, offset+1, key :: string); offset += 1+kl
				local next, err = encodeInto(BB, v, offset, depth+1)
				if not next then return nil, err end
				offset = next :: number
			end
			return offset, nil
		end
	end

	return nil, `unsupported type: {vt}`
end

decodeFrom = function(b: buffer, offset: number): (any, number)
	checkBounds(b, offset, 1, "tag")
	local tag = buf_readu8(b, offset); offset += 1

	if tag == T_NIL then return nil, offset end
	if tag == T_BOOL then checkBounds(b,offset,1,"bool"); return buf_readu8(b,offset)==1, offset+1 end
	if tag == T_U8 then checkBounds(b,offset,1,"u8"); return buf_readu8(b,offset), offset+1 end
	if tag == T_U16 then checkBounds(b,offset,2,"u16"); return buf_readu16(b,offset), offset+2 end
	if tag == T_U32 then checkBounds(b,offset,4,"u32"); return buf_readu32(b,offset), offset+4 end
	if tag == T_I8 then checkBounds(b,offset,1,"i8"); return buf_readi8(b,offset), offset+1 end
	if tag == T_I16 then checkBounds(b,offset,2,"i16"); return buf_readi16(b,offset), offset+2 end
	if tag == T_I32 then checkBounds(b,offset,4,"i32"); return buf_readi32(b,offset), offset+4 end
	if tag == T_F32 then checkBounds(b,offset,4,"f32"); return buf_readf32(b,offset), offset+4 end
	if tag == T_F64 then checkBounds(b,offset,8,"f64"); return buf_readf64(b,offset), offset+8 end

	if tag == T_STR8 then
		checkBounds(b,offset,1,"str8 len"); local len = buf_readu8(b,offset)
		return safeReadString(b,offset+1,len,"str8"), offset+1+len
	end
	if tag == T_STR16 then
		checkBounds(b,offset,2,"str16 len"); local len = buf_readu16(b,offset)
		return safeReadString(b,offset+2,len,"str16"), offset+2+len
	end

	if tag == T_INSTANCE then
		checkBounds(b,offset,4,"instance id"); local id = buf_readu32(b,offset)
		local inst = _idToInstance[id]
		if not inst then error(`[Buffer] no Instance registered for id {id}`) end
		return inst, offset+4
	end

	if tag == T_VEC3 then checkBounds(b,offset,12,"vec3"); return Vector3.new(buf_readf32(b,offset), buf_readf32(b,offset+4), buf_readf32(b,offset+8)), offset+12 end
	if tag == T_VEC2 then checkBounds(b,offset,8,"vec2"); return Vector2.new(buf_readf32(b,offset), buf_readf32(b,offset+4)), offset+8 end
	if tag == T_VEC3INT16 then checkBounds(b,offset,6,"vec3i16"); return Vector3int16.new(buf_readi16(b,offset), buf_readi16(b,offset+2), buf_readi16(b,offset+4)), offset+6 end
	if tag == T_VEC2INT16 then checkBounds(b,offset,4,"vec2i16"); return Vector2int16.new(buf_readi16(b,offset), buf_readi16(b,offset+2)), offset+4 end

	if tag == T_CF_LOSSY then
		checkBounds(b,offset,28,"cframe_l")
		local cf = CFrame.fromAxisAngle(
			Vector3.new(buf_readf32(b,offset+12), buf_readf32(b,offset+16), buf_readf32(b,offset+20)),
			buf_readf32(b,offset+24)
		) + Vector3.new(buf_readf32(b,offset), buf_readf32(b,offset+4), buf_readf32(b,offset+8))
		return cf, offset+28
	end
	if tag == T_CF_FULL then
		checkBounds(b,offset,48,"cframe_f")
		return CFrame.new(
			buf_readf32(b,offset), buf_readf32(b,offset+4), buf_readf32(b,offset+8), buf_readf32(b,offset+12),
			buf_readf32(b,offset+16), buf_readf32(b,offset+20), buf_readf32(b,offset+24), buf_readf32(b,offset+28),
			buf_readf32(b,offset+32), buf_readf32(b,offset+36), buf_readf32(b,offset+40), buf_readf32(b,offset+44)
		), offset+48
	end

	if tag == T_COLOR3 then checkBounds(b,offset,3,"color3");  return Color3.fromRGB(buf_readu8(b,offset), buf_readu8(b,offset+1), buf_readu8(b,offset+2)), offset+3 end
	if tag == T_UDIM2 then checkBounds(b,offset,16,"udim2");  return UDim2.new(buf_readf32(b,offset), buf_readi32(b,offset+4), buf_readf32(b,offset+8), buf_readi32(b,offset+12)), offset+16 end
	if tag == T_UDIM then checkBounds(b,offset,8,"udim");    return UDim.new(buf_readf32(b,offset), buf_readi32(b,offset+4)), offset+8 end
	if tag == T_RAY then
		checkBounds(b,offset,24,"ray")
		return Ray.new(
			Vector3.new(buf_readf32(b,offset),    buf_readf32(b,offset+4),  buf_readf32(b,offset+8)),
			Vector3.new(buf_readf32(b,offset+12), buf_readf32(b,offset+16), buf_readf32(b,offset+20))
		), offset+24
	end
	if tag == T_NRANGE then
		checkBounds(b,offset,1,"nrange flag"); local flag = buf_readu8(b,offset)
		if flag == 0 then checkBounds(b,offset+1,4,"nrange1"); return NumberRange.new(buf_readf32(b,offset+1)), offset+5 end
		checkBounds(b,offset+1,8,"nrange2"); return NumberRange.new(buf_readf32(b,offset+1), buf_readf32(b,offset+5)), offset+9
	end
	if tag == T_BRICKCLR then checkBounds(b,offset,2,"brickclr"); return BrickColor.new(buf_readu16(b,offset)), offset+2 end
	if tag == T_RECT then checkBounds(b,offset,16,"rect"); return Rect.new(buf_readf32(b,offset), buf_readf32(b,offset+4), buf_readf32(b,offset+8), buf_readf32(b,offset+12)), offset+16 end

	if tag == T_ENUM then
		checkBounds(b,offset,1,"enum nl"); local nl = buf_readu8(b,offset)
		local ename = safeReadString(b,offset+1,nl,"enum name")
		checkBounds(b,offset+1+nl,2,"enum val"); local ev = buf_readu16(b,offset+1+nl)
		local et = (Enum :: any)[ename]
		if not et or not tEnumType(et) then error(`[Buffer] unknown enum type: "{ename}"`) end
		local item = et:FromValue(ev)
		if not item then error(`[Buffer] unknown enum value {ev} for {ename}`) end
		return item, offset+3+nl
	end

	if tag == T_COLORSEQ then
		checkBounds(b,offset,1,"cseq count"); local kc = buf_readu8(b,offset); offset += 1
		checkBounds(b,offset,kc*7,"cseq kps")
		local kps = tcreate(kc) :: { ColorSequenceKeypoint }
		for i = 1, kc do
			kps[i] = ColorSequenceKeypoint.new(
				buf_readf32(b,offset),
				Color3.new(buf_readu8(b,offset+4)/255, buf_readu8(b,offset+5)/255, buf_readu8(b,offset+6)/255)
			)
			offset += 7
		end
		return ColorSequence.new(kps :: any), offset
	end
	if tag == T_COLORSEQKP then
		checkBounds(b,offset,7,"cseqkp")
		return ColorSequenceKeypoint.new(
			buf_readf32(b,offset),
			Color3.new(buf_readu8(b,offset+4)/255, buf_readu8(b,offset+5)/255, buf_readu8(b,offset+6)/255)
		), offset+7
	end
	if tag == T_NUMSEQ then
		checkBounds(b,offset,1,"nseq count"); local kc = buf_readu8(b,offset); offset += 1
		checkBounds(b,offset,kc*12,"nseq kps")
		local kps = tcreate(kc) :: { NumberSequenceKeypoint }
		for i = 1, kc do
			local time = buf_readf32(b,offset)
			local tv = buf_readf32(b,offset+4)
			local env = buf_readf32(b,offset+8)
			kps[i] = NumberSequenceKeypoint.new(time, tv, math.max(0, env))
			offset += 12
		end
		return NumberSequence.new(kps :: any), offset
	end
	if tag == T_NUMBERSEQKP then
		checkBounds(b,offset,12,"nseqkp")
		local time = buf_readf32(b,offset)
		local tv = buf_readf32(b,offset+4)
		local env = buf_readf32(b,offset+8)
		return NumberSequenceKeypoint.new(time, tv, math.max(0, env)), offset+12
	end
	if tag == T_FONT then
		checkBounds(b,offset,1,"font nl"); local fl = buf_readu8(b,offset)
		local family = safeReadString(b,offset+1,fl,"font family"); offset += 1+fl
		checkBounds(b,offset,3,"font w+s")
		local w = Enum.FontWeight:FromValue(buf_readu16(b,offset)) or Enum.FontWeight.Regular
		local s = Enum.FontStyle:FromValue(buf_readu8(b,offset+2))  or Enum.FontStyle.Normal
		return Font.new(family, w, s), offset+3
	end
	if tag == T_CONTENT then
		checkBounds(b,offset,1,"content first"); local first = buf_readu8(b,offset)
		if first == 0xFF then
			checkBounds(b,offset+1,2,"content u16"); local len = buf_readu16(b,offset+1)
			return Content.fromUri(safeReadString(b,offset+3,len,"content uri")), offset+3+len
		end
		return Content.fromUri(safeReadString(b,offset+1,first,"content uri")), offset+1+first
	end
	if tag == T_DATETIME   then checkBounds(b,offset,8,"datetime"); return DateTime.fromUnixTimestampMillis(buf_readf64(b,offset)), offset+8 end
	if tag == T_REGION3    then
		checkBounds(b,offset,24,"region3")
		local half = Vector3.new(buf_readf32(b,offset+12), buf_readf32(b,offset+16), buf_readf32(b,offset+20))
		local ctr  = Vector3.new(buf_readf32(b,offset),    buf_readf32(b,offset+4),  buf_readf32(b,offset+8))
		return Region3.new(ctr - half, ctr + half), offset+24
	end
	if tag == T_REGION3INT16 then
		checkBounds(b,offset,12,"region3i16")
		return Region3int16.new(
			Vector3int16.new(buf_readi16(b,offset),   buf_readi16(b,offset+2),  buf_readi16(b,offset+4)),
			Vector3int16.new(buf_readi16(b,offset+6), buf_readi16(b,offset+8),  buf_readi16(b,offset+10))
		), offset+12
	end
	if tag == T_PHYSPROP then
		checkBounds(b,offset,20,"physprop")
		return PhysicalProperties.new(
			buf_readf32(b,offset), buf_readf32(b,offset+4), buf_readf32(b,offset+8),
			buf_readf32(b,offset+12), buf_readf32(b,offset+16)
		), offset+20
	end
	if tag == T_PHYSPROP_DEFAULT then return PhysicalProperties.new(Enum.Material.Plastic), offset end
	if tag == T_AXES then
		checkBounds(b,offset,1,"axes"); local bits = buf_readu8(b,offset); local ax = {}
		if band(bits,1)~=0 then ax[#ax+1]=Enum.Axis.X end
		if band(bits,2)~=0 then ax[#ax+1]=Enum.Axis.Y end
		if band(bits,4)~=0 then ax[#ax+1]=Enum.Axis.Z end
		return Axes.new(tunpack(ax)), offset+1
	end
	if tag == T_FACES then
		checkBounds(b,offset,1,"faces"); local bits = buf_readu8(b,offset); local fc = {}
		if band(bits,1) ~=0 then fc[#fc+1]=Enum.NormalId.Top end; if band(bits,2) ~=0 then fc[#fc+1]=Enum.NormalId.Bottom end
		if band(bits,4) ~=0 then fc[#fc+1]=Enum.NormalId.Left end; if band(bits,8) ~=0 then fc[#fc+1]=Enum.NormalId.Right end
		if band(bits,16)~=0 then fc[#fc+1]=Enum.NormalId.Front  end; if band(bits,32)~=0 then fc[#fc+1]=Enum.NormalId.Back end
		return Faces.new(tunpack(fc)), offset+1
	end
	if tag == T_TWEENINFO then
		checkBounds(b,offset,15,"tween")
		local es = Enum.EasingStyle:FromValue(buf_readu8(b,offset+4)) or Enum.EasingStyle.Linear
		local ed = Enum.EasingDirection:FromValue(buf_readu8(b,offset+5)) or Enum.EasingDirection.Out
		return TweenInfo.new(
			buf_readf32(b,offset), es, ed,
			buf_readi32(b,offset+6),
			buf_readu8(b,offset+10) == 1,
			buf_readf32(b,offset+11)
		), offset+15
	end

	if tag == T_CUSTOM then
		checkBounds(b,offset,1,"custom id"); local id = buf_readu8(b,offset)
		local ct = CustomRegistry[id]
		if not ct then error(`[Buffer] unknown custom type id: {id}`) end
		return ct.decode(b, offset+1)
	end

	--[[
		Compressed wrappers: decompress, then decode the inner payload.
		Compress.decompress verifies the Adler-32 checksum before returning.
	]]--
	if tag == T_LZ4 or tag == T_DEFLATE or tag == T_ZSTD then
		checkBounds(b, offset, Compress.HEADER_SIZE - 1, "compress hdr")
		local inner, _ = Compress.decompress(tag, b, offset)
		return decodeFrom(inner, 0)
	end

	if tag == T_ARRAY then
		checkBounds(b,offset,2,"arr count"); local count = buf_readu16(b,offset); offset += 2
		local arr = tcreate(count)
		for i = 1, count do arr[i], offset = decodeFrom(b, offset) end
		return arr, offset
	end
	if tag == T_ARRAY_RLE then
		checkBounds(b,offset,2,"rle count"); local logical = buf_readu16(b,offset); offset += 2
		local arr = tcreate(logical); local idx = 1
		while idx <= logical do
			checkBounds(b,offset,2,"rle run"); local run = buf_readu16(b,offset); offset += 2
			if run == 0 then error("[Buffer] corrupt RLE: run length is 0") end
			local v; v, offset = decodeFrom(b, offset)
			for j = 0, run-1 do arr[idx+j] = v end; idx += run
		end
		return arr, offset
	end
	if tag == T_TABLE then
		checkBounds(b,offset,2,"tbl count"); local count = buf_readu16(b,offset); offset += 2
		local tbl: { [string]: any } = {}
		for _ = 1, count do
			checkBounds(b,offset,1,"tbl key len"); local kl = buf_readu8(b,offset)
			local key = safeReadString(b, offset+1, kl, "tbl key"); offset += 1+kl
			tbl[key], offset = decodeFrom(b, offset)
		end
		return tbl, offset
	end
	if tag == T_DELTA then
		checkBounds(b,offset,2,"delta count"); local count = buf_readu16(b,offset); offset += 2
		local patch: { [string]: any } = {}
		for _ = 1, count do
			checkBounds(b,offset,1,"delta key len"); local kl = buf_readu8(b,offset)
			local key = safeReadString(b, offset+1, kl, "delta key"); offset += 1+kl
			patch[key], offset = decodeFrom(b, offset)
		end
		return patch, offset
	end

	error(`[Buffer] unknown tag {tag} at byte {offset - 1}`)
end

--[[
	finalize.

	For large dicts (> CHUNK_FIELD_MAX fields) delegates to encodeLargeTable.
	nil is not a supported value — callers must not pass nil here.
]]--
local function finalize(value: any): (buffer?, string?)
	if value == true  then return TRUE_BUF,  nil end
	if value == false then return FALSE_BUF, nil end
	if value == 0     then return ZERO_BUF,  nil end

	if type(value) == "table" then
		local isArr, _ = checkArray(value)
		if not isArr then
			local fc = 0; for _ in pairs(value) do fc += 1 end
			if fc > CHUNK_FIELD_MAX then return encodeLargeTable(value, 0) end
		end
	end

	local scratch = acquireScratch()
	local ok, result = pcall(encodeInto, scratch, value, 0, 0)
	releaseScratch(scratch)
	if not ok then return nil, tostring(result) end
	if result == nil then return nil, "encode produced no output (unsupported value)" end
	local size = result :: number
	local out = buf_create(size); buf_copy(out, 0, scratch, 0, size)
	return out, nil
end


-- All typeof() strings Buffer can encode, plus "any" to skip the check.
local SCHEMA_VALID_TYPES: { [string]: true } = {
	["any"]                    = true, ["nil"]                    = true,
	["boolean"]                = true, ["number"]                 = true,
	["string"]                 = true, ["Vector3"]                = true,
	["Vector2"]                = true, ["Vector3int16"]           = true,
	["Vector2int16"]           = true, ["CFrame"]                 = true,
	["Color3"]                 = true, ["ColorSequence"]          = true,
	["ColorSequenceKeypoint"]  = true, ["UDim"]                   = true,
	["UDim2"]                  = true, ["Ray"]                    = true,
	["NumberRange"]            = true, ["NumberSequence"]         = true,
	["NumberSequenceKeypoint"] = true, ["BrickColor"]             = true,
	["EnumItem"]               = true, ["Rect"]                   = true,
	["Font"]                   = true, ["PhysicalProperties"]     = true,
	["DateTime"]               = true, ["Region3"]                = true,
	["Region3int16"]           = true, ["Axes"]                   = true,
	["Faces"]                  = true, ["TweenInfo"]              = true,
	["Instance"]               = true, ["table"]                  = true,
}

local _schemaCache: { [Schema]: TypeDefs.CompiledSchema } = {}
local function compileSchema(schema: Schema): (TypeDefs.CompiledSchema?, string?)
	if type(schema) ~= "table" then
		return nil, "[Schema] schema must be a table"
	end
	if type(schema.fields) ~= "table" then
		return nil, "[Schema] schema.fields must be an array of SchemaField"
	end

	local version = schema.version
	if version ~= nil then
		if type(version) ~= "number" or version ~= mfloor(version) or version < 1 or version > 255 then
			return nil, "[Schema] version must be an integer in [1, 255]"
		end
	end

	local seen: { [string]: true } = {}
	local compiled: { TypeDefs.CompiledField } = {}

	for i, field in ipairs(schema.fields) do
		if type(field) ~= "table" then
			return nil, `[Schema] field #{i} must be a table`
		end
		if type(field.name) ~= "string" or #field.name == 0 then
			return nil, `[Schema] field #{i}: name must be a non-empty string`
		end
		if seen[field.name] then
			return nil, `[Schema] duplicate field name "{field.name}"`
		end
		seen[field.name] = true

		local typeStr: string
		local checker: ((any) -> (boolean, string?))?

		if type(field.type) == "string" then
			if not SCHEMA_VALID_TYPES[field.type] then
				return nil, `[Schema] field "{field.name}": unknown type "{field.type}" — use a typeof() string or "any"`
			end
			typeStr = field.type
		elseif type(field.type) == "table" then
			local ft = field.type :: { typeStr: string, check: (any) -> (boolean, string?) }
			if type(ft.typeStr) ~= "string" then
				return nil, `[Schema] field "{field.name}": SchemaType.typeStr must be a string`
			end
			if type(ft.check) ~= "function" then
				return nil, `[Schema] field "{field.name}": SchemaType.check must be a function`
			end
			typeStr = ft.typeStr
			checker = ft.check
		else
			return nil, `[Schema] field "{field.name}": type must be a string or SchemaType object`
		end

		local isOptional = field.optional == true
		if field.default ~= nil and not isOptional then
			return nil, `[Schema] field "{field.name}": default provided but optional is not true`
		end

		compiled[i] = {
			name = field.name,
			typeStr = typeStr,
			optional = isOptional,
			default = field.default,
			check = checker,
		}
	end

	if #compiled == 0 then
		return nil, "[Schema] schema must have at least one field"
	end

	return { version = version or 1, fields = compiled }, nil
end

local function getCompiledSchema(schema: Schema): (TypeDefs.CompiledSchema?, string?)
	local cached = _schemaCache[schema]
	if cached then return cached, nil end
	local cs, err = compileSchema(schema)
	if not cs then return nil, err end
	_schemaCache[schema] = cs
	return cs, nil
end

local function encodeSchemaInto(BB: buffer, value: { [string]: any }, cs: TypeDefs.CompiledSchema, offset: number): (number?, string?)
	buf_writeu8(BB, offset, cs.version); offset += 1
	for _, field in cs.fields do
		local v = value[field.name]
		if v == nil then
			if not field.optional then
				return nil, `[EncodeSchema] required field "{field.name}" is nil`
			end
			buf_writeu8(BB, offset, T_NIL); offset += 1
		else
			if field.check then
				local ok, reason = field.check(v)
				if not ok then
					return nil, `[EncodeSchema] field "{field.name}": {reason or "type check failed"}`
				end
			elseif field.typeStr ~= "any" and typeof(v) ~= field.typeStr then
				return nil, `[EncodeSchema] field "{field.name}": expected {field.typeStr}, got {typeof(v)}`
			end

			local next, err = encodeInto(BB, v, offset, 0)
			if not next then return nil, err end
			offset = next :: number
		end
	end
	return offset, nil
end

local function decodeSchemaFrom(b: buffer, cs: TypeDefs.CompiledSchema, offset: number): ({ [string]: any }, number, string?)
	local result: { [string]: any } = {}
	if buf_len(b) <= offset then
		return result, offset, "[DecodeSchema] buffer too short for version byte"
	end
	offset += 1

	local bufEnd = buf_len(b)
	for _, field in cs.fields do
		if offset >= bufEnd then
			if field.optional then
				if field.default ~= nil then result[field.name] = field.default end
				continue
			end
			return result, offset, `[DecodeSchema] buffer too short for required field "{field.name}"`
		end

		local v, newOffset = decodeFrom(b, offset)
		offset = newOffset
		result[field.name] = if v == nil and field.default ~= nil then field.default else v
	end

	return result, offset, nil
end


local function makeType(typeStr: string, check: (any) -> (boolean, string?)): SchemaType
	return { typeStr = typeStr, check = check }
end

local Types = {}

function Types.any(): SchemaType
	return makeType("any", function(_) return true, nil end)
end

function Types.exact(typeofStr: string): SchemaType
	return makeType(typeofStr, function(v)
		if typeof(v) == typeofStr then return true, nil end
		return false, `expected {typeofStr}, got {typeof(v)}`
	end)
end

function Types.number(): SchemaType
	return makeType("number", function(v)
		if type(v) == "number" then return true, nil end
		return false, `expected number, got {typeof(v)}`
	end)
end

function Types.numberRange(min: number, max: number): SchemaType
	return makeType("number", function(v)
		if type(v) ~= "number" then return false, `expected number, got {typeof(v)}` end
		if v < min or v > max  then return false, `{v} is outside [{min}, {max}]` end
		return true, nil
	end)
end

function Types.integer(): SchemaType
	return makeType("number", function(v)
		if type(v) ~= "number" then return false, `expected number, got {typeof(v)}` end
		if v ~= mfloor(v)      then return false, `{v} is not an integer` end
		return true, nil
	end)
end

function Types.string(maxLen: number?): SchemaType
	return makeType("string", function(v)
		if type(v) ~= "string" then return false, `expected string, got {typeof(v)}` end
		if maxLen and #v > maxLen then
			return false, `string length {#v} exceeds max {maxLen}`
		end
		return true, nil
	end)
end

function Types.boolean(): SchemaType
	return makeType("boolean", function(v)
		if type(v) == "boolean" then return true, nil end
		return false, `expected boolean, got {typeof(v)}`
	end)
end

function Types.array(elementType: SchemaType, maxLen: number?): SchemaType
	return makeType("table", function(v)
		if type(v) ~= "table" then return false, `expected array table, got {typeof(v)}` end

		--// Use the same logic as checkArray to verify contiguous array
		local maxKey = 0
		local count = 0
		for k in pairs(v :: { [any]: any }) do
			count += 1
			if type(k) ~= "number" or k ~= mfloor(k) or k < 1 then
				return false, `non-integer key {tostring(k)} — not a sequence`
			end
			if (k :: number) > maxKey then maxKey = k :: number end
		end

		--// Check that keys are contiguous: max key should equal count
		if maxKey ~= count then
			return false, `array has gaps — max key {maxKey} but only {count} elements`
		end

		if maxLen and count > maxLen then
			return false, `array length {count} exceeds max {maxLen}`
		end

		for i = 1, count do
			local elem = (v :: { any })[i]
			local ok, reason = elementType.check(elem)
			if not ok then return false, `element [{i}]: {reason}` end
		end
		return true, nil
	end)
end

function Types.union(...: SchemaType): SchemaType
	local choices: { SchemaType } = { ... }
	return makeType("any", function(v)
		local reasons: { string } = {}
		for _, st in choices do
			local ok, reason = st.check(v)
			if ok then return true, nil end
			reasons[#reasons + 1] = reason or "?"
		end
		return false, `no union branch matched: {tconcat(reasons, " | ")}`
	end)
end

function Types.optional(inner: SchemaType): SchemaType
	return makeType("any", function(v)
		if v == nil then return true, nil end
		return inner.check(v)
	end)
end

function Types.literal(...: any): SchemaType
	local allowed: { any } = { ... }
	return makeType("any", function(v)
		for _, lit in allowed do
			if v == lit then return true, nil end
		end
		local strs: { string } = {}
		for _, lit in allowed do strs[#strs + 1] = tostring(lit) end
		return false, `value must be one of {tconcat(strs, ", ")}, got {tostring(v)}`
	end)
end


local function migrateSchema(data: { [string]: any }, fromVersion: number, toVersion: number, migrations: MigrationMap): ({ [string]: any }?, string?)
	if fromVersion == toVersion then return data, nil end
	if fromVersion > toVersion  then
		return nil, `[Buffer.MigrateSchema] cannot downgrade: from={fromVersion} to={toVersion}`
	end

	local current = data
	for v = fromVersion, toVersion - 1 do
		local step = migrations[v]
		if step then
			local ok, result = pcall(step, current)
			if not ok then
				return nil, `[Buffer.MigrateSchema] step {v}→{v+1} failed: {result}`
			end
			current = result :: { [string]: any }
		end
	end

	return current, nil
end


local SCHEMA_DELTA_MAX_FIELDS = 32
local function schemaDeltaDeepEqual(a: any, b: any): boolean
	if a == b then return true end
	if type(a) ~= "table" or type(b) ~= "table" then return false end
	for k, v in pairs(a :: { [any]: any }) do
		if not schemaDeltaDeepEqual(v, (b :: { [any]: any })[k]) then return false end
	end
	for k in pairs(b :: { [any]: any }) do
		if (a :: { [any]: any })[k] == nil then return false end
	end
	return true
end

local function encodeSchemaDelta(old: { [string]: any }, new: { [string]: any }, schema: Schema): (buffer?, string?)
	local cs, csErr = getCompiledSchema(schema)
	if not cs then return nil, csErr end

	local fields = cs.fields
	if #fields > SCHEMA_DELTA_MAX_FIELDS then
		return nil, `[Buffer.EncodeSchemaDelta] schema has {#fields} fields; max is {SCHEMA_DELTA_MAX_FIELDS}`
	end

	local mask = 0
	for i, field in fields do
		if not schemaDeltaDeepEqual(old[field.name], new[field.name]) then
			mask = bor(mask, lshift(1, i - 1))
		end
	end

	local scratch = acquireScratch(); local offset = 0
	buf_writeu8(scratch, offset, cs.version); offset += 1
	buf_writeu32(scratch, offset, mask); offset += 4

	if mask ~= 0 then
		for i, field in fields do
			if band(mask, lshift(1, i - 1)) ~= 0 then
				local v = new[field.name]

				if field.check then
					local ok, reason = field.check(v)
					if not ok then
						releaseScratch(scratch)
						return nil, `[Buffer.EncodeSchemaDelta] field "{field.name}": {reason or "type check failed"}`
					end
				elseif field.typeStr ~= "any" and v ~= nil and typeof(v) ~= field.typeStr then
					releaseScratch(scratch)
					return nil, `[Buffer.EncodeSchemaDelta] field "{field.name}": expected {field.typeStr}, got {typeof(v)}`
				end

				local next, err = encodeInto(scratch, v, offset, 0)
				if not next then releaseScratch(scratch); return nil, err end
				offset = next :: number
			end
		end
	end

	local out = buf_create(offset); buf_copy(out, 0, scratch, 0, offset)
	releaseScratch(scratch)
	return out, nil
end

local function decodeSchemaDelta(b: buffer, current: { [string]: any }, schema: Schema): ({ [string]: any }?, string?)
	local cs, csErr = getCompiledSchema(schema)
	if not cs then return nil, csErr end

	if #cs.fields > SCHEMA_DELTA_MAX_FIELDS then
		return nil, `[Buffer.DecodeSchemaDelta] schema has {#cs.fields} fields; max is {SCHEMA_DELTA_MAX_FIELDS}`
	end
	if buf_len(b) < 5 then
		return nil, "[Buffer.DecodeSchemaDelta] buffer too short for header (version + mask)"
	end

	local offset = 0; offset += 1
	local mask = buf_readu32(b, offset); offset += 4

	if mask == 0 then return current, nil end
	for i, field in cs.fields do
		if band(mask, lshift(1, i - 1)) ~= 0 then
			local v, newOffset = decodeFrom(b, offset)
			offset = newOffset
			current[field.name] = v
		end
	end

	return current, nil
end


local function encodeSafe(value: any): (buffer?, string?)
	if type(value) ~= "table" then
		return Buffer.Encode(value)
	end

	local seen: { [any]: true } = {}
	local function checkCycles(v: any, path: string): string?
		if type(v) ~= "table" then return nil end
		if seen[v] then return `cyclic reference at "{path}"` end
		seen[v] = true
		for k, child in pairs(v :: { [any]: any }) do
			local err = checkCycles(child, path .. "." .. tostring(k))
			if err then return err end
		end
		seen[v] = nil
		return nil
	end

	local cycleErr = checkCycles(value, "root")
	if cycleErr then
		return nil, `[Buffer.EncodeSafe] {cycleErr}`
	end

	return Buffer.Encode(value)
end


local TAG_NAMES: { [number]: string } = {
	[0]="NIL",[1]="BOOL",[2]="U8",[3]="U16",[4]="U32",[5]="I8",[6]="I16",[7]="I32",
	[8]="F32",[9]="F64",[10]="STR8",[11]="STR16",[12]="VEC3",[13]="CF_LOSSY",
	[14]="CF_FULL",[15]="COLOR3",[17]="TABLE",[18]="ARRAY",[19]="RLE",
	[20]="VEC2",[21]="UDIM2",[22]="RAY",[23]="NRANGE",[24]="BRICKCLR",
	[25]="ENUM",[26]="DELTA",[27]="UDIM",[28]="RECT",[29]="COLORSEQ",
	[30]="NUMSEQ",[31]="FONT",[32]="CONTENT",[33]="VEC3I16",[34]="VEC2I16",
	[35]="PHYSPROP",[36]="PHYSPROP_DEF",[38]="DATETIME",[39]="REGION3",
	[40]="REGION3I16",[41]="CUSTOM",[42]="AXES",[43]="FACES",[44]="TWEENINFO",
	[45]="COLORSEQKP",[46]="NUMSEQKP",[47]="LZ4",[48]="INSTANCE",[49]="DEFLATE",[50]="ZSTD",
}

local function visualizeBytes(b: buffer): string
	local lines: { string } = {}; local offset = 0; local total = buf_len(b)
	while offset < total do
		local tag  = buf_readu8(b, offset)
		local name = TAG_NAMES[tag] or ("??" .. tag)
		lines[#lines + 1] = string.format("[%04d] %02X %s", offset, tag, name)
		local ok, _, newOff = pcall(function() return decodeFrom(b, offset) end)
		if ok and newOff and newOff > offset then
			offset = newOff
		else
			offset += 1
		end
	end
	return table.concat(lines, "\n")
end

local function luaToJSON(value: any, depth: number): string
	if depth > 16 then return '"<max depth>"' end

	local vt = typeof(value)
	if value == nil then return "null" end
	if vt == "boolean" then return if value then "true" else "false" end
	if vt == "number" then
		if value ~= value then return '"NaN"' end
		if value ==  math.huge then return '"Infinity"' end
		if value == -math.huge then return '"-Infinity"' end
		return tostring(value)
	end
	if vt == "string" then
		local s = (value :: string)
			:gsub('\\', '\\\\'):gsub('"', '\\"')
			:gsub('\n', '\\n'):gsub('\r', '\\r'):gsub('\t', '\\t')
		return '"' .. s .. '"'
	end
	if vt == "table" then
		local isArr, count = checkArray(value)
		if isArr then
			local items: { string } = {}
			for i = 1, count do items[i] = luaToJSON(value[i], depth + 1) end
			return "[" .. table.concat(items, ",") .. "]"
		end
		local pairs_: { string } = {}
		for k, v in pairs(value :: { [any]: any }) do
			local key     = if type(k) == "string" then k else tostring(k)
			local safeKey = key:gsub('\\', '\\\\'):gsub('"', '\\"')
			pairs_[#pairs_ + 1] = '"' .. safeKey .. '":' .. luaToJSON(v, depth + 1)
		end
		return "{" .. table.concat(pairs_, ",") .. "}"
	end
	if vt == "Vector3" then
		local v = value :: Vector3
		return '{"__type":"Vector3","x":' .. v.X .. ',"y":' .. v.Y .. ',"z":' .. v.Z .. "}"
	end
	if vt == "Vector2" then
		local v = value :: Vector2
		return '{"__type":"Vector2","x":' .. v.X .. ',"y":' .. v.Y .. "}"
	end
	local safeVal = tostring(value):gsub('\\', '\\\\'):gsub('"', '\\"')
	return '{"__type":"' .. vt .. '","value":"' .. safeVal .. '"}'
end


local function newAsyncHandle(): (AsyncHandle, (buffer?, string?) -> ())
	local done = false
	local result: buffer? = nil
	local errMsg: string? = nil
	local waiters: { thread } = {}
	local trove = Trove.new()
	local thread = coroutine.running()

	trove:Add(function()
		if not done then
			done = true; errMsg = "operation cancelled"
			pcall(task.cancel, thread)
			for _, w in waiters do task.spawn(w) end
		end
	end)

	local handle = {} :: AsyncHandle
	function handle:Await(): (buffer?, string?)
		if done then return result, errMsg end
		table.insert(waiters, coroutine.running()); coroutine.yield()
		return result, errMsg
	end

	function handle:Cancel() trove:Clean() end

	local function complete(buf: buffer?, err: string?)
		if done then return end
		done = true; result = buf; errMsg = err
		trove:Clean()
		for _, w in waiters do task.spawn(w) end
	end

	return handle, complete
end


function Buffer.Encode(value: any): (buffer?, string?)
	debug.profilebegin("Buffer.Encode")
	if value == nil then
		debug.profileend()
		return nil, "[Buffer.Encode] nil is not supported — encode only non-nil values"
	end
	if not tEncodable(value) then
		debug.profileend()
		return nil, `[Buffer.Encode] non-encodable type: {typeof(value)}`
	end
	local usable = isCacheable(value)
	if usable then
		local hit: buffer? = Caches.warm:Get(value)
		if hit then debug.profileend(); return hit, nil end
	end
	local out, err = finalize(value)
	if out and usable then Caches.warm:Set(value, out) end
	debug.profileend()
	return out, err
end

function Buffer.EncodeWith(value: any, priority: Priority): (buffer?, string?)
	local prOk, prErr = tPriority(priority)
	if not prOk then return nil, `[Buffer.EncodeWith] bad priority: {prErr}` end
	if value == nil then return nil, "[Buffer.EncodeWith] nil is not supported" end
	if not tEncodable(value) then return nil, `[Buffer.EncodeWith] non-encodable: {typeof(value)}` end
	local usable = isCacheable(value)
	local cache = if usable then getCache(priority) else nil
	if cache then
		local hit: buffer? = cache:Get(value); if hit then return hit, nil end
	end
	local out, err = finalize(value)
	if out and cache then cache:Set(value, out) end
	return out, err
end

function Buffer.EncodeWithPolicy(value: any, policy: CachePolicy): (buffer?, string?)
	local vt = typeof(value)
	if policy == "never" or vt ~= "table" then return Buffer.Encode(value) end

	local eligible = policy == "always"
	if policy == "if-shallow" then
		eligible = true
		for _, v in pairs(value :: { [any]: any }) do
			if type(v) == "table" then eligible = false; break end
		end
	end

	if not eligible then return Buffer.Encode(value) end
	local hash    = quickHash(value :: { [any]: any })
	local cached: buffer? = _hashCache:Get(hash)
	if cached then return cached, nil end
	local out, err = finalize(value)
	if out then _hashCache:Set(hash, out) end
	return out, err
end

function Buffer.EncodeCompressed(value: any, mode: CompressionMode?, hint: string?): (buffer?, string?)
	local b, err = Buffer.Encode(value)
	if not b then return nil, err end
	local fn  = Compress.compressors[mode or "auto"]
	local out = (fn(b :: buffer, hint :: TypeDefs.DataHint))
	return out, nil
end

function Buffer.Decode(b: buffer): any
	debug.profilebegin("Buffer.Decode")
	assert(tBuf(b), "[Buffer.Decode] expected buffer")
	local value = (decodeFrom(b, 0))
	debug.profileend()
	return value
end

function Buffer.SafeDecode(b: buffer): (any, string?)
	if not tBuf(b) then return nil, `[Buffer.SafeDecode] expected buffer, got {typeof(b)}` end
	local ok, result = pcall(decodeFrom, b, 0)
	if not ok then return nil, tostring(result) end
	return result :: any, nil
end

function Buffer.ValidateSchema(schema: Schema): (boolean, string?)
	local _, err = compileSchema(schema)
	if err then return false, err end
	return true, nil
end

function Buffer.EncodeSchema(value: { [string]: any }, schema: Schema): (buffer?, string?)
	local cs, csErr = getCompiledSchema(schema)
	if not cs then return nil, csErr end

	local scratch = acquireScratch()
	local ok, result = pcall(encodeSchemaInto, scratch, value, cs :: TypeDefs.CompiledSchema, 0)
	releaseScratch(scratch)
	if not ok then return nil, tostring(result) end
	if result == nil then return nil, "schema encode failed (check field types and required fields)" end
	local size = result :: number
	local out = buf_create(size); buf_copy(out, 0, scratch, 0, size)
	return out, nil
end

function Buffer.DecodeSchema(b: buffer, schema: Schema): ({ [string]: any }?, string?)
	if not tBuf(b) then return nil, "[Buffer.DecodeSchema] expected buffer" end

	local cs, csErr = getCompiledSchema(schema)
	if not cs then return nil, csErr end

	local ok, result, _, err = pcall(decodeSchemaFrom, b, cs :: TypeDefs.CompiledSchema, 0)
	if not ok then return nil, tostring(result) end
	if err    then return nil, err end
	return result :: { [string]: any }, nil
end

function Buffer.EncodeToBase64(value: any, urlSafe: boolean?): (string?, string?)
	local b, err = Buffer.Encode(value)
	if not b then return nil, err end
	local stream = Base64.CreateEncoderStream(urlSafe)
	local ok, writeErr = stream:write(b :: buffer)
	if not ok then return nil, writeErr end
	return stream:finalize()
end

function Buffer.DecodeFromBase64(s: string): (any, string?)
	if type(s) ~= "string" then return nil, `[Buffer.DecodeFromBase64] expected string, got {typeof(s)}` end
	local raw, decErr = Base64.SafeDecode(s)
	if not raw then return nil, decErr end
	return Buffer.SafeDecode(raw :: buffer)
end

function Buffer.BufferToBase64(b: buffer, urlSafe: boolean?): string
	assert(tBuf(b), "[Buffer.BufferToBase64] expected buffer")
	return if urlSafe then Base64.EncodeURL(b) else Base64.Encode(b)
end

function Buffer.Base64ToBuffer(s: string): (buffer?, string?)
	if type(s) ~= "string" then return nil, `[Buffer.Base64ToBuffer] expected string, got {typeof(s)}` end
	return Base64.SafeDecode(s)
end

function Buffer.EncodedSize(value: any): (number?, string?)
	if value == nil then return nil, "[Buffer.EncodedSize] nil is not supported" end
	local scratch = acquireScratch()
	local ok, result = pcall(encodeInto, scratch, value, 0, 0)
	releaseScratch(scratch)
	if not ok then return nil, tostring(result) end
	if result == nil then return nil, "encode produced no output (unsupported value)" end
	return result :: number, nil
end

function Buffer.EncodeDelta(old: { [string]: any }, new: { [string]: any }): (buffer?, string?)
	local patch: { [string]: any } = {}
	for k, v in pairs(new) do if old[k] ~= v then patch[k] = v end end
	for k in pairs(old) do if new[k] == nil then patch[k] = nil end end
	local fc = 0; for _ in pairs(patch) do fc += 1 end
	if fc == 0 then
		local b = buf_create(3); buf_writeu8(b,0,T_DELTA); buf_writeu16(b,1,0); return b, nil
	end
	local scratch = acquireScratch(); local offset = 0
	buf_writeu8(scratch,0,T_DELTA); buf_writeu16(scratch,1,fc); offset += 3
	for k, v in pairs(patch) do
		local kl = #k
		if kl > 255 then releaseScratch(scratch); return nil, `delta key too long: "{k}"` end
		buf_writeu8(scratch,offset,kl); buf_writestring(scratch,offset+1,k); offset += 1+kl
		local next, err = encodeInto(scratch,v,offset,0)
		if not next then releaseScratch(scratch); return nil, err end
		offset = next :: number
	end
	local out = buf_create(offset); buf_copy(out,0,scratch,0,offset)
	releaseScratch(scratch)
	return out, nil
end

function Buffer.ApplyDelta(target: { [string]: any }, delta: buffer): { [string]: any }
	assert(tBuf(delta), "[Buffer.ApplyDelta] expected buffer")
	local patch = (decodeFrom(delta, 0))
	if type(patch) == "table" then
		for k, v in pairs(patch :: { [string]: any }) do target[k] = v end
	end
	return target
end

function Buffer.Invalidate(value: any)
	if typeof(value) ~= "table" and typeof(value) ~= "Instance" then
		Caches.hot:Set(value,nil); Caches.warm:Set(value,nil); Caches.cold:Set(value,nil)
	end
end

function Buffer.CreateStream(): Stream
	local parts: { buffer } = {}; local sealed = false
	local stream = {} :: Stream
	function stream:write(value: any): (boolean, string?)
		if sealed then return false, "stream already finalised" end
		local b, err = Buffer.Encode(value)
		if not b then return false, err end
		parts[#parts+1] = b :: buffer
		return true, nil
	end
	function stream:finalize(): (buffer?, string?)
		if sealed then return nil, "stream already finalised" end
		sealed = true
		if #parts == 0 then return buf_create(0), nil end
		return joinBuffers(parts), nil
	end
	return stream
end

function Buffer.EncodeAsync(value: any): AsyncHandle
	local handle, complete = newAsyncHandle()
	task.spawn(function()
		if type(value) ~= "table" then
			local b, err = Buffer.Encode(value); complete(b, err); return
		end
		local keys: { any } = {}; local fc = 0
		for k in pairs(value) do fc += 1; keys[fc] = k end
		local header = buf_create(3)
		buf_writeu8(header,0,T_TABLE); buf_writeu16(header,1,fc)
		local parts: { buffer } = { header }
		local i = 1
		while i <= fc do
			if i > 1 then task.wait() end
			local bEnd = math.min(i + ASYNC_FIELDS_PER_STEP - 1, fc)
			local scratch = acquireScratch(); local offset = 0
			local encErr: string? = nil
			for j = i, bEnd do
				local k   = keys[j]
				local key, keyErr = tableKeyToString(k)
				if not key then encErr = keyErr; break end
				local kl = #(key :: string)
				if kl > 255 then encErr = `key too long: "{key}"`; break end
				buf_writeu8(scratch,offset,kl); buf_writestring(scratch,offset+1,key :: string); offset += 1+kl
				local next, err = encodeInto(scratch,value[k],offset,0)
				if not next then encErr = err; break end
				offset = next :: number
			end
			if encErr then releaseScratch(scratch); complete(nil, encErr); return end
			local chunk = buf_create(offset); buf_copy(chunk,0,scratch,0,offset)
			releaseScratch(scratch); parts[#parts+1] = chunk
			i = bEnd + 1
		end
		complete(joinBuffers(parts), nil)
	end)
	return handle
end

function Buffer.DecodeAsync(b: buffer): AsyncHandle
	assert(tBuf(b), "[Buffer.DecodeAsync] expected buffer")
	local handle, complete = newAsyncHandle()
	task.spawn(function()
		task.wait()
		local ok, err = pcall(decodeFrom, b, 0)
		complete(if ok then b else nil, if ok then nil else tostring(err))
	end)
	return handle
end

function Buffer.RegisterInstance(instance: Instance, id: number)
	assert(typeof(instance) == "Instance", "[Buffer.RegisterInstance] expected Instance")
	assert(type(id) == "number" and id >= 0 and id <= 0xFFFFFFFF, "[Buffer.RegisterInstance] id must be u32")
	assert(not _instanceToId[instance], "[Buffer.RegisterInstance] Instance already registered")
	_instanceToId[instance] = id; _idToInstance[id] = instance
	local trove = Trove.new() :: { read _cleaning: false? }
	trove:Connect(instance.Destroying, function() Buffer.UnregisterInstance(instance) end)
	_instanceTroves[instance] = trove
end

function Buffer.UnregisterInstance(instance: Instance)
	local id = _instanceToId[instance]; if not id then return end
	_instanceToId[instance] = nil; _idToInstance[id] = nil
	local trove = _instanceTroves[instance]
	if trove then _instanceTroves[instance] = nil; trove:Clean() end
end

function Buffer.RegisterType(id: number, ct: CustomType)
	assert(type(id) == "number" and id >= 0 and id <= 254, "[Buffer.RegisterType] id must be 0–254")
	assert(not CustomRegistry[id], `[Buffer.RegisterType] id {id} already registered`)
	CustomRegistry[id] = ct
end

function Buffer.SetCompressionDict(dict: buffer)
	assert(tBuf(dict), "[Buffer.SetCompressionDict] expected buffer")
	Compress.SetDict(dict)
end

function Buffer.Visualize(b: buffer): string
	assert(tBuf(b), "[Buffer.Visualize] expected buffer")
	return visualizeBytes(b)
end

function Buffer.VisualizeEntropy(b: buffer): string
	assert(tBuf(b), "[Buffer.VisualizeEntropy] expected buffer")
	return Compress.VisualizeEntropy(b)
end

function Buffer.DetectDataClass(b: buffer): string
	assert(tBuf(b), "[Buffer.DetectDataClass] expected buffer")
	return Compress.DetectClass(b)
end

function Buffer.ToJSON(b: buffer): (string?, string?)
	assert(tBuf(b), "[Buffer.ToJSON] expected buffer")
	local ok, value = pcall(decodeFrom, b, 0)
	if not ok then return nil, tostring(value) end
	local jok, json = pcall(luaToJSON, value, 0)
	if not jok then return nil, tostring(json) end
	return json :: string, nil
end

function Buffer.FromJSON(json: string): (buffer?, string?)
	if type(json) ~= "string" then return nil, "[Buffer.FromJSON] expected string" end
	local ok, decoded = pcall(function()
		return game:GetService("HttpService"):JSONDecode(json)
	end)
	if not ok then return nil, `[Buffer.FromJSON] JSON parse error: {decoded}` end
	return Buffer.Encode(decoded)
end

Buffer.CustomByType = CustomByType
Buffer.Types = Types

function Buffer.EncodeSafe(value: any): (buffer?, string?)
	return encodeSafe(value)
end

function Buffer.MigrateSchema(data: { [string]: any }, fromVersion: number, toVersion: number, migrations: MigrationMap): ({ [string]: any }?, string?)
	return migrateSchema(data, fromVersion, toVersion, migrations)
end

function Buffer.EncodeSchemaDelta(old: { [string]: any }, new: { [string]: any }, schema: Schema): (buffer?, string?)
	return encodeSchemaDelta(old, new, schema)
end

function Buffer.DecodeSchemaDelta(b: buffer, current: { [string]: any }, schema: Schema): ({ [string]: any }?, string?)
	return decodeSchemaDelta(b, current, schema)
end

return Buffer
