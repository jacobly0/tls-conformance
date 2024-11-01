const std = @import("std");
pub fn build(b: *std.Build) void {
    const regen = b.option(bool, "regen", "Regenerate certificates (default true)") orelse true;
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const libressl_dep = b.dependency("libressl", .{
        .target = target,
        .optimize = optimize,
        .@"build-apps" = true,
    });
    const openssl_exe = libressl_dep.artifact("openssl");
    const tester_exe = b.addExecutable(.{
        .name = "tester",
        .root_source_file = b.path("tester.zig"),
        .target = target,
        .optimize = optimize,
    });
    const key_file, const cert_file = cert: {
        const run = b.addRunArtifact(openssl_exe);
        // zig fmt: off
        run.addArgs(&.{
            "req",
            "-x509",
            "-newkey", "rsa:2048",
            "-sha256",
            "-nodes",
            "-subj", "/CN=localhost",
            "-days", "1",
        });
        // zig fmt: on

        run.addArg("-keyout");
        const key_file = run.addOutputFileArg("rsa2048-sha256.key");

        run.addArg("-out");
        const cert_file = run.addOutputFileArg("rsa2048-sha256.cer");

        run.has_side_effects = regen; // expiration date
        b.default_step.dependOn(&run.step);

        run.step.dependOn(libressl_dep.builder.getInstallStep());
        break :cert .{ key_file, cert_file };
    };
    for ([_][]const u8{
        "TLS_AES_128_GCM_SHA256",
        "TLS_AES_256_GCM_SHA384",
        "TLS_CHACHA20_POLY1305_SHA256",
        "ECDHE-RSA-AES128-GCM-SHA256",
        "ECDHE-RSA-AES256-GCM-SHA384",
        "ECDHE-RSA-CHACHA20-POLY1305",
    }) |cipher| {
        const run = b.addRunArtifact(tester_exe);
        run.step.name = cipher;
        run.addArtifactArg(openssl_exe);
        run.addFileArg(key_file);
        run.addFileArg(cert_file);
        run.addArg(cipher);

        b.default_step.dependOn(&run.step);
    }
}
