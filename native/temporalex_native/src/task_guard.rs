use rustler::{Atom, Encoder, Env, LocalPid, OwnedEnv};
use tracing::error;

use crate::atoms;

/// Guarantees exactly one message is sent to an Elixir process from a Tokio task.
///
/// On normal completion: call `complete()` to send a success message.
/// On panic/cancellation: `Drop` sends `{error_tag, {:error, :task_crashed}}`.
///
/// Every spawned Tokio task must create a TaskGuard. This eliminates the
/// failure mode where a panic causes a message to never arrive, leaving
/// the Elixir process hanging forever.
pub struct TaskGuard {
    pid: LocalPid,
    error_tag: Atom,
    completed: bool,
}

impl TaskGuard {
    /// Create a guard that will send `{error_tag, {:error, :task_crashed}}`
    /// to `pid` if the task panics or is cancelled before `complete()` is called.
    pub fn new(pid: LocalPid, error_tag: Atom) -> Self {
        Self {
            pid,
            error_tag,
            completed: false,
        }
    }

    /// Send a success message and disarm the guard.
    /// The `builder` closure constructs the message term to send.
    pub fn complete<F>(mut self, builder: F)
    where
        F: for<'a> FnOnce(Env<'a>) -> rustler::Term<'a>,
    {
        self.completed = true;
        let mut env = OwnedEnv::new();
        if env.send_and_clear(&self.pid, builder).is_err() {
            error!(tag = ?self.error_tag, "TaskGuard complete: target process is dead");
        }
    }
}

impl Drop for TaskGuard {
    fn drop(&mut self) {
        if self.completed {
            return;
        }

        let mut env = OwnedEnv::new();
        let pid = self.pid;
        let tag = self.error_tag;

        if env
            .send_and_clear(&pid, |env| {
                (tag, (atoms::error(), atoms::task_crashed())).encode(env)
            })
            .is_err()
        {
            error!(tag = ?tag, "TaskGuard drop: target process is dead");
        }
    }
}

/// Guard for long-lived poll loop tasks.
///
/// On clean shutdown: call `complete_shutdown()` to send
///   `{:poll_loop_exited, loop_type, :shutdown}`.
/// On panic/cancellation: `Drop` sends
///   `{:poll_loop_exited, loop_type, :crashed}`.
pub struct PollLoopGuard {
    pid: LocalPid,
    loop_type: Atom,
    completed: bool,
}

impl PollLoopGuard {
    /// Create a guard for a poll loop.
    /// `loop_type` is `atoms::workflow()` or `atoms::activity()`.
    pub fn new(pid: LocalPid, loop_type: Atom) -> Self {
        Self {
            pid,
            loop_type,
            completed: false,
        }
    }

    /// Signal clean shutdown and disarm the guard.
    pub fn complete_shutdown(mut self) {
        self.completed = true;
        let mut env = OwnedEnv::new();
        let pid = self.pid;
        let loop_type = self.loop_type;

        if env
            .send_and_clear(&pid, |env| {
                (atoms::poll_loop_exited(), loop_type, atoms::shutdown()).encode(env)
            })
            .is_err()
        {
            error!(loop_type = ?loop_type, "PollLoopGuard shutdown: target process is dead");
        }
    }
}

impl Drop for PollLoopGuard {
    fn drop(&mut self) {
        if self.completed {
            return;
        }

        let mut env = OwnedEnv::new();
        let pid = self.pid;
        let loop_type = self.loop_type;

        if env
            .send_and_clear(&pid, |env| {
                (atoms::poll_loop_exited(), loop_type, atoms::crashed()).encode(env)
            })
            .is_err()
        {
            error!(loop_type = ?loop_type, "PollLoopGuard drop: target process is dead");
        }
    }
}
