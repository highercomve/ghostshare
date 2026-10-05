//! The Quick Share BLE wake-up beacon on Android: Android phones nearby
//! start announcing their Quick Share endpoint over mDNS when they see the
//! 0xFE2C advertisement, so they show up without their receiving screen
//! open. Advertising needs an `AdvertiseCallback` subclass, which JNI can't
//! make, so the work is in GhostShare's Kotlin helper
//! (src/android/QuickShareBeacon.kt, copied into the Gradle project by
//! build.zig); this calls its `start` and `stop`.
//!
//! The helper is an app class: the system class loader a thread attached
//! from native code gets doesn't see it, so it is loaded through the
//! Application's class loader. Failures are logged, never fatal: discovery
//! still finds phones that are already announcing.

const std = @import("std");
const oriel = @import("oriel");
const jni = oriel.android.jni;

const log = std.log.scoped(.ghostshare);

/// Start advertising (the helper waits for the permission and the adapter).
pub fn start() void {
    withEnv(startWith);
}

/// Stop advertising.
pub fn stop() void {
    withEnv(stopWith);
}

fn startWith(env: *jni.Env) void {
    call(env, "start");
}

fn stopWith(env: *jni.Env) void {
    call(env, "stop");
}

/// Run `f` with a JNI env for this thread, attaching it for the call if needed.
fn withEnv(comptime f: fn (*jni.Env) void) void {
    const vm = oriel.android.runtime.vm orelse {
        log.warn("BLE beacon: no Java VM", .{});
        return;
    };
    if (vm.getEnv()) |env| return f(env);
    var env: ?*jni.Env = null;
    if (vm.functions.AttachCurrentThread(vm, &env, null) != jni.JNI_OK or env == null) {
        log.warn("BLE beacon: could not attach to the Java VM", .{});
        return;
    }
    defer _ = vm.functions.DetachCurrentThread(vm);
    f(env.?);
}

const NewStringUtf = *const fn (*jni.Env, [*:0]const u8) callconv(.c) jni.jobject;

fn newString(env: *jni.Env, text: [*:0]const u8) jni.jobject {
    const new_string: NewStringUtf = @ptrCast(@alignCast(env.functions.NewStringUTF orelse return null));
    return new_string(env, text);
}

fn call(env: *jni.Env, comptime method: [:0]const u8) void {
    const f = env.functions;
    if (f.PushLocalFrame(env, 16) != 0) {
        _ = env.clearException();
        return;
    }
    defer _ = f.PopLocalFrame(env, null);
    callIn(env, method) catch |err| {
        _ = env.clearException();
        log.warn("BLE beacon: {s} failed ({s})", .{ method, @errorName(err) });
    };
}

fn callIn(env: *jni.Env, comptime method: [:0]const u8) !void {
    const f = env.functions;
    const helper = try helperClass(env);
    const id = f.GetStaticMethodID(env, helper, method, "()V") orelse return error.NoMethod;
    f.CallStaticVoidMethodA(env, helper, id, null);
    if (env.clearException()) return error.Threw;
}

/// dev.ghostshare.QuickShareBeacon, through the Application's class loader.
fn helperClass(env: *jni.Env) !jni.jclass {
    const f = env.functions;
    const activity_thread = f.FindClass(env, "android/app/ActivityThread") orelse return error.NoActivityThread;
    const current_application = f.GetStaticMethodID(env, activity_thread, "currentApplication", "()Landroid/app/Application;") orelse return error.NoCurrentApplication;
    const app = f.CallStaticObjectMethodA(env, activity_thread, current_application, null);
    if (env.clearException() or app == null) return error.NoApplication;

    const context = f.FindClass(env, "android/content/Context") orelse return error.NoContext;
    const get_class_loader = f.GetMethodID(env, context, "getClassLoader", "()Ljava/lang/ClassLoader;") orelse return error.NoGetClassLoader;
    const loader = f.CallObjectMethodA(env, app, get_class_loader, null);
    if (env.clearException() or loader == null) return error.NoClassLoader;

    const class_loader = f.FindClass(env, "java/lang/ClassLoader") orelse return error.NoClassLoaderClass;
    const load_class = f.GetMethodID(env, class_loader, "loadClass", "(Ljava/lang/String;)Ljava/lang/Class;") orelse return error.NoLoadClass;
    const name = newString(env, "dev.ghostshare.QuickShareBeacon") orelse return error.OutOfMemory;
    const helper = f.CallObjectMethodA(env, loader, load_class, &[_]jni.jvalue{.{ .l = name }});
    if (env.clearException() or helper == null) return error.NoHelperClass;
    return helper;
}
