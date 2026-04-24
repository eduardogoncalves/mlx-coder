// zig/src/queue.zig
// Bounded, blocking token queue used to decouple the Swift inference thread from
// the Zig render loop.
//
// Design
//   • Single contiguous ring buffer — no heap allocation after init.
//   • Mutex + condition variable — no busy-wait, no CPU spin.
//   • push() blocks when the buffer is full (backpressure to Swift).
//   • pop()  returns available bytes without blocking (render loop polls).
//   • A separate "done" flag lets the render loop drain after generation ends.

const std = @import("std");

pub const TokenQueue = struct {
    const CAP = 8192;
    // Classic ring-buffer: one slot is sacrificed to distinguish full from empty
    // (write+1 == read means full; read == write means empty).
    // Effective capacity is therefore CAP-1 = 8191 bytes per push-cycle.

    buf:   [CAP]u8 = undefined,
    write: usize   = 0,
    read:  usize   = 0,
    done:  bool    = false,  // set by Swift's done-callback; read by drain loop

    mutex: std.Thread.Mutex     = .{},
    cond:  std.Thread.Condition = .{},

    // -----------------------------------------------------------------------
    // Writer side (called from Swift callbacks — arbitrary thread)
    // -----------------------------------------------------------------------

    /// Push all bytes in `data` into the ring buffer, blocking if full.
    pub fn push(self: *TokenQueue, data: []const u8) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        for (data) |b| {
            // Block while buffer is full.
            while ((self.write + 1) % CAP == self.read) {
                self.cond.wait(&self.mutex);
            }
            self.buf[self.write] = b;
            self.write = (self.write + 1) % CAP;
        }

        self.cond.signal();
    }

    /// Signal that the generation run has finished.  May be called from any thread.
    pub fn markDone(self: *TokenQueue) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.done = true;
        self.cond.signal();
    }

    // -----------------------------------------------------------------------
    // Reader side (called from the Zig render loop — main thread only)
    // -----------------------------------------------------------------------

    /// Drain up to `out.len` bytes from the ring buffer without blocking.
    /// Returns the number of bytes written into `out`.
    pub fn pop(self: *TokenQueue, out: []u8) usize {
        self.mutex.lock();
        defer self.mutex.unlock();

        var i: usize = 0;
        while (i < out.len and self.read != self.write) {
            out[i] = self.buf[self.read];
            self.read = (self.read + 1) % CAP;
            i += 1;
        }

        // Wake the writer if it was blocked (buffer had space).
        if (i > 0) self.cond.signal();
        return i;
    }

    /// Returns true when no more data will be pushed and the buffer is empty.
    pub fn isExhausted(self: *TokenQueue) bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.done and self.read == self.write;
    }

    /// Reset for reuse between generation runs.
    pub fn reset(self: *TokenQueue) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.write = 0;
        self.read  = 0;
        self.done  = false;
    }

    /// Return the number of bytes currently available for reading.
    pub fn available(self: *TokenQueue) usize {
        self.mutex.lock();
        defer self.mutex.unlock();
        return (self.write + CAP - self.read) % CAP;
    }
};
