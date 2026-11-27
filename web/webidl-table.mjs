// The table of the Web IDL for the commands `web::` (src/wasmweb.zig).
// Task 01 of docs/dev/web-api-tasks/README.md: written by hand from the
// IDL blocks of https://wicg.github.io/serial/ (2026-11-27).
//
// SPDX-License-Identifier: BSD-2-Clause

export const interfaces = {
  Serial: {
    group: "serial",
    inherits: "EventTarget",
    attributes: {
      onconnect: { type: "EventHandler" },
      ondisconnect: { type: "EventHandler" },
    },
    operations: {
      getPorts: { args: [], returns: "Promise<sequence<SerialPort>>" },
      requestPort: { args: [{ name: "options", type: "SerialPortRequestOptions", optional: true }], returns: "Promise<SerialPort>" },
    },
  },
  SerialPort: {
    group: "serial",
    inherits: "EventTarget",
    attributes: {
      onconnect: { type: "EventHandler" },
      ondisconnect: { type: "EventHandler" },
      connected: { type: "boolean", readonly: true },
      readable: { type: "ReadableStream", readonly: true },
      writable: { type: "WritableStream", readonly: true },
    },
    operations: {
      getInfo: { args: [], returns: "SerialPortInfo" },
      open: { args: [{ name: "options", type: "SerialOptions" }], returns: "Promise<undefined>" },
      setSignals: { args: [{ name: "signals", type: "SerialOutputSignals", optional: true }], returns: "Promise<undefined>" },
      getSignals: { args: [], returns: "Promise<SerialInputSignals>" },
      close: { args: [], returns: "Promise<undefined>" },
      forget: { args: [], returns: "Promise<undefined>" },
    },
  },
};

export const dictionaries = {
  SerialPortRequestOptions: {
    members: {
      filters: { type: "sequence<SerialPortFilter>" },
      allowedBluetoothServiceClassIds: { type: "sequence<BluetoothServiceUUID>" },
    },
  },
  SerialPortFilter: {
    members: {
      usbVendorId: { type: "unsigned short" },
      usbProductId: { type: "unsigned short" },
      bluetoothServiceClassId: { type: "BluetoothServiceUUID" },
    },
  },
  SerialPortInfo: {
    members: {
      usbVendorId: { type: "unsigned short" },
      usbProductId: { type: "unsigned short" },
      bluetoothServiceClassId: { type: "BluetoothServiceUUID" },
    },
  },
  SerialOptions: {
    members: {
      baudRate: { type: "unsigned long", required: true },
      dataBits: { type: "octet" },
      stopBits: { type: "octet" },
      parity: { type: "ParityType" },
      bufferSize: { type: "unsigned long" },
      flowControl: { type: "FlowControlType" },
    },
  },
  SerialOutputSignals: {
    members: {
      dataTerminalReady: { type: "boolean" },
      requestToSend: { type: "boolean" },
      break: { type: "boolean" },
    },
  },
  SerialInputSignals: {
    members: {
      dataCarrierDetect: { type: "boolean", required: true },
      clearToSend: { type: "boolean", required: true },
      ringIndicator: { type: "boolean", required: true },
      dataSetReady: { type: "boolean", required: true },
    },
  },
};

export const enums = {
  ParityType: ["none", "even", "odd"],
  FlowControlType: ["none", "hardware"],
};

export const typedefs = {
  BluetoothServiceUUID: "(DOMString or unsigned long)",
};

// The root objects of `web::root`: a path from the global object, and
// the interface of the object.
export const roots = {
  "navigator.serial": "Serial",
};
