//! Prints the structure of a KFX book without its text: entity types with counts, and
//! the field layout of one type. Strings show as their length only.
//! Usage: kfxshape <book.kfx> [type [max entities]]
const std = @import("std");
const core = @import("core");
const ion = core.ion;

fn print(comptime f: []const u8, args: anytype) void {
    std.debug.print(f, args);
}

fn shape(v: ion.Value, depth: usize, max_items: usize) void {
    const pad = "                                                            ";
    const indent = pad[0..@min(depth * 2, pad.len)];
    switch (v.kind) {
        .struct_ => {
            print("{{\n", .{});
            var it = v.fields();
            while (it.next()) |f| {
                print("{s}  ${d}: ", .{ indent, f.key });
                shape(f.value, depth + 1, max_items);
            }
            print("{s}}}\n", .{indent});
        },
        .list, .sexp => {
            var it = v.items();
            var n: usize = 0;
            var count: usize = 0;
            var counter = v.items();
            while (counter.next()) |_| count += 1;
            print("[{d} items]\n", .{count});
            while (it.next()) |item| : (n += 1) {
                if (n >= max_items) break;
                print("{s}  - ", .{indent});
                shape(item, depth + 1, max_items);
            }
        },
        .string => print("string({d})\n", .{v.body.len}),
        .symbol => print("${d}\n", .{v.int}),
        .uint => print("{d}\n", .{v.int}),
        else => print("{s}\n", .{@tagName(v.kind)}),
    }
}

pub fn main(init: std.process.Init.Minimal) !void {
    const argv = init.args.vector;
    if (argv.len < 2) return error.Usage;
    const data = try core.file.map(argv[1]);
    var counts: [2048]u32 = @splat(0);
    var it = try core.kfx.entities(data);
    const want: ?u32 = if (argv.len > 2) try std.fmt.parseInt(u32, std.mem.sliceTo(argv[2], 0), 10) else null;
    const max: usize = if (argv.len > 3) try std.fmt.parseInt(usize, std.mem.sliceTo(argv[3], 0), 10) else 2;
    var shown: usize = 0;
    while (it.next()) |e| {
        if (e.kind < counts.len) counts[e.kind] += 1;
        if (want != null and e.kind == want.? and shown < max) {
            shown += 1;
            print("entity ${d} type ${d}: ", .{ e.id, e.kind });
            if (core.kfx.entityValue(e.raw)) |v| shape(v, 0, 4) else print("(not ion, {d} bytes)\n", .{e.raw.len});
        }
    }
    if (want == null) {
        for (counts, 0..) |n, k| {
            if (n > 0) print("type ${d}: {d}\n", .{ k, n });
        }
    }
}
