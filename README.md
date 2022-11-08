# fontana

*OpenType and TrueType font loading and rasterizing library*

**Fontana is in development and not ready for use in projects**

## Usage

This is the high-level overview of how to currently use fontana. It's also possible to render a single glyph to a contigious texture buffer, but generating a font atlas is the most common use-case.

    const ttf_buffer = loadTTF("fontname.ttf");
    var font = try fontana.otf.parseFromBytes(ttf_buffer);
    var font_atlas: fontana.Atlas(.{
        .pixel_format = .rgba_f32,
        .encoding = .ascii,
    }) = undefined;

    const codepoints = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ1234567890";
    //
    // This will write the font bitmap atlas to texture_buffer
    //
    try font_atlas.init(allocator, font, codepoints, 80, texture_buffer, texture_dimensions);
    defer font_atlas.deinit(allocator);

For a runnable example, see [fontana-example](https://github.com/kdchambers/fontana-examples). Example projects and binary assets are not to be checked into the main repo to keep it small.

## License

MIT