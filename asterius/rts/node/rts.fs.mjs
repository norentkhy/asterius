import fs from "fs";
import { Memory } from "./rts.memory.mjs";

class Device {
  constructor(f, console_history) {
    this.flush = f;
    this.consoleHistory = console_history;
    this.history = "";
    this.decoder = new TextDecoder("utf-8", { fatal: true });
    Object.seal(this);
  }

  read() {
    const r = this.history;
    this.history = "";
    return r;
  }

  write(buf) {
    const str =
      typeof buf === "string"
        ? buf
        : this.decoder.decode(buf, { stream: true });
    if (this.consoleHistory) {
      this.history += str;
    }
    this.flush(str);
    return buf.length;
  }
}

export class FS {
  constructor(components) {
    this.components = components;
    this.stdout = new Device((s) => process.stdout.write(s), true);
    this.stderr = new Device((s) => process.stderr.write(s), true);
  }

  read(fd, buf, count) {
    const p = Memory.unTag(buf);
    return fs.readSync(fd, this.components.memory.i8View, p, count, null);
  }

  write(fd, buf, count) {
    buf = this.components.memory.expose(buf, count, Uint8Array);
    switch (fd) {
      case 1: {
        return this.stdout.write(buf);
      }
      case 2: {
        return this.stderr.write(buf);
      }
      default: {
        return fs.writeSync(fd, buf);
      }
    }
  }

  writeNonMemory(fd, data) {
    switch (fd) {
      case 1: {
        this.stdout.write(data);
        break;
      }
      case 2: {
        this.stderr.write(data);
        break;
      }
      default: {
        throw new WebAssembly.RuntimeError(`writeNonMemory(${fd}, ${data})`);
      }
    }
  }

  history(fd) {
    switch (fd) {
      case 1: {
        return this.stdout.read();
      }
      case 2: {
        return this.stderr.read();
      }
      default: {
        throw new WebAssembly.RuntimeError(
          `Attempting to get history of ${fd}`
        );
      }
    }
  }
}
