const Task = @import("task.zig").Task;
const Deque = @import("deque.zig").Deque;
const std = @import("std");

pub const Worker = struct {
    const Self = @This();
    const TaskPtr = *TaskType;
    pub const TaskType = Task(Self);

    done: std.atomic.Atomic(bool) = std.atomic.Atomic(bool).init(false),
    wsq: []*Deque(TaskPtr),
    index: usize,

    fn steal(self: Self) ?TaskPtr {
        var index: usize = 0;

        while (index < self.wsq.len) : (index += 1) {
            if (index != self.index) {
                if (self.wsq[index].pop_front()) |task| {
                    return task;
                }
            }
        }

        return null;
    }

    pub fn stop(self: *Self) void {
        self.done.store(true, .Monotonic);
    }

    pub fn work(self: Self) void {
        while (!self.done.load(.Monotonic)) {
            if (!self.wsq[self.index].empty()) {
                if (self.wsq[self.index].pop_back()) |task| {
                    task.call_from(self, self.index);
                    continue;
                }
            }

            if (self.steal()) |task|
                task.call_from(self, self.index);

            //std.atomic.spinLoopHint();
        }
    }

    pub fn join(self: Self, t: TaskPtr) void {
        while (!t.is_done()) {
            if (!self.wsq[self.index].empty()) {
                if (self.wsq[self.index].pop_back()) |task| {
                    task.call_from(self, self.index);
                    continue;
                }
            }

            if (t.get_caller()) |index| {
                if (index != self.index) {
                    while (!self.wsq[index].empty() and !t.is_done()) {
                        if (self.wsq[index].pop_front()) |task| {
                            task.call_from(self, self.index);
                            continue;
                        }
                    }
                }
            }

            if (self.steal()) |task|
                task.call_from(self, self.index);

            //std.atomic.spinLoopHint();
        }
    }

    pub fn spawn(self: Self, task: TaskPtr) void {
        self.wsq[self.index].push_back(task) catch @panic("out of memory (push_back)");
    }

    pub fn run(self: Self, task: TaskPtr) void {
        task.call_from(self, self.index);
    }
};
