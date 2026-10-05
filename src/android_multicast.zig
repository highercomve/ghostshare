//! Android's Wi-Fi stack drops multicast frames that aren't addressed to the
//! device unless an app holds a `WifiManager.MulticastLock`. Quick Share
//! discovery is mDNS: queries go out to 224.0.0.251:5353 and the answers
//! (mdns-sd only sends and receives multicast) come back to that group, so
//! without the lock the device list stays empty. Acquiring the lock needs
//! `android.permission.CHANGE_WIFI_MULTICAST_STATE` in the manifest (a normal
//! permission: granted at install, no prompt), which Oriel emits for the
//! `local_network` permission GhostShare declares in build.zig.

const std = @import("std");
const oriel = @import("oriel");
const jni = oriel.android.jni;
const android_beacon = @import("android_beacon.zig");

const log = std.log.scoped(.ghostshare);

/// A global reference to the held `WifiManager.MulticastLock` (fallback JNI path).
var held: jni.jobject = null;

/// Hold the multicast lock until `release` (or the process ends: the system
/// drops a dead process's locks). Failures are logged, never fatal: manual
/// addresses still work without discovery.
pub fn acquire() void {
    // 1. Acquire via Kotlin QuickShareBeacon helper (runs on main looper with Context)
    android_beacon.callNamed("acquireMulticastLock");
    // 2. Also acquire directly via JNI as fallback
    withEnv(acquireWith);
}

pub fn release() void {
    android_beacon.callNamed("releaseMulticastLock");
    if (held == null) return;
    withEnv(releaseWith);
}

/// Run `f` with a JNI env for this thread, attaching it for the call if needed.
fn withEnv(comptime f: fn (*jni.Env) void) void {
    const vm = oriel.android.runtime.vm orelse {
        log.warn("multicast lock: no Java VM", .{});
        return;
    };
    if (vm.getEnv()) |env| return f(env);
    var env: ?*jni.Env = null;
    if (vm.functions.AttachCurrentThread(vm, &env, null) != jni.JNI_OK or env == null) {
        log.warn("multicast lock: could not attach to the Java VM", .{});
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

fn acquireWith(env: *jni.Env) void {
    if (held != null) return;
    const f = env.functions;
    if (f.PushLocalFrame(env, 16) != 0) {
        _ = env.clearException();
        return;
    }
    defer _ = f.PopLocalFrame(env, null);
    acquireIn(env) catch |err| {
        _ = env.clearException();
        log.warn("multicast lock JNI fallback not acquired ({s})", .{@errorName(err)});
    };
}

fn acquireIn(env: *jni.Env) !void {
    const f = env.functions;
    // The Application: ActivityThread.currentApplication()
    const activity_thread = f.FindClass(env, "android/app/ActivityThread") orelse return error.NoActivityThread;
    const current_application = f.GetStaticMethodID(env, activity_thread, "currentApplication", "()Landroid/app/Application;") orelse return error.NoCurrentApplication;
    const app = f.CallStaticObjectMethodA(env, activity_thread, current_application, null);
    if (env.clearException() or app == null) return error.NoApplication;

    const context = f.FindClass(env, "android/content/Context") orelse return error.NoContext;
    const get_system_service = f.GetMethodID(env, context, "getSystemService", "(Ljava/lang/String;)Ljava/lang/Object;") orelse return error.NoGetSystemService;
    const wifi_name = newString(env, "wifi") orelse return error.OutOfMemory;
    const wifi = f.CallObjectMethodA(env, app, get_system_service, &[_]jni.jvalue{.{ .l = wifi_name }});
    if (env.clearException() or wifi == null) return error.NoWifiManager;

    const wifi_manager = f.FindClass(env, "android/net/wifi/WifiManager") orelse return error.NoWifiManagerClass;
    const create_lock = f.GetMethodID(env, wifi_manager, "createMulticastLock", "(Ljava/lang/String;)Landroid/net/wifi/WifiManager$MulticastLock;") orelse return error.NoCreateMulticastLock;
    const tag = newString(env, "GhostShare mDNS") orelse return error.OutOfMemory;
    const lock = f.CallObjectMethodA(env, wifi, create_lock, &[_]jni.jvalue{.{ .l = tag }});
    if (env.clearException() or lock == null) return error.CreateMulticastLockFailed;

    const lock_class = f.GetObjectClass(env, lock) orelse return error.NoMulticastLockClass;
    const set_counted = f.GetMethodID(env, lock_class, "setReferenceCounted", "(Z)V") orelse return error.NoSetReferenceCounted;
    f.CallVoidMethodA(env, lock, set_counted, &[_]jni.jvalue{.{ .z = 0 }});
    if (env.clearException()) return error.SetReferenceCountedFailed;
    const acquire_method = f.GetMethodID(env, lock_class, "acquire", "()V") orelse return error.NoAcquire;
    f.CallVoidMethodA(env, lock, acquire_method, null);
    if (env.clearException()) return error.AcquireFailed;

    held = f.NewGlobalRef(env, lock);
    log.info("multicast lock acquired for mDNS discovery (direct JNI)", .{});
}

fn releaseWith(env: *jni.Env) void {
    const lock = held orelse return;
    held = null;
    const f = env.functions;
    defer f.DeleteGlobalRef(env, lock);
    const lock_class = f.GetObjectClass(env, lock) orelse return;
    defer f.DeleteLocalRef(env, lock_class);
    const release_method = f.GetMethodID(env, lock_class, "release", "()V") orelse {
        _ = env.clearException();
        return;
    };
    f.CallVoidMethodA(env, lock, release_method, null);
    _ = env.clearException();
}
