# <h1 align="center">Buffer</h1>
<h1 align="center">Next-Gen Binary Serialiser for Roblox (Luau). Encodes almost every Roblox/Lua value type into a binary buffer with tags.</h1>

## Downoload
[Downoload on Roblox Creator Store](https://create.roblox.com/store/asset/96592288854226/)

## Official Wiki (Still In Dev)
[Jump](https://maneetoo.github.io/Buffer/)

## Features

- **Full type support**: Primitives, vectors, CFrames, color sequences, enums, instances, and custom types
- **Multi-tier caching**: Hot/Warm/Cold LRU cache with configurable policies
- **Schema validation**: Versioned schemas with type checking and migration support
- **Delta encoding**: Efficient partial updates for structured data
- **Compression**: LZ4, ZSTD, and Deflate with automatic mode selection
- **Async API**: Non-blocking encode/decode for large data structures
- **Zero-copy streaming**: Stream multiple values into a single buffer

## Quick Start

```lua
local Buffer = require(game.ReplicatedStorage.Buffer)

-- Encode
local data = {
    position = Vector3.new(10, 20, 30),
    health = 100,
    name = "Player"
}
local buf, err = Buffer.Encode(data)

-- Decode
local decoded = Buffer.Decode(buf)
```

## Supported Types

| Category | Types |
|----------|-------|
| Primitives | nil, boolean, number (auto-sized), string (≤65535 bytes) |
| Math | Vector2, Vector3, Vector2int16, Vector3int16, CFrame, UDim, UDim2, Ray, Rect |
| Color | Color3, BrickColor, ColorSequence, ColorSequenceKeypoint |
| Sequences | NumberRange, NumberSequence, NumberSequenceKeypoint |
| Roblox | EnumItem, Font, Content, DateTime, Region3, Region3int16, PhysicalProperties, Axes, Faces, TweenInfo |
| Containers | Table (dictionary), Array (with RLE) |
| Special | Instance (registered reference), custom registered types |

## Performance Notes

- Primitive values (true, false, 0) return pre-allocated singletons
- String caching for values up to 1000 bytes
- RLE compression for arrays with runs ≥ 3 and total length ≥ 64
- Large dictionaries (>4096 fields) encoded in chunks to avoid buffer overflow
- Scratch buffer pool reduces allocations in hot paths

## Limitations

- Maximum string length: 65535 bytes
- Maximum array/table fields: 65535
- Table keys limited to string and number types (numbers converted to strings on wire)
- Instance references require manual registration on both sides

## Credits
This module uses:
**t** - https://github.com/osyrisrblx/t
**Trove** - https://github.com/Sleitnick/RbxUtil/blob/main/modules/component/init.luau?ysclid=mn1gw1vbnr25173765
