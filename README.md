# fontana

*OpenType and TrueType font loading and rasterizing library*

## Usage

See this compilable-ish example of how to use fontana to load some glyphs from a .ttf file.

    const std = @import("std");
    const fontana = @import("fontana.zig");

    const font_path = "assets/font_file.ttf";
    const font_size_pixels = 28;

    pub fn main() !void {
        var gpa = std.heap.GeneralPurposeAllocator(.{}){};
        defer _ = gpa.deinit();
        var allocator = gpa.allocator();

        const file_handle = try std.fs.cwd().openFile(font_path, .{ .mode = .read_only });
        defer file_handle.close();

        const file_size = (try file_handle.stat()).size;
        var ttf_buffer = try allocator.alloc(u8, file_size);
        _ = try file_handle.readAll(ttf_buffer);

        const font = try fontana.parseOTF(ttf_buffer);
        const scale = fontana.scaleForPixelHeight(font, font_size_pixels);

        const char_list = "abc";
        for (char_list) |char| {
            const bitmap = try fontana.createGlyphBitmap(allocator, font, scale, char);
            defer allocator.free(bitmap.pixels);
            std.log.info("Loaded bitmap of '{c}' with dimensions: ({d}, {d})", .{
                char,
                bitmap.width,
                bitmap.height,
            });

            //
            // Do something with the image bitmap
            //
        }
    }

## License

MIT