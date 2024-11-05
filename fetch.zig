const std = @import("std");
const http = std.http;

pub fn main() !void {
    var arena_instance = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    const arena = arena_instance.allocator();
    const gpa = arena;

    const args = try std.process.argsAlloc(arena);

    var client: http.Client = .{
        .allocator = gpa,
    };
    defer client.deinit();

    const uri = try std.Uri.parse(args[1]);
    var header_buf: [1 << 18]u8 = undefined;
    var req = try client.open(.GET, uri, .{
        .keep_alive = false,
        .redirect_behavior = @enumFromInt(5),
        .server_header_buffer = &header_buf,
    });
    defer req.deinit();
    try req.send();
    try req.finish();
    try req.wait();

    var bw = std.io.bufferedWriter(std.io.getStdOut().writer());
    const w = bw.writer();

    var total: usize = 0;
    var buf: [5000]u8 = undefined;
    while (true) {
        const amt = try req.readAll(&buf);
        total += amt;
        if (amt == 0) break;
        std.debug.print("got {d} bytes (total {d})\n", .{ amt, total });
        try w.writeAll(buf[0..amt]);
    }

    try bw.flush();
}
