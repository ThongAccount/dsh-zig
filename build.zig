const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const root_module = b.addModule("dsh", .{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    const dsh = b.addExecutable(.{
        .name = "dsh",
        .root_module = root_module,
    });

    const exe_step = b.step("exe", "Build the dsh executable");
    exe_step.dependOn(&dsh.step);

    const run_cmd = b.addRunArtifact(dsh);
    run_cmd.step.dependOn(&dsh.step);

    const run_step = b.step("run", "Run the dsh executable");
    run_step.dependOn(&run_cmd.step);

    const conformance_cmd = b.addRunArtifact(dsh);
    conformance_cmd.step.dependOn(&dsh.step);
    std.Build.Step.Run.addArgs(conformance_cmd, &[_][]const u8{ "conformance" });

    const conformance_step = b.step("conformance", "Run dsh conformance smoke test");
    conformance_step.dependOn(&conformance_cmd.step);

    b.installArtifact(dsh);
}
