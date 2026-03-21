--[[
    Types — central type definitions for the Buffer

    Every exported type in this file is re-exported by Buffer itself, so
    callers only need to require Buffer; they import Types when they want the
    raw type without pulling in the full serialiser (e.g. in a shared type
    module that must not have side-effects).

    Author: @maneetoo
    GitRepo: https://github.com/maneetoo/Buffer
    License: Apachi License 2.0 (see LICENSE.md)
--]]--

--!strict


-- ℹ️ | For developers: I described each type and what it is for and how it is used

local Types = {}

--------------------------------------------------------------------------------
--	 Primitive result shapes

--	 Luau cannot export bare tuple types, so functions that return (T?, string?)
--	 declare their returns inline.  These table variants exist for the rare case
--	 where a caller needs to *store* a result rather than pattern-match it
--	 immediately.
--------------------------------------------------------------------------------

--[[
	Stored encode result.  [1] = the encoded buffer, [2] = error message.
	Both are optional because exactly one of the two will be non-nil.
]]--
export type EncodeResult = { buffer? | string? }

--[[
	Stored decode result.  [1] = the decoded value, [2] = error message.
]]--
export type DecodeResult = { any | string? }

--------------------------------------------------------------------------------
-- Compression
--------------------------------------------------------------------------------

--[[
	Which algorithm Buffer.EncodeCompressed should use.

	"lz4"     — LZ4HC (pure Lua). Fast encode, decent ratio.
	            On the server the EncodingService Zstd path is used instead.
	"deflate" — Fixed-Huffman Deflate (pure Lua). Slower, better ratio,
	            especially for ASCII / text-heavy payloads.
	"none"    — Skip compression entirely. Useful when the caller knows the
	            data is already compressed or too small to benefit.
	"auto"    — Default. Reads the first tag byte to detect the data class,
	            then routes to lz4/deflate/zstd accordingly.
]]--
export type CompressionMode = "lz4" | "deflate" | "none" | "auto"

--[[
	Hint passed to the compression layer to override auto-detection.
	Buffer.EncodeCompressed accepts this as an optional third argument.

	"text"               — favour Deflate (Huffman helps ASCII runs).
	"numbers"            — favour LZ4HC (fast; numeric tags are repetitive).
	"spatial"            — favour LZ4HC (float32 CFrame/Vector3 arrays).
	"binary"             — auto between LZ4HC and Deflate.
	"already_compressed" — skip compression (saves the attempt).
	"auto"               — detect from first tag byte (default).
]]--
export type DataHint = "text" | "numbers" | "spatial" | "binary" | "already_compressed" | "auto"

--------------------------------------------------------------------------------
-- Cache
--------------------------------------------------------------------------------

--[[
	Which LRU tier Buffer.EncodeWith should use.

	"hot"  — 100-slot LRU. For values that change every frame,
	         like character positions or per-tick counters.
	"warm" — 500-slot LRU. The default for most game-state fields.
	"cold" — 2000-slot LRU. For near-static config that rarely changes.
]]--
export type Priority = "hot" | "warm" | "cold"

--[[
	How Buffer.EncodeWithPolicy should handle table values.
	Tables are never cached by default because two tables with identical
	content are different Lua objects, making the cache key unstable.

	"never"      — no caching (same behaviour as Buffer.Encode).
	"always"     — hash the table contents (djb2 variant) and cache the
	               result. Only safe when the table is truly immutable.
	"if-shallow" — cache only when the table has no nested table values.
	               A good middle ground for config-like structures.
]]--
export type CachePolicy = "never" | "always" | "if-shallow"

--------------------------------------------------------------------------------
-- Schema
--------------------------------------------------------------------------------

--[[
	A SchemaType is produced by the Buffer.Types constructors and can be
	passed as field.type instead of a plain string for richer encode-time
	validation (range checks, length limits, union branches, etc.).

	typeStr — the typeof() string Buffer uses on the wire.
	          "any" means no type constraint at the wire level.
	check   — called at encode time; must return true for valid values.
	          On failure return (false, humanReadableReason).
]]--
export type SchemaType = {
	typeStr: string,
	check:   (value: any) -> (boolean, string?),
}

--[[
	One field inside a Schema. Fields are encoded in declaration order; the
	field name is NOT written to the wire, so the decoder must use the same
	Schema with the same field order.

	field.type accepts either:
	  · a plain string  — any typeof() string Buffer supports, or "any".
	  · a SchemaType   — from Buffer.Types.xxx() for richer validation.
]]--
export type SchemaField = {
	--[[
		Key used to read from / write to the Lua table.
	]]--
	name: string,

	--[[
		Expected type. Either a typeof() string (e.g. "number", "Vector3")
		or a SchemaType object from Buffer.Types. Pass "any" to skip checks.
	]]--
	type: string | SchemaType,

	--[[
		When true, a nil value is encoded as T_NIL rather than raising an error.
	]]--
	optional: boolean?,

	--[[
		Value substituted by DecodeSchema when the field decodes as nil and
		optional is true. Ignored when optional is false.
	]]--
	default: any?,
}

--[[
	An ordered field list that describes one logical record type.
	Breaking change checklist: adding optional fields at the end is safe;
	reordering fields, changing types, or inserting in the middle are all
	breaking — bump `version` and handle migration in your decode logic.
]]--
export type Schema = {
	fields: { SchemaField },

	--[[
		Human-readable label used in error messages. Not written to the wire.
	]]--
	name: string?,

	--[[
		u8 written as the first byte of every schema-encoded buffer.
		Increment whenever the field list changes in a breaking way.
	]]--
	version: number?,
}

--[[
	A single migration step. Receives the decoded table at schema version V
	and must return the table ready for version V+1.
	Mutation in-place is fine.
]]--
export type MigrationStep = (data: { [string]: any }) -> { [string]: any }

--[[
	Internal representation produced by compileSchema.
	Stored in _schemaCache and used directly by encode/decode hot paths.
]]--
export type CompiledField = {
	name: string, --// key in the Lua table
	typeStr: string, --// typeof() string, or "any"
	optional: boolean, --// whether nil is allowed on encode
	default: any, --// substituted on decode when field is absent
	check: ((value: any) -> (boolean, string?))?, --// optional runtime validator (SchemaType)
}
export type CompiledSchema = {
	version: number,
	fields: { CompiledField },
}

--[[
	Maps each schema version V to the step function that upgrades V → V+1.
	Gap versions (no step defined for V) are treated as no-ops by
	Buffer.MigrateSchema, so you never need to fill every slot.

	Example:
	  local migrations: Buffer.MigrationMap = {
	    [1] = function(d) d.hp = d.health; d.health = nil; return d end,
	    [2] = function(d) d.level = d.level or 1; return d end,
	  }
]]--
export type MigrationMap = { [number]: MigrationStep }

--------------------------------------------------------------------------------
-- Custom type registry
--------------------------------------------------------------------------------

--[[
	Called by encodeInto to serialise a value of a registered custom type.
	`offset` is the current write position in the shared scratch buffer.
	Return the new offset on success, or (nil, errorMsg) on failure.
]]--
export type CustomEncoder = (value: any, offset: number) -> (number?, string?)

--[[
	Called by decodeFrom to deserialise a custom-type payload.
	Returns the decoded value and the new read offset.
]]--
export type CustomDecoder = (b: buffer, offset: number) -> (any, number)

--[[
	Everything Buffer needs to handle one custom type end-to-end.
]]--
export type CustomType = {
	encode: CustomEncoder,
	decode: CustomDecoder,

	--[[
		A predicate used internally to dispatch to this encoder when
		CustomByType is looked up by typeof() string.
	]]--
	check: (value: any) -> boolean,
}

--------------------------------------------------------------------------------
-- Stream
--------------------------------------------------------------------------------

--[[
	Write-only value accumulator. Each :write() encodes one value and appends
	the bytes internally; :finalize() joins everything into a single buffer.
	Useful when you want to build a multi-value packet without pre-allocating.
]]--
export type Stream = {
	write: (self: Stream, value: any) -> (boolean, string?),
	finalize: (self: Stream) -> (buffer?, string?),
}

--------------------------------------------------------------------------------
-- Async handle
--------------------------------------------------------------------------------

--[[
	Returned by Buffer.EncodeAsync and Buffer.DecodeAsync.
	The operation runs inside a task.spawn coroutine and yields between
	ASYNC_FIELDS_PER_STEP field batches so the game loop is not stalled.
]]--
export type AsyncHandle = {
	--[[
		Yields the calling coroutine until the operation completes.
		Returns (resultBuffer, nil) on success or (nil, errorMsg) on failure.
		Safe to call more than once; subsequent calls return the cached result.
	]]--
	Await: (self: AsyncHandle) -> (buffer?, string?),

	--[[
		Cancels a running operation. The worker coroutine is task.cancel'd
		via Trove. Calling :Await() after :Cancel() returns (nil, "operation cancelled").
		No-op if the operation has already completed.
	]]--
	Cancel: (self: AsyncHandle) -> (),
}

--------------------------------------------------------------------------------
-- Base64 streaming encoder
--------------------------------------------------------------------------------

--[[
	Returned by Base64.CreateEncoderStream.
	Processes input in fixed-size chunks to bound peak memory usage; useful
	when the source buffer is large (> a few hundred KB).
]]--
export type EncoderStream = {
	--[[
		Append bytes from `b`. Optional `offset` and `length` allow writing
		a sub-range without creating a temporary slice buffer.
		Returns (true, nil) on success or (false, errorMsg) on failure.
	]]--
	write: (self: EncoderStream, b: buffer, offset: number?, length: number?) -> (boolean, string?),

	--[[
		Flush any remaining bytes (with padding if needed) and return the
		complete base64 string. The stream is sealed after this call.
	]]--
	finalize: (self: EncoderStream) -> (string?, string?),

	--[[
		Abort the stream and release internal buffers tracked by Trove.
		Subsequent write/finalize calls return an error.
	]]--
	cancel: (self: EncoderStream) -> (),
}

--------------------------------------------------------------------------------
-- Compress progress callback
--------------------------------------------------------------------------------

--[[
	Passed to Compress.CompressProgressive.
	`done` is the number of source bytes processed so far; `total` is the
	full source size. Called once per 64 KB chunk and once on completion.
]]--
export type ProgressFn = (done: number, total: number) -> ()

--------------------------------------------------------------------------------
--	 Full Buffer module interface

--	 Typed as a table of functions so that other modules can annotate
--	 parameters that accept the Buffer module itself (e.g. Benchmark.Run).
--------------------------------------------------------------------------------

export type BufferModule = {
	--[[
		Core encode / decode
	]]--
	Encode: (value: any) -> (buffer?, string?),
	EncodeWith: (value: any, priority: Priority) -> (buffer?, string?),
	EncodeWithPolicy: (value: any, policy: CachePolicy) -> (buffer?, string?),
	EncodeCompressed: (value: any, mode: CompressionMode?, hint: string?) -> (buffer?, string?),
	Decode: (b: buffer) -> any,
	SafeDecode: (b: buffer) -> (any, string?),

	--[[
		Cyclic reference guard — like Encode but detects self-referential
		tables before encoding and returns a descriptive error instead of
		hitting MAX_DEPTH on a self-loop.
	]]--
	EncodeSafe: (value: any) -> (buffer?, string?),

	--[[
		Schema encode / decode (field names omitted from wire)
	]]--
	ValidateSchema: (schema: Schema) -> (boolean, string?),
	EncodeSchema: (value: { [string]: any }, schema: Schema) -> (buffer?, string?),
	DecodeSchema: (b: buffer, schema: Schema) -> ({ [string]: any }?, string?),

	--[[
		Schema migration — upgrade a decoded record through a chain of
		per-version step functions. Missing steps are treated as no-ops.
	]]--
	MigrateSchema: (
		data: { [string]: any },
		fromVersion: number,
		toVersion: number,
		migrations: MigrationMap
	) -> ({ [string]: any }?, string?),

	--[[
		Schema delta — encode / decode only the fields that changed using a
		u32 bitmask instead of field names. Supports up to 32 fields.
		Wire: u8 version | u32 bitmask | values_for_set_bits_in_order.
	]]--
	EncodeSchemaDelta: (
		old:{ [string]: any },
		new: { [string]: any },
		schema: Schema
	) -> (buffer?, string?),
	DecodeSchemaDelta: (
		b: buffer,
		current: { [string]: any },
		schema: Schema
	) -> ({ [string]: any }?, string?),

	--[[
		SchemaType constructors — pass the result as field.type instead of
		a plain string for richer encode-time validation.
	]]--
	Types: {
		any: () -> SchemaType,
		exact: (typeofStr: string) -> SchemaType,
		number: () -> SchemaType,
		numberRange: (min: number, max: number) -> SchemaType,
		integer:() -> SchemaType,
		string: (maxLen: number?) -> SchemaType,
		boolean: () -> SchemaType,
		array: (elementType: SchemaType, maxLen: number?) -> SchemaType,
		union: (...SchemaType) -> SchemaType,
		optional: (inner: SchemaType) -> SchemaType,
		literal: (...any) -> SchemaType,
	},

	--[[
		Base64 & JSON helpers
	]]--
	EncodeToBase64: (value: any, urlSafe: boolean?) -> (string?, string?),
	DecodeFromBase64: (s: string) -> (any, string?),
	BufferToBase64: (b: buffer, urlSafe: boolean?) -> string,
	Base64ToBuffer: (s: string) -> (buffer?, string?),
	ToJSON: (b: buffer) -> (string?, string?),
	FromJSON: (json: string) -> (buffer?, string?),

	--[[
		Delta / patch
	]]--
	EncodeDelta: (old: { [string]: any }, new: { [string]: any }) -> (buffer?, string?),
	ApplyDelta: (target: { [string]: any }, delta: buffer) -> { [string]: any },

	--[[
		Async
	]]--
	EncodeAsync: (value: any) -> AsyncHandle,
	DecodeAsync: (b: buffer) -> AsyncHandle,

	--[[
		Streaming
	]]--
	CreateStream: () -> Stream,

	--[[
		Instance registry
	]]--
	RegisterInstance:   (instance: Instance, id: number) -> (),
	UnregisterInstance: (instance: Instance) -> (),

	--[[
		Custom type registry
	]]--
	RegisterType: (id: number, ct: CustomType) -> (),
	CustomByType: { [string]: { id: number, ct: CustomType } },

	--[[
		Cache utilities
	]]--
	Invalidate:  (value: any) -> (),
	EncodedSize: (value: any) -> (number?, string?),

	--[[
		Compression utilities
	]]--
	SetCompressionDict: (dict: buffer) -> (),
	DetectDataClass: (b: buffer) -> string,
	VisualizeEntropy: (b: buffer) -> string,
	Visualize: (b: buffer) -> string,
}

return Types