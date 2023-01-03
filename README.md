# Fontana

*Toolkit for OpenType / TrueType fonts; text rendering in general*

___

**TLDR:** 

- In development, but functional
- TTF / OTF loading + drawing
- Wrapper over multiple backends
  - Custom built (Including rasterizer)
  - Freetype
  - Freetype & Harfbuzz
- Intended for use with low-level graphics API (Vulkan, WebGPU, etc)
- Will later pivot into new simplified Font format intended for projects that have the luxury of embedding fonts (games, operating systems, etc)

## Scope 

- Definition of a new Font Format designed primarily for embedded use
- Converter from TTF / OTF -> Embedded format
- Easy to use wrapper around Freetype / Harfbuzz for drawing
- Custom Font loading / rendering backend

## API & Usage

**NOTE**: *This only refers to the TTF / OTF loading / drawing capabilities. Custom font format is still a TODO. See [Roadmap](#roadmap) for state of project*

Currently, the API is very simple but provides a lot of flexibility through comptime configuration.

The first step is creating the Font type, which takes a backend as a comptime configuration option. The options are: `fontana`, `freetype` and `freetype_harfbuzz`. In the example below, we're using the custom built `fontana` backend:

```c++
const font_backend: fontana.Backend = .fontana;
const Font = fontana.Font(font_backend);

var font = try Font.initFromFile(allocator, font_path);
defer font.deinit(allocator);
```

The `Font` type has 3 public functions, `initFromFile()`, `deinit()` and `createPen()`. The first two work as expected, so let's move onto the `Pen` type.

The `Pen` type encapsules an atlas, font size and collection of codepoints. The specified codepoints will be converted into glyphs and rasterised to a texture. If working on an application that will be rendering text at different sizes, you can generate more `Pens` from the same `Font`.

**NOTE**: *The Font Atlas managed by a Pen can share the backing texture with other parts of an application, it only owns the meta-data about what rendered glyphs are stored where.*

Here's the function signature:

```rust
pub fn createPen(
    self: *@This(),
    comptime PixelType: type,
    allocator: std.mem.Allocator,
    size: Size,
    points_per_pixel: f64,
    codepoints: []const u8,
    texture_size: u32,
    texture_pixels: [*]PixelType,
) !Pen
```

Continuing the above example, here a `Pen` is created from our font.

```rust
const PixelType = graphics.RGBA(f32);
const points_per_pixel = 100;
const font_size = fontana.Size{ .point = 24.0 };
const pen = try font.createPen(
    PixelType,
    allocator,
    font_size,
    points_per_pixel,
    atlas_codepoints,
    texture.dimensions.width,
    texture.pixels,
);
```

**NOTE**: *The Atlas only supports square textures, hence texture_size as opposed to texture_dimensions*

**NOTE**: *The PixelType is passed by the client and it's properties are detected automatically during rasterization. Unless it's a very irregular type it should just work.*

The `Pen` type has a single purpose, to generate texture quads to a vertex buffer that can be used by a graphics API to draw text to the screen. It only has a single public function:

```rust
pub fn write(
    self: *@This(),
    codepoints: []const u8,
    placement: geometry.Coordinates2D(f64),
    screen_scale: geometry.Scale2D(f64),
    writer_interface: anytype,
) !void
```

The client specifies what text to render, where to render it on the screen, the scaling of the screen and a comptime interface used to channel the output.

`screen_scale` converts pixels to the coordinate system of the graphics API, in vulkan it can be calculated as follows:

```rust
fn scaleFromScreenDimensions(width: f64, height: f64) Scale2D(f64) {
    return .{
        .vertical = 2.0 / height,
        .horizontal = 2.0 / width,
    };
}
```

This is because Vulkan uses the NDC right coordinate system, going from -1.0 to +1.0 (Total length of 2.0) on both the X and Y axis.

`writer_interface` is of a comptime evaluated type, and has to satisfy the following interface:

```rust
pub fn write(
    self: *@This(),
    screen_extent: fontana.geometry.Extent2D(f32),
    texture_extent: fontana.geometry.Extent2D(f32),
) !void
```

All this does is map texture values to locations on the output display, defined in the coordinate system of the underlying graphics API.

## Integration

Just add `src/fontana.zig` as a new package in your build.zig.

```rust
const fontana_path = "your_project/deps/fontana";
exe.addPackage(.{
    .name = "fontana",
    .source = .{ .path = fontana_path ++ "/src/fontana.zig" },
});
```

Fontana is kept in sync with the latest zig release. It was last tested with version **0.11.0-dev.1023**.

## Example

A running example can be found in the example repository [fontana-examples](https://github.com/kdchambers/fontana-examples). 
Non-essential assets including large amount of code are not checked into the main repo to keep it minimal and automation friendly.

To see the above example in complete form, see [this file specifically](https://github.com/kdchambers/fontana-examples/blob/main/src/main.zig)

## Roadmap

TODO: Add ROADMAP

## License

MIT