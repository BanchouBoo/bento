const std = @import("std");

pub fn getBuildMode(b: *std.build.Builder, default: std.builtin.Mode) !std.builtin.Mode {
    const description = try std.mem.join(b.allocator, "", &.{
        "What mode the project should build in (default: ", @tagName(default), ")",
    });
    const mode = b.option(std.builtin.Mode, "mode", description) orelse default;

    return mode;
}

pub fn build(b: *std.build.Builder) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = try getBuildMode(b, .ReleaseSmall);

    const include_x11_backend = b.option(bool, "x11-backend", "Compile bento with X11 support") orelse true;
    const include_wayland_backend = b.option(bool, "wayland-backend", "Compile bento with Wayland support") orelse true;

    const build_options = b.addOptions();
    build_options.addOption(bool, "x11_backend", include_x11_backend);
    build_options.addOption(bool, "wayland_backend", include_wayland_backend);

    const bento = b.addExecutable(.{
        .name = "bento",
        .root_source_file = .{ .path = "src/main.zig" },
        .optimize = optimize,
        .target = target,
    });
    bento.addOptions("build_options", build_options);
    bento.addPackagePath("accord", "pkg/accord/accord.zig");
    bento.install();

    bento.linkLibC();
    if (include_x11_backend) {
        bento.linkSystemLibrary("xcb");
        bento.linkSystemLibrary("xcb-shape");
        bento.linkSystemLibrary("xcb-cursor");
    }

    if (include_wayland_backend) {
        bento.linkSystemLibrary("wayland-client");
        bento.linkSystemLibrary("wayland-protocols");
        bento.linkSystemLibrary("wayland-cursor");
        bento.linkSystemLibrary("xkbcommon");

        const project_protocol_dir = try std.fs.cwd().openIterableDir("protocol", .{});
        const project_protocol_path = try project_protocol_dir.dir.realpathAlloc(b.allocator, ".");

        bento.addIncludePath(project_protocol_path);

        const system_protocol_path = std.mem.trim(
            u8,
            try b.exec(&.{ "pkg-config", "--variable=pkgdatadir", "wayland-protocols" }),
            "\n",
        );
        const wayland_scanner = std.mem.trim(
            u8,
            try b.exec(&.{ "pkg-config", "--variable=wayland_scanner", "wayland-scanner" }),
            "\n",
        );

        bento.addCSourceFile(try runWaylandScanner(
            b,
            wayland_scanner,
            system_protocol_path,
            "stable/xdg-shell/xdg-shell",
            project_protocol_path,
        ), &.{});
        bento.addCSourceFile(try runWaylandScanner(
            b,
            wayland_scanner,
            system_protocol_path,
            "unstable/xdg-output/xdg-output-unstable-v1",
            project_protocol_path,
        ), &.{});

        var protocol_iterator = project_protocol_dir.iterate();
        while (try protocol_iterator.next()) |item| {
            if (item.kind == .File and std.mem.endsWith(u8, item.name, ".xml")) {
                const protocol_name = item.name[0 .. item.name.len - 4];
                bento.addCSourceFile(try runWaylandScanner(
                    b,
                    wayland_scanner,
                    project_protocol_path,
                    protocol_name,
                    project_protocol_path,
                ), &.{});
            }
        }
    }

    const run_cmd = bento.run();
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run bento");
    run_step.dependOn(&run_cmd.step);
}

fn runWaylandScanner(
    b: *std.build.Builder,
    scanner_path: []const u8,
    input_base_path: []const u8,
    name: []const u8,
    output_base_path: []const u8,
) ![]const u8 {
    var name_iterator = std.mem.split(u8, name, "/");
    var base_name = name;
    while (name_iterator.next()) |part| base_name = part;

    const xml_name = try std.mem.concat(b.allocator, u8, &.{ name, ".xml" });
    const client_header_name = try std.mem.concat(b.allocator, u8, &.{ base_name, "-client-protocol.h" });
    const glue_code_name = try std.mem.concat(b.allocator, u8, &.{ base_name, "-protocol.c" });

    const xml_path = try std.mem.join(b.allocator, "/", &.{ input_base_path, xml_name });
    const client_header_path = try std.mem.join(b.allocator, "/", &.{ output_base_path, client_header_name });
    const glue_code_path = try std.mem.join(b.allocator, "/", &.{ output_base_path, glue_code_name });

    _ = try b.exec(&.{ scanner_path, "client-header", xml_path, client_header_path });
    _ = try b.exec(&.{ scanner_path, "private-code", xml_path, glue_code_path });

    return glue_code_path;
}
