const std = @import("std");
pub fn main() !void {
    const stderr = if (false) std.io.getStdErr().writer() else std.io.null_writer;

    var gpa: std.heap.GeneralPurposeAllocator(.{}) = .{};
    defer _ = gpa.deinit();

    var args = try std.process.argsWithAllocator(gpa.allocator());
    defer args.deinit();

    _ = args.skip();
    const openssl_exe = args.next().?;
    const key_path = args.next().?;
    const cert_path = args.next().?;
    const cipher = args.next().?;

    var server_to_detect_an_open_port = try net.bindWithoutListening(
        std.net.Address.initIp6(.{0} ** 16, 0, 0, 0),
        .{ .kernel_backlog = 1, .reuse_address = true },
    );
    defer server_to_detect_an_open_port.deinit();

    var port_buf: [std.fmt.count("{d}", .{std.math.maxInt(u16)})]u8 = undefined;
    const port = server_to_detect_an_open_port.listen_address.getPort();
    const port_str = std.fmt.bufPrint(&port_buf, "{d}", .{port}) catch unreachable;

    // zig fmt: off
    var server: std.process.Child = .init(&.{
        openssl_exe,
        "s_server",
        "-accept", port_str,
        "-naccept", "1",
        "-key", key_path,
        "-cert", cert_path,
        if (std.mem.startsWith(u8, cipher, "TLS_")) "-tls1_3" else "-tls1_2",
        "-cipher", cipher,
        "-www",
    }, gpa.allocator());
    // zig fmt: on
    server.stdout_behavior = .Pipe;
    try server.spawn();
    errdefer _ = server.kill() catch {};

    var stdout_buf: [1 << 7]u8 = undefined;
    var continuation = false;
    while (true) {
        var stdout_fbs = std.io.fixedBufferStream(&stdout_buf);
        server.stdout.?.reader().streamUntilDelimiter(stdout_fbs.writer(), '\n', stdout_buf.len) catch |err| switch (err) {
            error.NoSpaceLeft => unreachable,
            error.StreamTooLong => {
                stderr.writeAll(stdout_fbs.getWritten()) catch {};
                continuation = true;
                continue;
            },
            error.EndOfStream => std.process.exit(1),
            else => |e| return e,
        };
        const line = stdout_fbs.getWritten();
        stderr.print("{s}\n", .{line}) catch {};
        if (!continuation and std.mem.eql(u8, line, "ACCEPT")) break;
        continuation = false;
    }

    var client: std.http.Client = .{
        .allocator = gpa.allocator(),
        .next_https_rescan_certs = false,
    };
    defer client.deinit();
    try client.ca_bundle.addCertsFromFilePath(gpa.allocator(), std.fs.cwd(), cert_path);
    var response_headers: [1 << 14]u8 = undefined;
    var response_buf: [1 << 14]u8 = undefined;
    var response: std.ArrayListUnmanaged(u8) = .initBuffer(&response_buf);
    const result = while (true) break client.fetch(.{
        .server_header_buffer = &response_headers,
        .redirect_behavior = .not_allowed,
        .response_storage = .{ .static = &response },
        .location = .{ .uri = .{
            .scheme = "https",
            .host = .{ .raw = "localhost" },
            .port = port,
            .path = .{ .raw = "/" },
        } },
    }) catch |err| switch (err) {
        error.ConnectionRefused => continue, // race condition
        else => |e| return e,
    };
    if (result.status != .ok) {
        std.debug.print("result = {}\n", .{result});
        std.process.exit(2);
    }

    stderr.writeAll(response.items) catch {};
    var line_it = std.mem.tokenizeScalar(u8, response.items, '\n');
    while (line_it.next()) |line| {
        var tok_it = std.mem.tokenizeScalar(u8, line, ' ');
        if (!std.mem.eql(u8, tok_it.next() orelse continue, "Cipher")) continue;
        if (!std.mem.eql(u8, tok_it.next() orelse continue, ":")) continue;
        if (!std.mem.eql(u8, tok_it.next() orelse continue, cipher)) continue;
        if (tok_it.next() == null) break;
    } else std.process.exit(3);

    _ = try server.wait();
}

const net = struct {
    const posix = std.posix;
    const mem = std.mem;

    const Address = std.net.Address;
    const ListenOptions = std.net.Address.ListenOptions;
    const ListenError = std.net.Address.ListenError;
    const Server = std.net.Server;

    fn bindWithoutListening(address: Address, options: ListenOptions) ListenError!Server {
        const nonblock: u32 = if (options.force_nonblocking) posix.SOCK.NONBLOCK else 0;
        const sock_flags = posix.SOCK.STREAM | posix.SOCK.CLOEXEC | nonblock;
        const proto: u32 = if (address.any.family == posix.AF.UNIX) 0 else posix.IPPROTO.TCP;

        const sockfd = try posix.socket(address.any.family, sock_flags, proto);
        var s: Server = .{
            .listen_address = undefined,
            .stream = .{ .handle = sockfd },
        };
        errdefer s.stream.close();

        if (options.reuse_address or options.reuse_port) {
            try posix.setsockopt(
                sockfd,
                posix.SOL.SOCKET,
                posix.SO.REUSEADDR,
                &mem.toBytes(@as(c_int, 1)),
            );
            if (@hasDecl(posix.SO, "REUSEPORT")) {
                try posix.setsockopt(
                    sockfd,
                    posix.SOL.SOCKET,
                    posix.SO.REUSEPORT,
                    &mem.toBytes(@as(c_int, 1)),
                );
            }
        }

        var socklen = address.getOsSockLen();
        try posix.bind(sockfd, &address.any, socklen);
        if (false) // I said, without listening!
            try posix.listen(sockfd, options.kernel_backlog);
        try posix.getsockname(sockfd, &s.listen_address.any, &socklen);
        return s;
    }
};
