const std = @import("std");
const builtin = @import("builtin");

fn createEmsdkStep(b: *std.Build, emsdk: *std.Build.Dependency) *std.Build.Step.Run {
    if (builtin.os.tag == .windows) {
        return b.addSystemCommand(&.{emsdk.path("emsdk.bat").getPath(b)});
    } else {
        return b.addSystemCommand(&.{emsdk.path("emsdk").getPath(b)});
    }
}

fn emSdkSetupStep(b: *std.Build, emsdk: *std.Build.Dependency) !?*std.Build.Step.Run {
    const dot_emsc_path = emsdk.path(".emscripten").getPath(b);
    const dot_emsc_exists = !std.meta.isError(std.fs.accessAbsolute(dot_emsc_path, .{}));

    if (!dot_emsc_exists) {
        const emsdk_install = createEmsdkStep(b, emsdk);
        emsdk_install.addArgs(&.{ "install", "latest" });
        const emsdk_activate = createEmsdkStep(b, emsdk);
        emsdk_activate.addArgs(&.{ "activate", "latest" });
        emsdk_activate.step.dependOn(&emsdk_install.step);
        return emsdk_activate;
    } else {
        return null;
    }
}
pub fn build(b: *std.Build) void {
    var target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    if (target.result.os.tag == .emscripten) {
        target = b.resolveTargetQuery(.{
            .cpu_arch = .wasm32,
            .cpu_model = .{ .explicit = &std.Target.wasm.cpu.mvp },
            .cpu_features_add = std.Target.wasm.featureSet(&.{
                .atomics,
                .bulk_memory,
            }),
            .os_tag = .emscripten,
        });
    }

    const upstream = b.dependency("upstream", .{});

    // Options
    const build_shared = b.option(bool, "shared", "Build shared library") orelse false;
    const build_testing = b.option(bool, "testing", "Build tests") orelse false;
    const build_examples = b.option(bool, "examples", "Build example applications") orelse false;
    const enable_logging = b.option(bool, "logging", "Enable logging") orelse true;
    const enable_debug_logging = b.option(bool, "debug-logging", "Enable debug logging") orelse false;
    const enable_udev = b.option(bool, "udev", "Enable udev backend for device enumeration (Linux only)") orelse true;

    // Version information - read from version.h
    const version_h_path = upstream.path("libusb/version.h").getPath(b);
    const version_h_content = std.fs.cwd().readFileAlloc(b.allocator, version_h_path, 1024 * 1024) catch |err| {
        std.log.err("Failed to read version.h: {}", .{err});
        std.process.exit(1);
    };

    const version_major = extractVersionNumber(version_h_content, "LIBUSB_MAJOR") orelse "1";
    const version_minor = extractVersionNumber(version_h_content, "LIBUSB_MINOR") orelse "0";
    const version_micro = extractVersionNumber(version_h_content, "LIBUSB_MICRO") orelse "0";

    const lib = b.addLibrary(.{
        .linkage = if (build_shared) .dynamic else .static,
        .name = "usb-1.0",
        .version = .{
            .major = std.fmt.parseInt(u32, version_major, 10) catch 1,
            .minor = std.fmt.parseInt(u32, version_minor, 10) catch 0,
            .patch = std.fmt.parseInt(u32, version_micro, 10) catch 0,
        },
        .root_module = b.createModule(.{
            .target = target,
            .optimize = optimize,
        }),
    });

    // Generate config.h
    const config_h = conf: {
        const is_posix =
            target.result.isDarwinLibC() or
            target.result.os.tag == .linux or
            target.result.os.tag == .openbsd or
            target.result.os.tag == .emscripten;
        const config = b.addConfigHeader(.{ .style = .{
            .cmake = b.path("config.h.in"),
        } }, .{
            .HAVE_CLOCK_GETTIME = define_from_bool(!(target.result.os.tag == .windows)),
            .HAVE_PTHREAD_CONDATTR_SETCLOCK = null,
            .HAVE_PTHREAD_SETNAME_NP = null,
            .HAVE_PTHREAD_THREADID_NP = null,
            .HAVE_EVENTFD = null,
            .HAVE_PIPE2 = null,
            .HAVE_SYSLOG = define_from_bool(is_posix),
            .HAVE_ASM_TYPES_H = null,
            .HAVE_STRING_H = 1,
            .HAVE_SYS_TIME_H = 1,
            .HAVE_TIMERFD = null,
            .HAVE_NFDS_T = null,
            .HAVE_STRUCT_TIMESPEC = 1,
            .DEFAULT_VISIBILITY = .@"__attribute__ ((visibility (\"default\")))",
            .PLATFORM_WINDOWS = define_from_bool(target.result.os.tag == .windows),
            .PLATFORM_POSIX = define_from_bool(is_posix),
            .ENABLE_LOGGING = define_from_bool(enable_logging),
            .ENABLE_DEBUG_LOGGING = define_from_bool(enable_debug_logging),
            ._GNU_SOURCE = 1,
        });
        break :conf config;
    };
    lib.addConfigHeader(config_h);
    //lib.addIncludePath(b.path("config.h"));
    // Common sources - make sure to include strerror.c which has logging functions
    const common_sources = &.{
        "core.c",
        "descriptor.c",
        "hotplug.c",
        "io.c",
        "strerror.c",
        "sync.c",
    };

    lib.addCSourceFiles(.{
        .files = common_sources,
        .flags = &.{
            "-std=c99",
        },
        .language = .c,
        .root = upstream.path("libusb"),
    });

    // Include directories
    lib.addIncludePath(upstream.path("libusb"));
    lib.addIncludePath(upstream.path("libusb/os"));

    // Platform-specific sources and libraries
    switch (target.result.os.tag) {
        .windows => {
            const windows_sources = &.{
                "os/events_windows.c",
                "os/threads_windows.c",
                "os/windows_common.c",
                "os/windows_usbdk.c",
                "os/windows_winusb.c",
            };

            lib.addCSourceFiles(.{
                .files = windows_sources,
                .flags = &.{},
                .root = upstream.path("libusb"),
            });

            if (build_shared) {
                // Add .def file for shared library exports
                // Note: Zig handles this differently than CMake
                lib.root_module.addCMacro("LIBUSB_DLL", "1");
            }
            lib.linkLibC();

            //lib.linkSystemLibrary("windowsapp");

            if (target.result.abi == .msvc) {
                lib.root_module.addCMacro("_CRT_SECURE_NO_WARNINGS", "1");
            }
        },
        .linux => {
            const posix_sources = &.{
                "os/events_posix.c",
                "os/threads_posix.c",
                "os/linux_usbfs.c",
            };

            lib.addCSourceFiles(.{
                .files = posix_sources,
                .flags = &.{"-std=c99"},
                .root = upstream.path("libusb"),
            });

            if (enable_udev) {
                lib.addCSourceFile(.{
                    .file = upstream.path("libusb/os/linux_udev.c"),
                    .flags = &.{"-std=c99"},
                });
                lib.linkSystemLibrary("udev");
                lib.linkSystemLibrary("libudev");

                lib.root_module.addCMacro("HAVE_LIBUDEV", "1");
            } else {
                lib.addCSourceFile(.{
                    .file = upstream.path("libusb/os/linux_netlink.c"),
                    .flags = &.{"-std=c99"},
                });
            }

            lib.linkLibC();
            lib.linkSystemLibrary("pthread");
        },
        .macos, .ios, .watchos, .tvos => {
            const posix_sources = &.{
                "os/events_posix.c",
                "os/threads_posix.c",
                "os/darwin_usb.c",
            };

            lib.addCSourceFiles(.{
                .files = posix_sources,
                .flags = &.{},
                .root = upstream.path("libusb"),
            });

            lib.linkFramework("Foundation");
            lib.linkFramework("IOKit");
            lib.linkFramework("Security");
        },
        .netbsd => {
            const posix_sources = &.{
                "os/events_posix.c",
                "os/threads_posix.c",
                "os/netbsd_usb.c",
            };

            lib.addCSourceFiles(.{
                .files = posix_sources,
                .flags = &.{},
                .root = upstream.path("libusb"),
            });

            lib.linkLibC();
        },
        .openbsd => {
            const posix_sources = &.{
                "os/events_posix.c",
                "os/threads_posix.c",
                "os/openbsd_usb.c",
            };

            lib.addCSourceFiles(.{
                .files = posix_sources,
                .flags = &.{},
                .root = upstream.path("libusb"),
            });

            lib.linkLibC();
        },
        .emscripten => {
            lib.root_module.addCMacro("__EMSCRIPTEN__", "1");
            lib.root_module.addCMacro("HAVE_EMSCRIPTEN_API", "1");
            lib.root_module.addCMacro("__EMSCRIPTEN_ATOMICS__", "1");
            lib.root_module.addCMacro("_LIBCPP_VERSION", "1"); // Important for libc++ headers
            lib.root_module.addCMacro("_REENTRANT", "");
            // Include emscripten for cross compilation
            if (b.lazyDependency("emsdk", .{})) |dep| {
                if (try emSdkSetupStep(b, dep)) |emSdkStep| {
                    lib.step.dependOn(&emSdkStep.step);
                }
                lib.addIncludePath(dep.path("upstream/emscripten/cache/sysroot/include/c++/v1"));
                lib.addIncludePath(dep.path("upstream/emscripten/cache/sysroot/include/compat"));
                lib.addIncludePath(dep.path("upstream/emscripten/cache/sysroot/include"));
            }
            const posix_sources = &.{
                "os/events_posix.c",
                "os/threads_posix.c",
            };

            lib.addCSourceFiles(.{
                .files = posix_sources,
                .flags = &.{},
                .language = .c,
                .root = upstream.path("libusb"),
            });
            lib.addCSourceFile(.{
                .file = upstream.path("libusb/os/emscripten_webusb.cpp"),
                .flags = &.{
                    "-std=gnu++20",
                    "-w",
                },
                .language = .cpp,
            });

            //lib.linkSystemLibrary("pthread");
        },
        else => {
            std.log.err("Unsupported target platform: {}", .{target.result.os.tag});
            std.process.exit(1);
        },
    }

    // Install library and headers
    b.installArtifact(lib);
    lib.installHeader(upstream.path("libusb/libusb.h"), "libusb.h");

    // Tests
    if (build_testing) {}

    // Examples
    if (build_examples) {
        // Add example executables here
        const example = b.addExecutable(.{
            .name = "listdevs",
            .root_module = b.createModule(.{
                .target = target,
                .optimize = optimize,
            }),
        });
        example.addCSourceFile(.{
            .file = upstream.path("examples/listdevs.c"),
            .language = .c,
        });
        example.linkLibrary(lib);
        example.linkLibC();
        b.installArtifact(example);
    }
}
fn define_from_bool(val: bool) ?u1 {
    return if (val) 1 else null;
}
fn generateConfigH(b: *std.Build, target: std.Build.ResolvedTarget) *std.Build.Step.ConfigHeader {
    const is_posix =
        target.result.isDarwinLibC() or
        target.result.os.tag == .linux or
        target.result.os.tag == .openbsd or
        target.result.os.tag == .emscripten;
    const config = b.addConfigHeader(.{ .style = .{
        .cmake = b.path("config.h.in"),
    } }, .{
        .HAVE_CLOCK_GETTIME = define_from_bool(!(target.result.os.tag == .windows)),
        .HAVE_PTHREAD_CONDATTR_SETCLOCK = null,
        .HAVE_PTHREAD_SETNAME_NP = null,
        .HAVE_PTHREAD_THREADID_NP = null,
        .HAVE_EVENTFD = null,
        .HAVE_PIPE2 = null,
        .HAVE_SYSLOG = define_from_bool(is_posix),
        .HAVE_ASM_TYPES_H = null,
        .HAVE_STRING_H = 1,
        .HAVE_SYS_TIME_H = 1,
        .HAVE_TIMERFD = null,
        .HAVE_NFDS_T = null,
        .HAVE_STRUCT_TIMESPEC = 1,
        .DEFAULT_VISIBILITY = .@"__attribute__ ((visibility (\"default\")))",
        .PLATFORM_WINDOWS = define_from_bool(target.result.os.tag == .windows),
        .PLATFORM_POSIX = define_from_bool(is_posix),
        .ENABLE_LOGGING = 1,
        .ENABLE_DEBUG_LOGGING = null,
        ._GNU_SOURCE = 1,
    });

    return config;
}
fn generateConfigH2(b: *std.Build, target: std.Build.ResolvedTarget) *std.Build.Step.ConfigHeader {
    _ = target;
    const config = b.addConfigHeader(.{ .style = .{
        .cmake = b.path("config.h.in"),
    } }, .{
        .DEFAULT_VISIBILITY = "",
        .ENABLE_LOGGING = 1,
        .HAVE_CLOCK_GETTIME = 1,
        .HAVE_PIPE2 = 1,
        .HAVE_PTHREAD_CONDATTR_SETCLOCK = 1,
        .HAVE_STRING_H = 1,
        .HAVE_STRUCT_TIMESPEC = 1,
        .HAVE_SYSLOG = 1,
        .HAVE_SYS_TIME_H = 1,
        .PLATFORM_POSIX = 1,
        ._GNU_SOURCE = 1,
    });

    return config;
}
fn extractVersionNumber(content: []const u8, define_name: []const u8) ?[]const u8 {
    const pattern = std.fmt.allocPrint(std.heap.page_allocator, "#define {s} ", .{define_name}) catch return null;
    defer std.heap.page_allocator.free(pattern);

    if (std.mem.indexOf(u8, content, pattern)) |start| {
        const line_start = start + pattern.len;
        if (std.mem.indexOfScalar(u8, content[line_start..], '\n')) |line_end| {
            const version_str = std.mem.trim(u8, content[line_start .. line_start + line_end], " \t\r\n");
            return std.heap.page_allocator.dupe(u8, version_str) catch null;
        }
    }
    return null;
}
