const std = @import("std");
pub fn main() !void {
    const stdout = std.io.getStdOut().writer();
    var gpa: std.heap.GeneralPurposeAllocator(.{}) = .{};
    defer _ = gpa.deinit();
    var arena: std.heap.ArenaAllocator = .init(gpa.allocator());
    defer arena.deinit();

    var headers_buf: [1 << 18]u8 = undefined;
    var top_sites_client: std.http.Client = .{ .allocator = arena.allocator() };
    defer top_sites_client.deinit();
    var top_sites_req = try top_sites_client.open(.GET, .{
        .scheme = "https",
        .host = .{ .raw = "raw.githubusercontent.com" },
        .path = .{ .raw = "/Kikobeats/top-sites/refs/heads/master/top-sites.json" },
    }, .{ .keep_alive = false, .server_header_buffer = &headers_buf });
    defer top_sites_req.deinit();
    try top_sites_req.send();
    try top_sites_req.finish();
    try top_sites_req.wait();
    var top_sites_reader = std.json.reader(arena.allocator(), top_sites_req.reader());
    defer top_sites_reader.deinit();
    if (try top_sites_reader.next() != .array_begin) return error.InvalidFormat;
    var site_client: std.http.Client = .{ .allocator = arena.allocator() };
    defer site_client.deinit();
    var total_succeeded: u32 = 0;
    var total: u32 = 0;
    while (try top_sites_reader.peekNextTokenType() != .array_end) {
        const site = try std.json.innerParse(Site, arena.allocator(), &top_sites_reader, .{
            .max_value_len = 1 << 5,
            .allocate = .alloc_always,
        });
        const result: std.http.Client.FetchResult =
            if (std.mem.eql(u8, site.rootDomain, "adobe.com") or
            std.mem.eql(u8, site.rootDomain, "washingtonpost.com") or
            std.mem.eql(u8, site.rootDomain, "disney.com") or
            std.mem.eql(u8, site.rootDomain, "outlook.com") or
            std.mem.eql(u8, site.rootDomain, "businesswire.com"))
            .{ .status = .request_timeout }
        else
            site_client.fetch(.{
                .server_header_buffer = &headers_buf,
                .location = .{ .uri = .{
                    .scheme = "https",
                    .host = .{ .raw = site.rootDomain },
                    .path = .{ .raw = "/" },
                } },
            }) catch .{ .status = .bad_request };
        stdout.print("\x1B[{d}m{s}\x1B[m\n", .{
            @as(u6, if (result.status == .ok) 32 else 31),
            site.rootDomain,
        }) catch {};
        if (result.status == .ok) total_succeeded += 1;
        total += 1;
    }
    if (try top_sites_reader.next() != .array_end or
        try top_sites_reader.next() != .end_of_document) return error.InvalidFormat;
    stdout.print("{d}/{d} succeeded\n", .{ total_succeeded, total }) catch {};
}
const Site = struct {
    rank: u32,
    rootDomain: []const u8,
    linkingRootDomains: u32,
    domainAuthority: u8,
};
