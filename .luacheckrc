std = "luau"
ignore = {
    "212", -- unused argument
    "213", -- unused loop variable
}
globals = {
    "buffer",  -- Roblox buffer library
    "task",    -- Roblox task library
    "debug",   -- Roblox debug library
    "Enum",    -- Roblox Enum
    "Vector3", "Vector2", "Vector3int16", "Vector2int16",
    "CFrame", "Color3", "UDim2", "UDim", "Ray", "NumberRange",
    "BrickColor", "Rect", "ColorSequence", "ColorSequenceKeypoint",
    "NumberSequence", "NumberSequenceKeypoint", "Font", "Content",
    "DateTime", "Region3", "Region3int16", "PhysicalProperties",
    "Axes", "Faces", "TweenInfo", "Instance"
}