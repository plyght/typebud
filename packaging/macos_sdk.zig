//! The macOS SDK version a typebud binary declares.
//!
//! AppKit picks its look from the SDK an executable was linked against (the `sdk` field
//! of LC_BUILD_VERSION), not from the OS it runs on: a binary that declares an SDK older
//! than 26 gets the pre-26 controls, sidebar and window chrome even on macOS 26 and later.
//! Zig writes the SDK version it found on the build machine (15.x with Xcode 16), so
//! after linking this rewrites LC_BUILD_VERSION with `vtool` to declare that SDK or 26.0,
//! whichever is newer, keeping the deployment minimum (12.0), and ad-hoc signs the result
//! again (vtool invalidates the linker's signature; release builds re-sign the bundle).
//! Each architecture is patched before `lipo`.

const std = @import("std");

/// LSMinimumSystemVersion in Info.plist and the `minos` every macOS build declares.
pub const minimum: std.SemanticVersion = .{ .major = 12, .minor = 0, .patch = 0 };

/// The first SDK that opts AppKit into the macOS 26 design (Liquid Glass).
pub const design_sdk = "26.0";

const script =
    \\set -eu
    \\in=$1 out=$2 minos=$3 floor=$4
    \\sdk=$(xcrun --sdk macosx --show-sdk-version 2>/dev/null || true)
    \\major=${sdk%%.*}
    \\case "$major" in ''|*[!0-9]*) sdk=$floor; major=${floor%%.*} ;; esac
    \\if [ "$major" -lt "${floor%%.*}" ]; then sdk=$floor; fi
    \\if ! vtool=$(xcrun -f vtool 2>/dev/null); then
    \\  echo "warning: vtool not found (install the Xcode command line tools); typebud keeps the SDK version zig wrote and the pre-26 AppKit look" >&2
    \\  cp "$in" "$out"
    \\  exit 0
    \\fi
    \\"$vtool" -set-build-version macos "$minos" "$sdk" -replace -output "$out" "$in"
    \\chmod 755 "$out"
    \\codesign --force --sign - "$out"
    \\
;

/// A copy of `exe` that declares minos = its target's minimum and sdk >= 26.0.
pub fn declareSdk(b: *std.Build, exe: *std.Build.Step.Compile) std.Build.LazyPath {
    const target = exe.rootModuleTarget();
    const min = target.os.version_range.semver.min;
    const run = b.addSystemCommand(&.{ "/bin/sh", "-c", script, "macos-sdk" });
    run.setName(b.fmt("declare macOS {s} SDK ({s})", .{ design_sdk, @tagName(target.cpu.arch) }));
    run.addArtifactArg(exe);
    const out = run.addOutputFileArg("typebud");
    run.addArg(b.fmt("{d}.{d}", .{ min.major, min.minor }));
    run.addArg(design_sdk);
    return out;
}
