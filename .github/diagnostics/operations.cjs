// Temporary observation only. Paths, arguments and environment values are not recorded.
const fs = require('node:fs');
const cp = require('node:child_process');
const path = require('node:path');
const { syncBuiltinESMExports } = require('node:module');
const { promisify } = require('node:util');
const dir = process.env.ARCHON_DIAG_LOG_DIR;
if (dir) {
  const write = fs.writeSync;
  const fd = fs.openSync(path.join(dir, `operations-${process.pid}.jsonl`), 'a');
  const pending = new Map();
  const binaryLabel = value => {
    const name = path.basename(String(value)).toLowerCase();
    return [
      'bun',
      'bun.exe',
      'git',
      'git.exe',
      'tar',
      'tar.exe',
      'bash',
      'bash.exe',
      'node',
      'node.exe',
    ].includes(name)
      ? name
      : 'other';
  };
  let serial = 0;
  let observerWriteMs = 0;
  let observerWrites = 0;
  const emit = fields => {
    const started = performance.now();
    write(
      fd,
      JSON.stringify({
        pid: process.pid,
        utcMs: Date.now(),
        monoMs: started,
        observerWriteMs,
        observerWrites,
        ...fields,
      }) + '\n'
    );
    observerWriteMs += performance.now() - started;
    observerWrites++;
  };
  function begin(op, detail = {}) {
    const id = ++serial;
    pending.set(id, { id, op, started: performance.now(), ...detail });
    if (op.startsWith('process.')) emit({ event: 'begin', ...pending.get(id) });
    return id;
  }
  function end(id, detail = {}) {
    const entry = pending.get(id);
    if (!entry) return;
    const elapsedMs = performance.now() - entry.started;
    if (elapsedMs >= 100 || entry.op.startsWith('process.') || detail.errorCode)
      emit({ event: 'end', ...entry, elapsedMs, ...detail });
    pending.delete(id);
  }
  function preserve(original, wrapper) {
    for (const key of Reflect.ownKeys(original)) {
      if (!['name', 'length', 'prototype', 'caller', 'arguments'].includes(key))
        Object.defineProperty(wrapper, key, Object.getOwnPropertyDescriptor(original, key));
    }
  }
  function syncWrap(owner, key, op) {
    const original = owner[key];
    const wrapper = function (...args) {
      const id = begin(op);
      try {
        const result = Reflect.apply(original, this, args);
        end(id);
        return result;
      } catch (error) {
        end(id, { errorCode: error?.code });
        throw error;
      }
    };
    preserve(original, wrapper);
    owner[key] = wrapper;
  }
  for (const key of [
    'cp',
    'rm',
    'mkdtemp',
    'readFile',
    'writeFile',
    'mkdir',
    'readdir',
    'copyFile',
    'stat',
    'lstat',
    'realpath',
    'open',
    'unlink',
    'rename',
  ]) {
    const original = fs.promises[key];
    fs.promises[key] = function (...args) {
      const id = begin(`fs.${key}`);
      try {
        const result = Reflect.apply(original, this, args);
        return result.then(
          value => {
            end(id);
            return value;
          },
          error => {
            end(id, { errorCode: error?.code });
            throw error;
          }
        );
      } catch (error) {
        end(id, { errorCode: error?.code });
        throw error;
      }
    };
  }
  for (const key of ['cpSync', 'rmSync', 'mkdtempSync']) syncWrap(fs, key, `fs.${key}`);
  for (const key of ['spawnSync', 'execFileSync', 'execSync'])
    syncWrap(cp, key, `process.node.${key}`);
  function observeChild(child, id) {
    const entry = pending.get(id);
    if (entry) entry.childPid = child.pid;
    emit({ event: 'spawned', id, childPid: child.pid });
    for (const event of ['exit', 'close'])
      child.once(event, (code, signal) => {
        emit({
          event,
          id,
          childPid: child.pid,
          code: typeof code === 'number' ? code : undefined,
          errorCode: code?.code,
          signal,
        });
        if (event === 'close') end(id);
      });
    for (const name of ['stdin', 'stdout', 'stderr'])
      for (const event of ['finish', 'end', 'close'])
        child[name]?.once(event, () =>
          emit({ event: `pipe.${event}`, id, pipe: name, childPid: child.pid })
        );
  }
  for (const key of ['spawn', 'execFile', 'exec']) {
    const original = cp[key];
    const wrapper = function (...args) {
      const id = begin(`process.node.${key}`, { binary: binaryLabel(args[0]) });
      try {
        const result = Reflect.apply(original, this, args);
        observeChild(result, id);
        return result;
      } catch (error) {
        end(id, { errorCode: error?.code });
        throw error;
      }
    };
    preserve(original, wrapper);
    // Node/Bun's promisify custom implementation can bypass the exported function.
    const custom = original[promisify.custom];
    if (custom)
      Object.defineProperty(wrapper, promisify.custom, {
        configurable: true,
        value: function (...args) {
          const id = begin(`process.node.${key}.promisified`, { binary: binaryLabel(args[0]) });
          try {
            const result = Reflect.apply(custom, this, args);
            if (result.child) observeChild(result.child, id);
            const observed = result.then(
              value => {
                emit({ event: 'promise-settled', id });
                end(id);
                return value;
              },
              error => {
                emit({ event: 'promise-rejected', id, errorCode: error?.code });
                end(id);
                throw error;
              }
            );
            preserve(result, observed);
            return observed;
          } catch (error) {
            end(id, { errorCode: error?.code });
            throw error;
          }
        },
      });
    cp[key] = wrapper;
  }
  if (globalThis.Bun) {
    syncWrap(Bun, 'spawnSync', 'process.bun.spawnSync');
    const original = Bun.spawn;
    Bun.spawn = function (...args) {
      const command = Array.isArray(args[0]) ? args[0] : args[0]?.cmd;
      const id = begin('process.bun.spawn', { binary: binaryLabel(command?.[0]) });
      try {
        const result = Reflect.apply(original, this, args);
        pending.get(id).childPid = result.pid;
        emit({ event: 'spawned', id, childPid: result.pid });
        const observed = result.exited.then(
          code => {
            end(id, { code });
            return code;
          },
          error => {
            end(id, { errorCode: error?.code });
            throw error;
          }
        );
        Object.defineProperty(result, 'exited', { value: observed });
        return result;
      } catch (error) {
        end(id, { errorCode: error?.code });
        throw error;
      }
    };
  }
  syncBuiltinESMExports();
  let tick = performance.now();
  let cpu = process.cpuUsage();
  setInterval(() => {
    const now = performance.now();
    const currentCpu = process.cpuUsage();
    const outstanding = [...pending.values()]
      .filter(value => now - value.started >= 100)
      .map(value => ({ ...value, ageMs: now - value.started }));
    if (outstanding.length || now - tick > 500)
      emit({
        event: 'sample',
        gapMs: now - tick,
        cpuUserUs: currentCpu.user - cpu.user,
        cpuSystemUs: currentCpu.system - cpu.system,
        rss: process.memoryUsage.rss(),
        pending: outstanding,
      });
    tick = now;
    cpu = currentCpu;
  }, 250).unref();
  emit({
    event: 'ready',
    version: process.version,
    bun: globalThis.Bun?.version,
    ppid: process.ppid,
    cpuCount: require('node:os').availableParallelism(),
  });
  process.once('exit', () => emit({ event: 'process-exit', pending: [...pending.values()] }));
}
