# <h1 align="center">API Reference</h1>

## Overview

Buffer encodes almost every Roblox/Luau value type into a compact binary format with type tags. It features multi-tiered LRU caching, schema validation, delta encoding, compression, and async processing for large data structures.

!!! notice
    All methods that return `(buffer?, string?)` return an error message as the second return value on failure. Use `SafeDecode` to handle untrusted input without throwing.

!!! warning
    The buffer returned from `Encode` is immutable for the purpose of caching. Do not modify it directly.

!!! failure
    Encoding `nil` as a root value is not supported and will return an error. To encode a "null" value, wrap it in a table (e.g., `{value = nil}`).

---

## Core API

### Buffer.Encode

```lua
Buffer.Encode(value: any) -> (buffer?, errorMsg: string?)
```

Encodes any supported value into a binary buffer. Non-table results (booleans, numbers, strings under 1000 bytes) are automatically cached in the "warm" LRU tier.

**Returns:**

On success: `buffer` — the encoded binary data;
On failure: `nil, errorMsg` — descriptive error message

**Example:**
```lua
local buffer, err = Buffer.Encode({ player = "John", score = 1000 })
if not buffer then
    warn("Encoding failed:", err)
    return
end
```

!!! warning
    `nil` as a root value is not supported. To encode a null, wrap it in a table: `{ value = nil }`.

!!! notice
    Tables are **not** automatically cached due to mutability. Use `EncodeWithPolicy` for table caching.

---

### Buffer.Decode

```lua
Buffer.Decode(b: buffer) -> any
```

Decodes a buffer back into a value. Throws an error if the buffer is corrupt or malformed.

**Parameters:**
`b: buffer` — the encoded binary data

**Returns:** The decoded value

**Example:**
```lua
local value = Buffer.Decode(buffer)
print(value.player, value.score) -- "John", 1000
```

!!! failure
    This method **throws** on error. Always use `SafeDecode` for untrusted input.

---

### Buffer.SafeDecode

```lua
Buffer.SafeDecode(b: buffer) -> (value: any, errorMsg: string?)
```

Decodes a buffer safely, returning an error message instead of throwing. Ideal for handling network data, file input, or external sources.

**Parameters:**
`b: buffer` — the encoded binary data

**Returns:**
On success: `value, nil`;
On failure: `nil, errorMsg`

**Example:**
```lua
local value, err = Buffer.SafeDecode(untrustedBuffer)
if err then
    print("Corrupt data:", err)
    return
end
```

!!! notice
    Even with SafeDecode, malformed data can cause the decoder to return unexpected but valid Lua values. Always validate the structure after decoding.

---

### Buffer.EncodeSafe

```lua
Buffer.EncodeSafe(value: any) -> (buffer?, string?)
```

A wrapper around `Buffer.Encode` that performs cycle detection on tables. Prevents infinite recursion from self-referential structures.

**Example:**
```lua
local cycle = {}
cycle.self = cycle -- Cyclic reference

local buffer, err = Buffer.EncodeSafe(cycle)
if not buffer then
    print("Cannot encode cycles:", err) -- "cyclic reference at root.self"
end
```

!!! failure
    Standard `Buffer.Encode` will crash on cyclic tables. Always use `EncodeSafe` when the table structure is unknown or untrusted.

---

### Buffer.EncodeWith

```lua
Buffer.EncodeWith(value: any, priority: "hot" | "warm" | "cold") -> (buffer?, string?)
```

Encodes a value with a specific cache tier priority. Overrides the default caching behavior.

**Cache Tiers:**

| Priority | Capacity | Best For |
|----------|----------|----------|
| `"hot"`  | 100      | Values that change every frame (player positions, current state) |
| `"warm"` | 500      | Default tier; general-purpose caching                            |
| `"cold"` | 2000     | Large, infrequently accessed values (static data, configuration) |

**Example:**
```lua
-- Player position changes every frame — use hot cache
local posBuffer = Buffer.EncodeWith(player.Position, "hot") -- EXAMPLE!!!

-- Game configuration rarely changes — use cold cache
local configBuffer = Buffer.EncodeWith(gameConfig, "cold")
```

!!! warning
    Cache is keyed by value equality, not reference. Two different tables with identical contents will share a cache entry.

---

### Buffer.EncodeWithPolicy

```lua
Buffer.EncodeWithPolicy(value: any, policy: "never" | "always" | "if-shallow") -> (buffer?, string?)
```

Applies a caching policy specifically for table values. This is the only way to cache tables.

**Policies:**
`"never"` — Do not cache the table (default behavior)
`"always"` — Cache based on a fast content hash of the table's **entire** contents
`"if-shallow"` — Cache only if the table contains no nested tables (shallow tables only)

**Important:** 
`"always"` computes a hash of all key-value pairs. This is safe **only for immutable tables** (tables that never change).
`"if-shallow"` is ideal for configuration tables, settings, or any table without nested structures.

**Example:**
```lua
-- Immutable static data — safe to always cache
local staticData = { version = 2, type = "config" }
local buffer1 = Buffer.EncodeWithPolicy(staticData, "always")

-- Nested table — "if-shallow" won't cache this
local nested = { player = { name = "John" } }
local buffer2 = Buffer.EncodeWithPolicy(nested, "if-shallow") -- No caching

-- Shallow table — will be cached
local shallow = { x = 10, y = 20, z = 30 }
local buffer3 = Buffer.EncodeWithPolicy(shallow, "if-shallow") -- Cached
```

!!! failure
    Using `"always"` on mutable tables can lead to stale cache entries. Only use this policy for tables that never change after encoding.

---

## Schema System

Schemas provide type safety and structure validation for your data. They're ideal for network protocols, configuration files, and any data that must adhere to a known format. It takes up as little space as possible

### Schema Definition

A schema is a table with a `version` (optional, 1-255) and a `fields` array:

```lua
type Schema = {
    version?: number,
    fields: {
        name: string,
        type: string | SchemaType,
        optional?: boolean,
        default?: any,
    }[]
}
```

**Example Schema:**
```lua
local playerSchema = {
    version = 1,
    fields = {
        { name = "name", type = "string" },
        { name = "level", type = "number", optional = false },
        { name = "inventory", type = Buffer.Types.array(Buffer.Types.string()) },
        { name = "lastLogin", type = "DateTime", optional = true, default = DateTime.now() }
    }
}
```

### Buffer.EncodeSchema

```lua
Buffer.EncodeSchema(value: { [string]: any }, schema: Schema) -> (buffer?, string?)
```

Encodes a value according to a schema, performing validation before encoding.

**Validations performed:**
Required fields exist
Field types match schema definition
Custom validators (if using `Buffer.Types`) pass

**Example:**
```lua
local playerData = {
    name = "John",
    level = 42,
    inventory = { "sword", "shield" }
}

local buffer, err = Buffer.EncodeSchema(playerData, playerSchema)
if not buffer then
    print("Validation failed:", err)
end
```

### Buffer.DecodeSchema

```lua
Buffer.DecodeSchema(b: buffer, schema: Schema) -> ({ [string]: any }?, string?)
```

Decodes a buffer according to a schema. Returns a table with all fields populated, using defaults for optional fields if they're missing from the encoded data.

**Behavior:**
Fields not present in the buffer use the schema's `default` value (if specified)
Missing required fields return an error
Type validation is performed on all decoded values

**Example:**
```lua
local data, err = Buffer.DecodeSchema(buffer, playerSchema)
if not err then
    print(data.name, data.level) -- "John", 42
    print(data.lastLogin) -- DateTime.now() (default)
end
```

### Buffer.ValidateSchema

```lua
Buffer.ValidateSchema(schema: Schema) -> (boolean, string?)
```

Validates a schema definition without encoding any data.

**Validates:**
`fields` is an array
Each field has a non-empty `name`
Field names are unique
Field `type` is a valid string or `SchemaType` object
Optional fields with defaults are properly marked

**Example:**
```lua
local ok, err = Buffer.ValidateSchema(playerSchema)
if not ok then
    error("Invalid schema: " .. err)
end
```

!!! failure
    A schema must have at least one field. Empty schemas are rejected.

---

## Buffer.Types

`Buffer.Types` provides factory functions for creating type validators used in schemas.

### Types.any()

```lua
Buffer.Types.any() -> SchemaType
```

Accepts any value. Useful for polymorphic fields.

### Types.exact()

```lua
Buffer.Types.exact(typeofStr: string) -> SchemaType
```

Requires the value to have exactly the given `typeof()` result.

### Types.number()

```lua
Buffer.Types.number() -> SchemaType
```

Accepts any Lua number.

### Types.numberRange()

```lua
Buffer.Types.numberRange(min: number, max: number) -> SchemaType
```

Accepts numbers within the inclusive range `[min, max]`.

### Types.integer()

```lua
Buffer.Types.integer() -> SchemaType
```

Accepts whole numbers (no fractional part).

### Types.string()

```lua
Buffer.Types.string(maxLen: number?) -> SchemaType
```

Accepts strings. Optionally enforces a maximum length.

### Types.boolean()

```lua
Buffer.Types.boolean() -> SchemaType
```

Accepts boolean values.

### Types.array()

```lua
Buffer.Types.array(elementType: SchemaType, maxLen: number?) -> SchemaType
```

Accepts Lua sequences (contiguous integer keys starting from 1). Validates each element against `elementType`. Optionally enforces maximum length.

**Example:**
```lua
local stringArray = Buffer.Types.array(Buffer.Types.string())
local numberArray = Buffer.Types.array(Buffer.Types.numberRange(0, 100), 10)
```

### Types.union()

```lua
Buffer.Types.union(...: SchemaType) -> SchemaType
```

Accepts values that match any of the provided types.

**Example:**
```lua
local stringOrNumber = Buffer.Types.union(
    Buffer.Types.string(),
    Buffer.Types.number()
)
```

### Types.optional()

```lua
Buffer.Types.optional(inner: SchemaType) -> SchemaType
```

Accepts either `nil` or a value matching the inner type.

### Types.literal()

```lua
Buffer.Types.literal(...: any) -> SchemaType
```

Accepts only the exact literal values provided.

**Example:**
```lua
local direction = Buffer.Types.literal("up", "down", "left", "right")
```

---

## Schema Deltas

Deltas encode only the differences between two schema-compliant tables, significantly reducing storage and transmission size for incremental updates.

### Buffer.EncodeSchemaDelta

```lua
Buffer.EncodeSchemaDelta(
    old: { [string]: any },
    new: { [string]: any },
    schema: Schema
) -> (buffer?, string?)
```

Encodes only the fields that differ between `old` and `new`. Uses a bitmask to indicate which fields changed.

**Requirements:**
Both `old` and `new` must be valid against the schema
Fields with `nil` in `new` are considered unchanged (not encoded)

**Example:**
```lua
local old = { name = "John", level = 42, score = 1000 }
local new = { name = "John", level = 43, score = 1000 }

-- Only encodes the 'level' field (changed from 42 to 43)
local delta, err = Buffer.EncodeSchemaDelta(old, new, playerSchema)
```

!!! notice
    The encoded delta is typically much smaller than re-encoding the entire `new` table, especially when few fields change.

### Buffer.DecodeSchemaDelta

```lua
Buffer.DecodeSchemaDelta(
    b: buffer,
    current: { [string]: any },
    schema: Schema
) -> ({ [string]: any }?, string?)
```

Applies a delta buffer to the `current` table, updating it with the changes. The table is modified in-place.

**Example:**
```lua
-- current is { name = "John", level = 42, score = 1000 }
local updated, err = Buffer.DecodeSchemaDelta(deltaBuffer, current, playerSchema)
-- updated.level is now 43
```

---

## Schema Migration

When your schema evolves over time, migrations allow you to transform older data versions to the latest format.

### MigrationMap

```lua
type MigrationMap = { [fromVersion: number]: (data: { [string]: any }) -> { [string]: any } }
```

A table mapping a version number to a migration function. The function receives data in the old format and returns data in the new format for the **next** version.

**Example:**
```lua
local migrations = {
    [1] = function(data)
        -- Version 1 → Version 2: Add default inventory
        data.inventory = data.inventory or {}
        return data
    end,
    [2] = function(data)
        -- Version 2 → Version 3: Rename 'xp' to 'experience'
        data.experience = data.xp
        data.xp = nil
        return data
    end
}
```

### Buffer.MigrateSchema

```lua
Buffer.MigrateSchema(
    data: { [string]: any },
    fromVersion: number,
    toVersion: number,
    migrations: MigrationMap
) -> ({ [string]: any }?, string?)
```

Applies the necessary migration steps to transform data from `fromVersion` to `toVersion`. The original data is not modified.

**Returns:**
On success: the migrated data table
On failure: `nil, errorMsg`

**Example:**
```lua
local oldData = { name = "John", xp = 100 } -- Version 1
local migrated, err = Buffer.MigrateSchema(oldData, 1, 3, migrations)
-- migrated now has: { name = "John", experience = 100, inventory = {} }
```

!!! warning
    Migrations are applied sequentially. You cannot skip versions or downgrade (fromVersion must be less than toVersion).

---

## Compression

Buffer supports transparent compression using LZ4, Deflate, and Zstd algorithms.

### Buffer.EncodeCompressed

```lua
Buffer.EncodeCompressed(
    value: any,
    mode: CompressionMode?,
    hint: string?
) -> (buffer?, string?)
```

Encodes a value and compresses the resulting buffer. The compression method is stored as a tag in the output, allowing `Buffer.Decode` to decompress automatically.

**Compression Modes:**

| Mode | Description |
|------|-------------|
| `"auto"`    | Automatically selects the best algorithm based on data size and entropy (default) |
| `"lz4"`     | Fast compression/decompression, moderate ratio                                    |
| `"deflate"` | Balanced compression, widely compatible                                           |
| `"zstd"`    | High compression ratio, good speed                                                |

**Hints:**
`"binary"` — Data is binary (e.g., images, custom formats)
`"text"` — Data is human-readable text
`"json"` — Data is JSON-like

**Example:**
```lua
-- Auto-select best compression
local compressed, err = Buffer.EncodeCompressed(hugeTable)

-- Force Zstd with binary hint
local compressed, err = Buffer.EncodeCompressed(largeData, "zstd", "binary")
```

!!! notice
    The output buffer can be passed directly to `Buffer.Decode` — decompression happens automatically.

### Buffer.SetCompressionDict

```lua
Buffer.SetCompressionDict(dict: buffer)
```

Sets a custom dictionary for LZ4 and Zstd compression. Dictionaries can significantly improve compression ratios for small, repetitive data by providing a common pattern base.

**Use cases:**
Game state snapshots with known structure
Network packets with repeated headers
Configuration files with common keys

**Example:**
```lua
local dict = Buffer.Encode({
    { "position", "velocity", "rotation" }, -- Common field names
    { "player", "npc", "item" }             -- Common object types
})
Buffer.SetCompressionDict(dict)
```

!!! warning
    The dictionary must be identical for compression and decompression. Include it in your game's assets or transmit it with the data.

---

## Instance Registry

Roblox Instances are encoded as numeric IDs (u32) rather than full objects. This requires a registry to map IDs to instances.

### Buffer.RegisterInstance

```lua
Buffer.RegisterInstance(instance: Instance, id: number)
```

Registers an instance with a numeric ID. The decoder uses the same ID to look up the instance.

**Requirements:**
ID must be between 0 and 0xFFFFFFFF (u32 range)
Each instance can have only one ID
IDs must be unique

**Example:**
```lua
local player = game.Players.LocalPlayer
Buffer.RegisterInstance(player, 1)

-- Now player can be encoded and decoded
local buffer = Buffer.Encode(player)
local decoded = Buffer.Decode(buffer) -- Returns the same player instance
```

!!! notice
    The library automatically unregisters instances when they're destroyed (using the `Destroying` event). No manual cleanup is needed.

### Buffer.UnregisterInstance

```lua
Buffer.UnregisterInstance(instance: Instance)
```

Manually unregisters an instance. This is automatically handled by the library, but can be used for explicit cleanup.

---

## Custom Types

You can extend Buffer to support custom Roblox or Lua types by registering a custom encoder/decoder.

### CustomType Definition

```lua
type CustomType = {
    encode: (BB: buffer, value: any, offset: number) -> (number?, string?),
    decode: (b: buffer, offset: number) -> (any, number),
}
```

- **encode**: Writes the value to the buffer at `offset`. Returns the new offset or `nil, error`.
- **decode**: Reads a value from the buffer at `offset`. Returns `(value, newOffset)`.

### Buffer.RegisterType

```lua
Buffer.RegisterType(id: number, ct: CustomType)
```

Registers a custom type with a numeric ID (0-254). IDs 0-127 are reserved for future library use.

**Example:**
```lua
-- Custom type for UDim2 (though already supported)
Buffer.RegisterType(200, {
    encode = function(BB, value, offset)
        buf_writeu8(BB, offset, T_UDIM2)
        buf_writef32(BB, offset+1, value.X.Scale)
        buf_writei32(BB, offset+5, value.X.Offset)
        buf_writef32(BB, offset+9, value.Y.Scale)
        buf_writei32(BB, offset+13, value.Y.Offset)
        return offset + 17, nil
    end,
    decode = function(b, offset)
        return UDim2.new(
            buf_readf32(b, offset),
            buf_readi32(b, offset+4),
            buf_readf32(b, offset+8),
            buf_readi32(b, offset+12)
        ), offset + 16
    end
})
```

!!! warning
    Custom type IDs must be unique. Registering with an existing ID will overwrite it.

---

## Advanced Encoding

### Buffer.EncodeDelta

```lua
Buffer.EncodeDelta(old: { [string]: any }, new: { [string]: any }) -> (buffer?, string?)
```

Encodes a delta between two dictionaries (not schema-validated). Fields present in `old` but missing in `new` are encoded as `nil` (deleted). This is a lower-level API than schema deltas.

**Example:**
```lua
local old = { a = 1, b = 2, c = 3 }
local new = { a = 1, b = 4 } -- c is deleted

local delta = Buffer.EncodeDelta(old, new)
-- delta encodes: b changed to 4, c deleted (nil)
```

### Buffer.ApplyDelta

```lua
Buffer.ApplyDelta(target: { [string]: any }, delta: buffer) -> { [string]: any }
```

Applies a delta buffer to a target table, modifying it in-place. Returns the target for chaining.

**Example:**
```lua
local target = { a = 1, b = 2, c = 3 }
Buffer.ApplyDelta(target, deltaBuffer)
-- target is now { a = 1, b = 4 } (c removed)
```

### Buffer.CreateStream

```lua
Buffer.CreateStream() -> Stream
```

Creates a streaming encoder for writing multiple values sequentially. Useful for batched operations or when you don't know the final size ahead of time.

**Stream Methods:**
- `stream:write(value: any) -> (boolean, string?)` — Encode and append a value
- `stream:finalize() -> (buffer?, string?)` — Return the concatenated buffer

**Example:**
```lua
local stream = Buffer.CreateStream()
stream:write({ type = "player", name = "John" })
stream:write({ type = "score", value = 1000 })
stream:write({ type = "inventory", items = { "sword" } })

local buffer = stream:finalize() -- All three values concatenated
```

!!! notice
    Once finalized, the stream cannot be written to again.

## Asynchronous Operations

For large tables with thousands of fields, synchronous encoding can block the main thread. Async methods process data in chunks, yielding between batches to keep the game responsive.

### AsyncHandle

Async methods return a handle with the following methods:

- `handle:Await() -> (buffer?, string?)` — Waits for completion and returns result
- `handle:Cancel()` — Cancels the ongoing operation

### Buffer.EncodeAsync

```lua
Buffer.EncodeAsync(value: any) -> AsyncHandle
```

Encodes a large table asynchronously. Processes fields in chunks of `ASYNC_FIELDS_PER_STEP` (default 256), yielding between chunks.

**Example:**
```lua
local handle = Buffer.EncodeAsync(largeTable)

-- Do other work while encoding runs...
updateGameState()

-- Wait for completion when needed
local buffer, err = handle:Await()
if buffer then
    saveToDataStore(buffer)
end
```

!!! notice
    Async encoding only yields for tables with more than 256 fields. Small values encode synchronously.

### Buffer.DecodeAsync

```lua
Buffer.DecodeAsync(b: buffer) -> AsyncHandle
```

Decodes a buffer asynchronously. Currently processes the entire decode in a single chunk but yields at least once.

**Example:**
```lua
local handle = Buffer.DecodeAsync(buffer)

-- Wait for result
local value, err = handle:Await()
if value then
    print("Decoded:", value)
end
```

!!! warning
    Cancelling an async operation after it completes has no effect. Cancelling during processing prevents the completion callback.

---

## Conversions

### Buffer.EncodeToBase64

```lua
Buffer.EncodeToBase64(value: any, urlSafe: boolean?) -> (string?, string?)
```

Encodes a value and converts the binary buffer to a Base64 string. If `urlSafe` is true, uses URL-safe Base64 encoding (replaces `+` and `/` with `-` and `_`).

**Example:**
```lua
local b64, err = Buffer.EncodeToBase64({ data = "hello" }, true)
if b64 then
    print(b64) -- "eyJkYXRhIjoiaGVsbG8ifQ==" (or URL-safe variant)
end
```

### Buffer.DecodeFromBase64

```lua
Buffer.DecodeFromBase64(s: string) -> (any, string?)
```

Decodes a Base64 string back into a value.

**Example:**
```lua
local value, err = Buffer.DecodeFromBase64(b64String)
if value then
    print(value.data) -- "hello"
end
```

### Buffer.BufferToBase64

```lua
Buffer.BufferToBase64(b: buffer, urlSafe: boolean?) -> string
```

Converts a binary buffer to a Base64 string. Throws on error.

### Buffer.Base64ToBuffer

```lua
Buffer.Base64ToBuffer(s: string) -> (buffer?, string?)
```

Converts a Base64 string back into a binary buffer. Returns an error on invalid Base64.

### Buffer.ToJSON

```lua
Buffer.ToJSON(b: buffer) -> (string?, string?)
```

Decodes a buffer and converts the result to a JSON string. Handles special types (Vector3, CFrame, etc.) by adding a `__type` field.

**Example:**
```lua
local json, err = Buffer.ToJSON(buffer)
if json then
    print(json) -- {"__type":"Vector3","x":1,"y":2,"z":3}
end
```

### Buffer.FromJSON

```lua
Buffer.FromJSON(json: string) -> (buffer?, string?)
```

Parses a JSON string and encodes the result. The JSON must represent a valid Lua value (no functions, userdata, etc.).

**Example:**
```lua
local buffer, err = Buffer.FromJSON('{"player":"John","score":1000}')
if buffer then
    -- buffer can now be decoded to a Lua table
end
```

---

## Debugging & Introspection

### Buffer.Visualize

```lua
Buffer.Visualize(b: buffer) -> string
```

Returns a human-readable representation of the buffer's internal structure, showing byte offsets and tag names.

**Example output:**
```
[0000] 11 STR16
[0001] 05
[0006] 18 ARRAY
[0007] 03
[0010] 02 U8
[0011] 42
[0012] 02 U8
[0013] 43
[0014] 02 U8
[0015] 44
```

### Buffer.VisualizeEntropy

```lua
Buffer.VisualizeEntropy(b: buffer) -> string
```

Shows the entropy distribution of a buffer, helping to choose the optimal compression algorithm.

### Buffer.DetectDataClass

```lua
Buffer.DetectDataClass(b: buffer) -> string
```

Attempts to classify the type of data in a buffer. Returns one of:
- `"binary"` — Unknown binary data
- `"text"` — Human-readable text
- `"json"` — JSON-like structure
- `"lz4"` — Already LZ4 compressed
- `"zstd"` — Already Zstd compressed
- `"deflate"` — Already Deflate compressed

### Buffer.Invalidate

```lua
Buffer.Invalidate(value: any)
```

Removes a value from all cache tiers. Useful when you know a cached value is stale.

**Example:**
```lua
local config = loadConfig()
Buffer.EncodeWithPolicy(config, "always") -- Cached
-- ... later, config changes ...
Buffer.Invalidate(config) -- Clear stale cache
```

### Buffer.EncodedSize

```lua
Buffer.EncodedSize(value: any) -> (number?, string?)
```

Estimates the byte size of the encoded value without allocating a final buffer. Useful for pre-allocation, validation, or checking if a value will exceed size limits.

**Returns:**
On success: `number` — estimated size in bytes
On failure: `nil, errorMsg`

**Example:**
```lua
local size, err = Buffer.EncodedSize(hugeTable)
if size and size > 1024 * 1024 then
    warn("Table will be 1MB+ after encoding!")
end
```

!!! notice
    This is an estimate; the actual encoded size may differ slightly due to tag overhead. The estimate is accurate within a few bytes.

---

---

## Utility Functions

### Buffer.Types

The `Buffer.Types` namespace contains all type factory functions. This is a reference to the `Types` module, accessible for convenience.

### Buffer.CustomByType

```lua
Buffer.CustomByType: { [string]: { id: number, ct: CustomType } }
```

A table mapping type names to registered custom types. Useful for introspection.

---
manee was here :)