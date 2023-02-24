const std = @import("std");

pub fn Task(comptime args: type) type {
    return struct {
        _data: *u64,
        _call: *const fn (*u64, args) void,
        _done: std.atomic.Atomic(bool) = std.atomic.Atomic(bool).init(false),
        _worker: std.atomic.Atomic(isize) = std.atomic.Atomic(isize).init(-1),

        const Self = @This();

        pub fn call_from(self: *Self, _args: args, worker: usize) void {
            self._worker.store(@intCast(isize, worker), .Monotonic);
            self.call(_args);
        }

        pub fn get_caller(self: *Self) ?usize {
            var n = self._worker.load(.Monotonic);

            if (n < 0)
                return null;

            return @intCast(usize, n);
        }

        pub fn call(self: *Self, _args: args) void {
            var result = self._call(self._data, _args);
            self._done.store(true, .Release);
            return result;
        }

        pub fn from_struct(comptime T: type, value: *align(8) T) Self {
            const data = @ptrCast(*u64, value);

            const transform = struct {
                fn call(_data: *u64, _args: args) void {
                    var ptr = @ptrCast(*align(8) T, _data);
                    ptr.call(_args);
                }
            };

            return Self{ ._data = data, ._call = transform.call };
        }

        pub fn is_done(self: Self) bool {
            return self._done.load(.Acquire);
        }
    };
}

pub fn SaveOutput(comptime str: type, comptime ret: type) type {
    return struct {
        data: str align(8),
        out: ret align(8) = undefined,

        const Self = @This();

        pub fn call(self: *Self, args: anytype) void {
            self.out = self.data.call(args);
        }

        pub fn eval(self: Self) ret {
            return self.out;
        }

        pub fn init(data: str) Self {
            return Self{ .data = data };
        }
    };
}
