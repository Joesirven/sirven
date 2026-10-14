// the peer verify lock: one read-check-write step at a time over a peer folder's nonce memory and
// ledger (lib/attestation/cli.mjs, peerVerify).
//
// the lock is a file created exclusively (O_EXCL) and holding an owner record: the holder's
// process number, host name, and a random token. a lock is dead only when its holder process no
// longer exists on this host, so a live holder keeps its lock however long it runs. a dead
// holder's lock is removed by exactly one waiter: the waiter creates a break file named for the
// dead token, and only the creator of that break file removes the lock. release removes the lock
// only while it still carries this holder's token. a waiter that cannot take the lock within the
// wait refuses the request (LockUnavailable); it never runs without the lock.
//
// residual window, documented rather than closed: a waiter that dies between creating a break
// file and removing the lock leaves the break file behind. a later waiter removes that abandoned
// break file by renaming it, which is atomic, so only one waiter removes a given file. two
// recoveries of the same abandoned break file racing each other would need two crashes inside
// microsecond windows.

import { closeSync, openSync, readFileSync, renameSync, statSync, unlinkSync, writeFileSync } from 'node:fs';
import { randomBytes } from 'node:crypto';
import { hostname, uptime } from 'node:os';

export class LockUnavailable extends Error {}

const POLL_MS = 10;
// a lock or break file with no readable owner record is dead once it is this old: its creator
// died between creating the file and writing the record, which takes microseconds.
const UNREADABLE_OWNER_MS = 10_000;
// a lock whose owner cannot be checked from this host (another host, or a host name that has
// changed) is dead once it is this old. no real verify holds a lock for anywhere near a day, so
// this only ends a lock that can otherwise never be cleared.
const UNCHECKABLE_OWNER_MS = 24 * 60 * 60 * 1000;
export const DEFAULT_WAIT_MS = 10_000;

// test only: SIRVEN_ATTESTATION_TEST_LOCK_WAIT_MS shortens the wait so a test can see a refusal.
function waitMilliseconds() {
  const value = Number(process.env.SIRVEN_ATTESTATION_TEST_LOCK_WAIT_MS || 0);
  return value > 0 ? value : DEFAULT_WAIT_MS;
}

function readRecord(path) {
  let text;
  try {
    text = readFileSync(path, 'utf8');
  } catch (error) {
    if (error.code === 'ENOENT') return { missing: true, record: null };
    throw error;
  }
  try {
    const record = JSON.parse(text);
    if (Number.isInteger(record.pid) && typeof record.host === 'string' && typeof record.token === 'string') return { missing: false, record };
  } catch {
    // not written yet, or damaged: handled as an unreadable owner below
  }
  return { missing: false, record: null };
}

// the time this boot began, in whole seconds. a record from an earlier boot names a process that
// cannot still be running, even if its process number has since been given to another process.
// the tolerance is minutes, not seconds: the boot time is computed from the wall clock, so a clock
// step (time synchronisation, a virtual machine resuming) must never make a live holder look dead.
const BOOT_TOLERANCE_SECONDS = 10 * 60;
function bootedAt() {
  return Math.round(Date.now() / 1000 - uptime());
}

function holderIsGone(record) {
  if (!(record.pid > 0)) return false;
  if (Number.isInteger(record.boot) && Math.abs(record.boot - bootedAt()) > BOOT_TOLERANCE_SECONDS) return true;
  try {
    process.kill(record.pid, 0);
    return false;
  } catch (error) {
    return error.code === 'ESRCH';
  }
}

function fileAgeMs(path) {
  return Date.now() - statSync(path).mtimeMs;
}

// a lock is dead when its holder is gone on this host. an unreadable record is dead only after
// UNREADABLE_OWNER_MS. a holder on another host cannot be checked from here, so its lock is dead
// only after UNCHECKABLE_OWNER_MS.
function isDead(read, path) {
  if (!read.record) return fileAgeMs(path) > UNREADABLE_OWNER_MS;
  if (read.record.host !== hostname()) return fileAgeMs(path) > UNCHECKABLE_OWNER_MS;
  return holderIsGone(read.record);
}

// the identity a break file is named for: the owner's token, or the file's inode and time when
// the record is unreadable. a break for one identity can exist only once at a time.
function identityOf(read, path) {
  if (read.record) return read.record.token;
  const stat = statSync(path);
  return `unreadable-${stat.ino}-${Math.trunc(stat.mtimeMs)}`;
}

function ownRecord(token) {
  return JSON.stringify({ pid: process.pid, host: hostname(), boot: bootedAt(), token });
}

// create the lock with this holder's record. false when a lock already exists.
function tryCreate(path, token) {
  let fd;
  try {
    fd = openSync(path, 'wx', 0o600);
  } catch (error) {
    if (error.code === 'EEXIST') return false;
    throw error;
  }
  try {
    writeFileSync(fd, ownRecord(token));
  } catch (error) {
    closeSync(fd);
    try {
      unlinkSync(path);
    } catch {
      // the file is ours and may already be gone; the write error is the one to report
    }
    throw error;
  }
  closeSync(fd);
  return true;
}

// remove a break file whose creator is gone. the rename is atomic, so one waiter wins it.
function removeAbandonedBreak(breakPath) {
  const read = readRecord(breakPath);
  if (read.missing || !isDead(read, breakPath)) return false;
  const parked = `${breakPath}.${randomBytes(8).toString('base64url')}.abandoned`;
  try {
    renameSync(breakPath, parked);
  } catch (error) {
    if (error.code === 'ENOENT') return true;
    throw error;
  }
  try {
    unlinkSync(parked);
  } catch (error) {
    if (error.code !== 'ENOENT') throw error;
  }
  return true;
}

// remove a dead holder's lock, exclusively. returns true when the lock is gone or was removed
// here, so the caller should retry at once; false when the caller should wait.
function clearDeadLock(path, token) {
  try {
    return clearDeadLockOnce(path, token);
  } catch (error) {
    // the lock file was released between the read and the stat: that is progress, not a failure
    if (error.code === 'ENOENT') return true;
    throw error;
  }
}

function clearDeadLockOnce(path, token) {
  const read = readRecord(path);
  if (read.missing) return true;
  if (!isDead(read, path)) return false;

  const identity = identityOf(read, path);
  const breakPath = `${path}.break.${identity}`;
  let fd;
  try {
    fd = openSync(breakPath, 'wx', 0o600);
  } catch (error) {
    if (error.code !== 'EEXIST') throw error;
    return removeAbandonedBreak(breakPath);
  }
  try {
    writeFileSync(fd, ownRecord(token));
  } finally {
    closeSync(fd);
  }

  try {
    // re-read under the break: the lock must still be the same dead lock before it is removed.
    const again = readRecord(path);
    if (!again.missing && isDead(again, path) && identityOf(again, path) === identity) {
      try {
        unlinkSync(path);
      } catch (error) {
        if (error.code !== 'ENOENT') throw error;
      }
    }
  } finally {
    const mine = readRecord(breakPath);
    if (!mine.missing && mine.record && mine.record.token === token) {
      try {
        unlinkSync(breakPath);
      } catch (error) {
        if (error.code !== 'ENOENT') throw error;
      }
    }
  }
  return true;
}

// remove the lock only while it still carries this holder's token. release never throws over
// the result of the work: a missing or foreign lock is left as it is.
function releaseLock(path, token) {
  try {
    const read = readRecord(path);
    if (!read.missing && read.record && read.record.token === token) unlinkSync(path);
  } catch (error) {
    if (error.code !== 'ENOENT') process.stderr.write(`peer verify: could not release ${path}: ${error.message}\n`);
  }
}

// describes the lock that blocked the wait, for the refusal: the file, and the owner it records.
function describeBlockingLock(path) {
  let read;
  try {
    read = readRecord(path);
  } catch {
    return `the lock at ${path} could not be read`;
  }
  if (read.missing) return `the lock at ${path} was released as the wait ended`;
  if (!read.record) return `the lock at ${path} has no readable owner record`;
  const { pid, host, boot } = read.record;
  const since = Number.isInteger(boot) ? ` (recorded at boot ${boot})` : '';
  return `the lock at ${path} is held by process ${pid} on host "${host}"${since}`;
}

// run work while holding the lock. throws LockUnavailable when the lock cannot be taken within
// the wait. any error from work is rethrown unchanged.
export function withVerifyLock(path, work) {
  const token = randomBytes(16).toString('base64url');
  const deadline = Date.now() + waitMilliseconds();
  const sleeper = new Int32Array(new SharedArrayBuffer(4));
  for (;;) {
    if (tryCreate(path, token)) break;
    if (clearDeadLock(path, token) && Date.now() < deadline) continue;
    if (Date.now() >= deadline) {
      throw new LockUnavailable(`${describeBlockingLock(path)}; this verify was not run. docs/peer-routing.md, "Clearing a stuck verify lock", says when and how to clear it`);
    }
    Atomics.wait(sleeper, 0, 0, POLL_MS);
  }
  try {
    return work();
  } finally {
    releaseLock(path, token);
  }
}
