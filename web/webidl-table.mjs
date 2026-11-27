// The table of the Web IDL for the commands `web::` (src/wasmweb.zig).
// tools/webidl writes this file from tools/webidl/idl/: run
// `zig build webidl`, and do not edit it. Each file of the IDL has the
// URL of its spec in its header.

export const interfaces = {
  "Bluetooth": {
    "group": "bluetooth",
    "inherits": "EventTarget",
    "attributes": {
      "onavailabilitychanged": { "type": "EventHandler" },
      "referringDevice": { "type": "BluetoothDevice?", "readonly": true },
      "onadvertisementreceived": { "type": "EventHandler" },
      "ongattserverdisconnected": { "type": "EventHandler" },
      "oncharacteristicvaluechanged": { "type": "EventHandler" },
      "onserviceadded": { "type": "EventHandler" },
      "onservicechanged": { "type": "EventHandler" },
      "onserviceremoved": { "type": "EventHandler" }
    },
    "operations": {
      "getAvailability": { "args": [], "returns": "Promise<boolean>" },
      "getDevices": { "args": [], "returns": "Promise<sequence<BluetoothDevice>>" },
      "requestDevice": { "args": [{ "name": "options", "type": "RequestDeviceOptions", "optional": true }], "returns": "Promise<BluetoothDevice>" }
    }
  },
  "BluetoothAdvertisingEvent": {
    "group": "bluetooth",
    "inherits": "Event",
    "attributes": {
      "device": { "type": "BluetoothDevice", "readonly": true },
      "uuids": { "type": "FrozenArray<UUID>", "readonly": true },
      "name": { "type": "DOMString?", "readonly": true },
      "appearance": { "type": "unsigned short?", "readonly": true },
      "txPower": { "type": "byte?", "readonly": true },
      "rssi": { "type": "byte?", "readonly": true },
      "manufacturerData": { "type": "BluetoothManufacturerDataMap", "readonly": true },
      "serviceData": { "type": "BluetoothServiceDataMap", "readonly": true }
    },
    "operations": {}
  },
  "BluetoothCharacteristicProperties": {
    "group": "bluetooth",
    "inherits": null,
    "attributes": {
      "broadcast": { "type": "boolean", "readonly": true },
      "read": { "type": "boolean", "readonly": true },
      "writeWithoutResponse": { "type": "boolean", "readonly": true },
      "write": { "type": "boolean", "readonly": true },
      "notify": { "type": "boolean", "readonly": true },
      "indicate": { "type": "boolean", "readonly": true },
      "authenticatedSignedWrites": { "type": "boolean", "readonly": true },
      "reliableWrite": { "type": "boolean", "readonly": true },
      "writableAuxiliaries": { "type": "boolean", "readonly": true }
    },
    "operations": {}
  },
  "BluetoothDevice": {
    "group": "bluetooth",
    "inherits": "EventTarget",
    "attributes": {
      "id": { "type": "DOMString", "readonly": true },
      "name": { "type": "DOMString?", "readonly": true },
      "gatt": { "type": "BluetoothRemoteGATTServer?", "readonly": true },
      "watchingAdvertisements": { "type": "boolean", "readonly": true },
      "onadvertisementreceived": { "type": "EventHandler" },
      "ongattserverdisconnected": { "type": "EventHandler" },
      "oncharacteristicvaluechanged": { "type": "EventHandler" },
      "onserviceadded": { "type": "EventHandler" },
      "onservicechanged": { "type": "EventHandler" },
      "onserviceremoved": { "type": "EventHandler" }
    },
    "operations": {
      "forget": { "args": [], "returns": "Promise<undefined>" },
      "watchAdvertisements": { "args": [{ "name": "options", "type": "WatchAdvertisementsOptions", "optional": true }], "returns": "Promise<undefined>" }
    }
  },
  "BluetoothManufacturerDataMap": {
    "group": "bluetooth",
    "inherits": null,
    "attributes": {
      "size": { "type": "unsigned long", "readonly": true }
    },
    "operations": {
      "get": { "args": [{ "name": "key", "type": "unsigned short" }], "returns": "DataView?" },
      "has": { "args": [{ "name": "key", "type": "unsigned short" }], "returns": "boolean" },
      "keys": { "args": [], "returns": "sequence<unsigned short>" },
      "values": { "args": [], "returns": "sequence<DataView>" }
    }
  },
  "BluetoothPermissionResult": {
    "group": "bluetooth",
    "inherits": "PermissionStatus",
    "attributes": {
      "devices": { "type": "FrozenArray<BluetoothDevice>" }
    },
    "operations": {}
  },
  "BluetoothRemoteGATTCharacteristic": {
    "group": "bluetooth",
    "inherits": "EventTarget",
    "attributes": {
      "service": { "type": "BluetoothRemoteGATTService", "readonly": true },
      "uuid": { "type": "UUID", "readonly": true },
      "properties": { "type": "BluetoothCharacteristicProperties", "readonly": true },
      "value": { "type": "DataView?", "readonly": true },
      "oncharacteristicvaluechanged": { "type": "EventHandler" }
    },
    "operations": {
      "getDescriptor": { "args": [{ "name": "descriptor", "type": "BluetoothDescriptorUUID" }], "returns": "Promise<BluetoothRemoteGATTDescriptor>" },
      "getDescriptors": { "args": [{ "name": "descriptor", "type": "BluetoothDescriptorUUID", "optional": true }], "returns": "Promise<sequence<BluetoothRemoteGATTDescriptor>>" },
      "readValue": { "args": [], "returns": "Promise<DataView>" },
      "writeValue": { "args": [{ "name": "value", "type": "BufferSource" }], "returns": "Promise<undefined>" },
      "writeValueWithResponse": { "args": [{ "name": "value", "type": "BufferSource" }], "returns": "Promise<undefined>" },
      "writeValueWithoutResponse": { "args": [{ "name": "value", "type": "BufferSource" }], "returns": "Promise<undefined>" },
      "startNotifications": { "args": [], "returns": "Promise<BluetoothRemoteGATTCharacteristic>" },
      "stopNotifications": { "args": [], "returns": "Promise<BluetoothRemoteGATTCharacteristic>" }
    }
  },
  "BluetoothRemoteGATTDescriptor": {
    "group": "bluetooth",
    "inherits": null,
    "attributes": {
      "characteristic": { "type": "BluetoothRemoteGATTCharacteristic", "readonly": true },
      "uuid": { "type": "UUID", "readonly": true },
      "value": { "type": "DataView?", "readonly": true }
    },
    "operations": {
      "readValue": { "args": [], "returns": "Promise<DataView>" },
      "writeValue": { "args": [{ "name": "value", "type": "BufferSource" }], "returns": "Promise<undefined>" }
    }
  },
  "BluetoothRemoteGATTServer": {
    "group": "bluetooth",
    "inherits": null,
    "attributes": {
      "device": { "type": "BluetoothDevice", "readonly": true },
      "connected": { "type": "boolean", "readonly": true }
    },
    "operations": {
      "connect": { "args": [], "returns": "Promise<BluetoothRemoteGATTServer>" },
      "disconnect": { "args": [], "returns": "undefined" },
      "getPrimaryService": { "args": [{ "name": "service", "type": "BluetoothServiceUUID" }], "returns": "Promise<BluetoothRemoteGATTService>" },
      "getPrimaryServices": { "args": [{ "name": "service", "type": "BluetoothServiceUUID", "optional": true }], "returns": "Promise<sequence<BluetoothRemoteGATTService>>" }
    }
  },
  "BluetoothRemoteGATTService": {
    "group": "bluetooth",
    "inherits": "EventTarget",
    "attributes": {
      "device": { "type": "BluetoothDevice", "readonly": true },
      "uuid": { "type": "UUID", "readonly": true },
      "isPrimary": { "type": "boolean", "readonly": true },
      "oncharacteristicvaluechanged": { "type": "EventHandler" },
      "onserviceadded": { "type": "EventHandler" },
      "onservicechanged": { "type": "EventHandler" },
      "onserviceremoved": { "type": "EventHandler" }
    },
    "operations": {
      "getCharacteristic": { "args": [{ "name": "characteristic", "type": "BluetoothCharacteristicUUID" }], "returns": "Promise<BluetoothRemoteGATTCharacteristic>" },
      "getCharacteristics": { "args": [{ "name": "characteristic", "type": "BluetoothCharacteristicUUID", "optional": true }], "returns": "Promise<sequence<BluetoothRemoteGATTCharacteristic>>" },
      "getIncludedService": { "args": [{ "name": "service", "type": "BluetoothServiceUUID" }], "returns": "Promise<BluetoothRemoteGATTService>" },
      "getIncludedServices": { "args": [{ "name": "service", "type": "BluetoothServiceUUID", "optional": true }], "returns": "Promise<sequence<BluetoothRemoteGATTService>>" }
    }
  },
  "BluetoothServiceDataMap": {
    "group": "bluetooth",
    "inherits": null,
    "attributes": {
      "size": { "type": "unsigned long", "readonly": true }
    },
    "operations": {
      "get": { "args": [{ "name": "key", "type": "UUID" }], "returns": "DataView?" },
      "has": { "args": [{ "name": "key", "type": "UUID" }], "returns": "boolean" },
      "keys": { "args": [], "returns": "sequence<UUID>" },
      "values": { "args": [], "returns": "sequence<DataView>" }
    }
  },
  "BluetoothUUID": {
    "group": "bluetooth",
    "inherits": null,
    "attributes": {},
    "operations": {}
  },
  "Gamepad": {
    "group": "gamepad",
    "inherits": null,
    "attributes": {
      "id": { "type": "DOMString", "readonly": true },
      "index": { "type": "long", "readonly": true },
      "connected": { "type": "boolean", "readonly": true },
      "timestamp": { "type": "DOMHighResTimeStamp", "readonly": true },
      "mapping": { "type": "GamepadMappingType", "readonly": true },
      "axes": { "type": "FrozenArray<double>", "readonly": true },
      "buttons": { "type": "FrozenArray<GamepadButton>", "readonly": true },
      "touches": { "type": "FrozenArray<GamepadTouch>", "readonly": true },
      "vibrationActuator": { "type": "GamepadHapticActuator", "readonly": true }
    },
    "operations": {}
  },
  "GamepadButton": {
    "group": "gamepad",
    "inherits": null,
    "attributes": {
      "pressed": { "type": "boolean", "readonly": true },
      "touched": { "type": "boolean", "readonly": true },
      "value": { "type": "double", "readonly": true }
    },
    "operations": {}
  },
  "GamepadEvent": {
    "group": "gamepad",
    "inherits": "Event",
    "attributes": {
      "gamepad": { "type": "Gamepad", "readonly": true }
    },
    "operations": {}
  },
  "GamepadHapticActuator": {
    "group": "gamepad",
    "inherits": null,
    "attributes": {
      "effects": { "type": "FrozenArray<GamepadHapticEffectType>", "readonly": true }
    },
    "operations": {
      "playEffect": { "args": [{ "name": "type", "type": "GamepadHapticEffectType" }, { "name": "params", "type": "GamepadEffectParameters", "optional": true }], "returns": "Promise<GamepadHapticsResult>" },
      "reset": { "args": [], "returns": "Promise<GamepadHapticsResult>" }
    }
  },
  "HID": {
    "group": "hid",
    "inherits": "EventTarget",
    "attributes": {
      "onconnect": { "type": "EventHandler" },
      "ondisconnect": { "type": "EventHandler" }
    },
    "operations": {
      "getDevices": { "args": [], "returns": "Promise<sequence<HIDDevice>>" },
      "requestDevice": { "args": [{ "name": "options", "type": "HIDDeviceRequestOptions" }], "returns": "Promise<sequence<HIDDevice>>" }
    }
  },
  "HIDConnectionEvent": {
    "group": "hid",
    "inherits": "Event",
    "attributes": {
      "device": { "type": "HIDDevice", "readonly": true }
    },
    "operations": {}
  },
  "HIDDevice": {
    "group": "hid",
    "inherits": "EventTarget",
    "attributes": {
      "oninputreport": { "type": "EventHandler" },
      "opened": { "type": "boolean", "readonly": true },
      "vendorId": { "type": "unsigned short", "readonly": true },
      "productId": { "type": "unsigned short", "readonly": true },
      "productName": { "type": "DOMString", "readonly": true },
      "collections": { "type": "FrozenArray<HIDCollectionInfo>", "readonly": true }
    },
    "operations": {
      "open": { "args": [], "returns": "Promise<undefined>" },
      "close": { "args": [], "returns": "Promise<undefined>" },
      "forget": { "args": [], "returns": "Promise<undefined>" },
      "sendReport": { "args": [{ "name": "reportId", "type": "octet" }, { "name": "data", "type": "BufferSource" }], "returns": "Promise<undefined>" },
      "sendFeatureReport": { "args": [{ "name": "reportId", "type": "octet" }, { "name": "data", "type": "BufferSource" }], "returns": "Promise<undefined>" },
      "receiveFeatureReport": { "args": [{ "name": "reportId", "type": "octet" }], "returns": "Promise<DataView>" }
    }
  },
  "HIDInputReportEvent": {
    "group": "hid",
    "inherits": "Event",
    "attributes": {
      "device": { "type": "HIDDevice", "readonly": true },
      "reportId": { "type": "octet", "readonly": true },
      "data": { "type": "DataView", "readonly": true }
    },
    "operations": {}
  },
  "MIDIAccess": {
    "group": "midi",
    "inherits": "EventTarget",
    "attributes": {
      "inputs": { "type": "MIDIInputMap", "readonly": true },
      "outputs": { "type": "MIDIOutputMap", "readonly": true },
      "onstatechange": { "type": "EventHandler" },
      "sysexEnabled": { "type": "boolean", "readonly": true }
    },
    "operations": {}
  },
  "MIDIConnectionEvent": {
    "group": "midi",
    "inherits": "Event",
    "attributes": {
      "port": { "type": "MIDIPort?", "readonly": true }
    },
    "operations": {}
  },
  "MIDIInput": {
    "group": "midi",
    "inherits": "MIDIPort",
    "attributes": {
      "onmidimessage": { "type": "EventHandler" }
    },
    "operations": {}
  },
  "MIDIInputMap": {
    "group": "midi",
    "inherits": null,
    "attributes": {
      "size": { "type": "unsigned long", "readonly": true }
    },
    "operations": {
      "get": { "args": [{ "name": "key", "type": "DOMString" }], "returns": "MIDIInput?" },
      "has": { "args": [{ "name": "key", "type": "DOMString" }], "returns": "boolean" },
      "keys": { "args": [], "returns": "sequence<DOMString>" },
      "values": { "args": [], "returns": "sequence<MIDIInput>" }
    }
  },
  "MIDIMessageEvent": {
    "group": "midi",
    "inherits": "Event",
    "attributes": {
      "data": { "type": "Uint8Array?", "readonly": true }
    },
    "operations": {}
  },
  "MIDIOutput": {
    "group": "midi",
    "inherits": "MIDIPort",
    "attributes": {},
    "operations": {
      "send": { "args": [{ "name": "data", "type": "sequence<octet>" }, { "name": "timestamp", "type": "DOMHighResTimeStamp", "optional": true }], "returns": "undefined" },
      "clear": { "args": [], "returns": "undefined" }
    }
  },
  "MIDIOutputMap": {
    "group": "midi",
    "inherits": null,
    "attributes": {
      "size": { "type": "unsigned long", "readonly": true }
    },
    "operations": {
      "get": { "args": [{ "name": "key", "type": "DOMString" }], "returns": "MIDIOutput?" },
      "has": { "args": [{ "name": "key", "type": "DOMString" }], "returns": "boolean" },
      "keys": { "args": [], "returns": "sequence<DOMString>" },
      "values": { "args": [], "returns": "sequence<MIDIOutput>" }
    }
  },
  "MIDIPort": {
    "group": "midi",
    "inherits": "EventTarget",
    "attributes": {
      "id": { "type": "DOMString", "readonly": true },
      "manufacturer": { "type": "DOMString?", "readonly": true },
      "name": { "type": "DOMString?", "readonly": true },
      "type": { "type": "MIDIPortType", "readonly": true },
      "version": { "type": "DOMString?", "readonly": true },
      "state": { "type": "MIDIPortDeviceState", "readonly": true },
      "connection": { "type": "MIDIPortConnectionState", "readonly": true },
      "onstatechange": { "type": "EventHandler" }
    },
    "operations": {
      "open": { "args": [], "returns": "Promise<MIDIPort>" },
      "close": { "args": [], "returns": "Promise<MIDIPort>" }
    }
  },
  "Navigator": {
    "group": null,
    "inherits": null,
    "attributes": {
      "bluetooth": { "type": "Bluetooth", "readonly": true, "group": "bluetooth" },
      "hid": { "type": "HID", "readonly": true, "group": "hid" },
      "serial": { "type": "Serial", "readonly": true, "group": "serial" },
      "usb": { "type": "USB", "readonly": true, "group": "usb" }
    },
    "operations": {
      "getGamepads": { "args": [], "returns": "sequence<Gamepad?>", "group": "gamepad" },
      "requestMIDIAccess": { "args": [{ "name": "options", "type": "MIDIOptions", "optional": true }], "returns": "Promise<MIDIAccess>", "group": "midi" }
    }
  },
  "Serial": {
    "group": "serial",
    "inherits": "EventTarget",
    "attributes": {
      "onconnect": { "type": "EventHandler" },
      "ondisconnect": { "type": "EventHandler" }
    },
    "operations": {
      "getPorts": { "args": [], "returns": "Promise<sequence<SerialPort>>" },
      "requestPort": { "args": [{ "name": "options", "type": "SerialPortRequestOptions", "optional": true }], "returns": "Promise<SerialPort>" }
    }
  },
  "SerialPort": {
    "group": "serial",
    "inherits": "EventTarget",
    "attributes": {
      "onconnect": { "type": "EventHandler" },
      "ondisconnect": { "type": "EventHandler" },
      "connected": { "type": "boolean", "readonly": true },
      "readable": { "type": "ReadableStream?", "readonly": true },
      "writable": { "type": "WritableStream?", "readonly": true }
    },
    "operations": {
      "getInfo": { "args": [], "returns": "SerialPortInfo" },
      "open": { "args": [{ "name": "options", "type": "SerialOptions" }], "returns": "Promise<undefined>" },
      "setSignals": { "args": [{ "name": "signals", "type": "SerialOutputSignals", "optional": true }], "returns": "Promise<undefined>" },
      "getSignals": { "args": [], "returns": "Promise<SerialInputSignals>" },
      "close": { "args": [], "returns": "Promise<undefined>" },
      "forget": { "args": [], "returns": "Promise<undefined>" }
    }
  },
  "USB": {
    "group": "usb",
    "inherits": "EventTarget",
    "attributes": {
      "onconnect": { "type": "EventHandler" },
      "ondisconnect": { "type": "EventHandler" }
    },
    "operations": {
      "getDevices": { "args": [], "returns": "Promise<sequence<USBDevice>>" },
      "requestDevice": { "args": [{ "name": "options", "type": "USBDeviceRequestOptions" }], "returns": "Promise<USBDevice>" }
    }
  },
  "USBAlternateInterface": {
    "group": "usb",
    "inherits": null,
    "attributes": {
      "alternateSetting": { "type": "octet", "readonly": true },
      "interfaceClass": { "type": "octet", "readonly": true },
      "interfaceSubclass": { "type": "octet", "readonly": true },
      "interfaceProtocol": { "type": "octet", "readonly": true },
      "interfaceName": { "type": "DOMString?", "readonly": true },
      "endpoints": { "type": "FrozenArray<USBEndpoint>", "readonly": true }
    },
    "operations": {}
  },
  "USBConfiguration": {
    "group": "usb",
    "inherits": null,
    "attributes": {
      "configurationValue": { "type": "octet", "readonly": true },
      "configurationName": { "type": "DOMString?", "readonly": true },
      "interfaces": { "type": "FrozenArray<USBInterface>", "readonly": true }
    },
    "operations": {}
  },
  "USBConnectionEvent": {
    "group": "usb",
    "inherits": "Event",
    "attributes": {
      "device": { "type": "USBDevice", "readonly": true }
    },
    "operations": {}
  },
  "USBDevice": {
    "group": "usb",
    "inherits": null,
    "attributes": {
      "usbVersionMajor": { "type": "octet", "readonly": true },
      "usbVersionMinor": { "type": "octet", "readonly": true },
      "usbVersionSubminor": { "type": "octet", "readonly": true },
      "deviceClass": { "type": "octet", "readonly": true },
      "deviceSubclass": { "type": "octet", "readonly": true },
      "deviceProtocol": { "type": "octet", "readonly": true },
      "vendorId": { "type": "unsigned short", "readonly": true },
      "productId": { "type": "unsigned short", "readonly": true },
      "deviceVersionMajor": { "type": "octet", "readonly": true },
      "deviceVersionMinor": { "type": "octet", "readonly": true },
      "deviceVersionSubminor": { "type": "octet", "readonly": true },
      "manufacturerName": { "type": "DOMString?", "readonly": true },
      "productName": { "type": "DOMString?", "readonly": true },
      "serialNumber": { "type": "DOMString?", "readonly": true },
      "configuration": { "type": "USBConfiguration?", "readonly": true },
      "configurations": { "type": "FrozenArray<USBConfiguration>", "readonly": true },
      "opened": { "type": "boolean", "readonly": true }
    },
    "operations": {
      "open": { "args": [], "returns": "Promise<undefined>" },
      "close": { "args": [], "returns": "Promise<undefined>" },
      "forget": { "args": [], "returns": "Promise<undefined>" },
      "selectConfiguration": { "args": [{ "name": "configurationValue", "type": "octet" }], "returns": "Promise<undefined>" },
      "claimInterface": { "args": [{ "name": "interfaceNumber", "type": "octet" }], "returns": "Promise<undefined>" },
      "releaseInterface": { "args": [{ "name": "interfaceNumber", "type": "octet" }], "returns": "Promise<undefined>" },
      "selectAlternateInterface": { "args": [{ "name": "interfaceNumber", "type": "octet" }, { "name": "alternateSetting", "type": "octet" }], "returns": "Promise<undefined>" },
      "controlTransferIn": { "args": [{ "name": "setup", "type": "USBControlTransferParameters" }, { "name": "length", "type": "unsigned short" }], "returns": "Promise<USBInTransferResult>" },
      "controlTransferOut": { "args": [{ "name": "setup", "type": "USBControlTransferParameters" }, { "name": "data", "type": "BufferSource", "optional": true }], "returns": "Promise<USBOutTransferResult>" },
      "clearHalt": { "args": [{ "name": "direction", "type": "USBDirection" }, { "name": "endpointNumber", "type": "octet" }], "returns": "Promise<undefined>" },
      "transferIn": { "args": [{ "name": "endpointNumber", "type": "octet" }, { "name": "length", "type": "unsigned long" }], "returns": "Promise<USBInTransferResult>" },
      "transferOut": { "args": [{ "name": "endpointNumber", "type": "octet" }, { "name": "data", "type": "BufferSource" }], "returns": "Promise<USBOutTransferResult>" },
      "isochronousTransferIn": { "args": [{ "name": "endpointNumber", "type": "octet" }, { "name": "packetLengths", "type": "sequence<unsigned long>" }], "returns": "Promise<USBIsochronousInTransferResult>" },
      "isochronousTransferOut": { "args": [{ "name": "endpointNumber", "type": "octet" }, { "name": "data", "type": "BufferSource" }, { "name": "packetLengths", "type": "sequence<unsigned long>" }], "returns": "Promise<USBIsochronousOutTransferResult>" },
      "reset": { "args": [], "returns": "Promise<undefined>" }
    }
  },
  "USBEndpoint": {
    "group": "usb",
    "inherits": null,
    "attributes": {
      "endpointNumber": { "type": "octet", "readonly": true },
      "direction": { "type": "USBDirection", "readonly": true },
      "type": { "type": "USBEndpointType", "readonly": true },
      "packetSize": { "type": "unsigned long", "readonly": true }
    },
    "operations": {}
  },
  "USBInTransferResult": {
    "group": "usb",
    "inherits": null,
    "attributes": {
      "data": { "type": "DataView?", "readonly": true },
      "status": { "type": "USBTransferStatus", "readonly": true }
    },
    "operations": {}
  },
  "USBInterface": {
    "group": "usb",
    "inherits": null,
    "attributes": {
      "interfaceNumber": { "type": "octet", "readonly": true },
      "alternate": { "type": "USBAlternateInterface", "readonly": true },
      "alternates": { "type": "FrozenArray<USBAlternateInterface>", "readonly": true },
      "claimed": { "type": "boolean", "readonly": true }
    },
    "operations": {}
  },
  "USBIsochronousInTransferPacket": {
    "group": "usb",
    "inherits": null,
    "attributes": {
      "data": { "type": "DataView?", "readonly": true },
      "status": { "type": "USBTransferStatus", "readonly": true }
    },
    "operations": {}
  },
  "USBIsochronousInTransferResult": {
    "group": "usb",
    "inherits": null,
    "attributes": {
      "data": { "type": "DataView?", "readonly": true },
      "packets": { "type": "FrozenArray<USBIsochronousInTransferPacket>", "readonly": true }
    },
    "operations": {}
  },
  "USBIsochronousOutTransferPacket": {
    "group": "usb",
    "inherits": null,
    "attributes": {
      "bytesWritten": { "type": "unsigned long", "readonly": true },
      "status": { "type": "USBTransferStatus", "readonly": true }
    },
    "operations": {}
  },
  "USBIsochronousOutTransferResult": {
    "group": "usb",
    "inherits": null,
    "attributes": {
      "packets": { "type": "FrozenArray<USBIsochronousOutTransferPacket>", "readonly": true }
    },
    "operations": {}
  },
  "USBOutTransferResult": {
    "group": "usb",
    "inherits": null,
    "attributes": {
      "bytesWritten": { "type": "unsigned long", "readonly": true },
      "status": { "type": "USBTransferStatus", "readonly": true }
    },
    "operations": {}
  },
  "USBPermissionResult": {
    "group": "usb",
    "inherits": "PermissionStatus",
    "attributes": {
      "devices": { "type": "FrozenArray<USBDevice>" }
    },
    "operations": {}
  },
  "ValueEvent": {
    "group": "bluetooth",
    "inherits": "Event",
    "attributes": {
      "value": { "type": "any", "readonly": true }
    },
    "operations": {}
  },
  "Window": {
    "group": null,
    "inherits": null,
    "attributes": {
      "ongamepadconnected": { "type": "EventHandler", "group": "gamepad" },
      "ongamepaddisconnected": { "type": "EventHandler", "group": "gamepad" }
    },
    "operations": {}
  },
  "WorkerNavigator": {
    "group": null,
    "inherits": null,
    "attributes": {
      "hid": { "type": "HID", "readonly": true, "group": "hid" },
      "serial": { "type": "Serial", "readonly": true, "group": "serial" },
      "usb": { "type": "USB", "readonly": true, "group": "usb" }
    },
    "operations": {}
  }
};

export const dictionaries = {
  "AllowedBluetoothDevice": {
    "inherits": null,
    "members": {
      "deviceId": { "type": "DOMString", "required": true },
      "mayUseGATT": { "type": "boolean", "required": true },
      "allowedServices": { "type": "(DOMString or sequence<UUID>)", "required": true },
      "allowedManufacturerData": { "type": "sequence<unsigned short>", "required": true }
    }
  },
  "AllowedUSBDevice": {
    "inherits": null,
    "members": {
      "vendorId": { "type": "octet", "required": true },
      "productId": { "type": "octet", "required": true },
      "serialNumber": { "type": "DOMString" }
    }
  },
  "BluetoothAdvertisingEventInit": {
    "inherits": "EventInit",
    "members": {
      "device": { "type": "BluetoothDevice", "required": true },
      "uuids": { "type": "sequence<(DOMString or unsigned long)>" },
      "name": { "type": "DOMString" },
      "appearance": { "type": "unsigned short" },
      "txPower": { "type": "byte" },
      "rssi": { "type": "byte" },
      "manufacturerData": { "type": "BluetoothManufacturerDataMap" },
      "serviceData": { "type": "BluetoothServiceDataMap" }
    }
  },
  "BluetoothDataFilterInit": {
    "inherits": null,
    "members": {
      "dataPrefix": { "type": "BufferSource" },
      "mask": { "type": "BufferSource" }
    }
  },
  "BluetoothLEScanFilterInit": {
    "inherits": null,
    "members": {
      "services": { "type": "sequence<BluetoothServiceUUID>" },
      "name": { "type": "DOMString" },
      "namePrefix": { "type": "DOMString" },
      "manufacturerData": { "type": "sequence<BluetoothManufacturerDataFilterInit>" },
      "serviceData": { "type": "sequence<BluetoothServiceDataFilterInit>" }
    }
  },
  "BluetoothManufacturerDataFilterInit": {
    "inherits": "BluetoothDataFilterInit",
    "members": {
      "companyIdentifier": { "type": "unsigned short", "required": true }
    }
  },
  "BluetoothPermissionDescriptor": {
    "inherits": "PermissionDescriptor",
    "members": {
      "deviceId": { "type": "DOMString" },
      "filters": { "type": "sequence<BluetoothLEScanFilterInit>" },
      "optionalServices": { "type": "sequence<BluetoothServiceUUID>" },
      "optionalManufacturerData": { "type": "sequence<unsigned short>" },
      "acceptAllDevices": { "type": "boolean" }
    }
  },
  "BluetoothPermissionStorage": {
    "inherits": null,
    "members": {
      "allowedDevices": { "type": "sequence<AllowedBluetoothDevice>", "required": true }
    }
  },
  "BluetoothServiceDataFilterInit": {
    "inherits": "BluetoothDataFilterInit",
    "members": {
      "service": { "type": "BluetoothServiceUUID", "required": true }
    }
  },
  "GamepadEffectParameters": {
    "inherits": null,
    "members": {
      "duration": { "type": "unsigned long long" },
      "startDelay": { "type": "unsigned long long" },
      "strongMagnitude": { "type": "double" },
      "weakMagnitude": { "type": "double" },
      "leftTrigger": { "type": "double" },
      "rightTrigger": { "type": "double" }
    }
  },
  "GamepadEventInit": {
    "inherits": "EventInit",
    "members": {
      "gamepad": { "type": "Gamepad?" }
    }
  },
  "GamepadTouch": {
    "inherits": null,
    "members": {
      "touchId": { "type": "unsigned long" },
      "surfaceId": { "type": "octet" },
      "position": { "type": "DOMPointReadOnly" },
      "surfaceDimensions": { "type": "DOMRectReadOnly?" }
    }
  },
  "HIDCollectionInfo": {
    "inherits": null,
    "members": {
      "usagePage": { "type": "unsigned short" },
      "usage": { "type": "unsigned short" },
      "type": { "type": "octet" },
      "children": { "type": "sequence<HIDCollectionInfo>" },
      "inputReports": { "type": "sequence<HIDReportInfo>" },
      "outputReports": { "type": "sequence<HIDReportInfo>" },
      "featureReports": { "type": "sequence<HIDReportInfo>" }
    }
  },
  "HIDConnectionEventInit": {
    "inherits": "EventInit",
    "members": {
      "device": { "type": "HIDDevice", "required": true }
    }
  },
  "HIDDeviceFilter": {
    "inherits": null,
    "members": {
      "vendorId": { "type": "unsigned short" },
      "productId": { "type": "unsigned short" },
      "usagePage": { "type": "unsigned short" },
      "usage": { "type": "unsigned short" }
    }
  },
  "HIDDeviceRequestOptions": {
    "inherits": null,
    "members": {
      "filters": { "type": "sequence<HIDDeviceFilter>", "required": true },
      "exclusionFilters": { "type": "sequence<HIDDeviceFilter>" }
    }
  },
  "HIDInputReportEventInit": {
    "inherits": "EventInit",
    "members": {
      "device": { "type": "HIDDevice", "required": true },
      "reportId": { "type": "octet", "required": true },
      "data": { "type": "DataView", "required": true }
    }
  },
  "HIDReportInfo": {
    "inherits": null,
    "members": {
      "reportId": { "type": "octet" },
      "items": { "type": "sequence<HIDReportItem>" }
    }
  },
  "HIDReportItem": {
    "inherits": null,
    "members": {
      "isAbsolute": { "type": "boolean" },
      "isArray": { "type": "boolean" },
      "isBufferedBytes": { "type": "boolean" },
      "isConstant": { "type": "boolean" },
      "isLinear": { "type": "boolean" },
      "isRange": { "type": "boolean" },
      "isVolatile": { "type": "boolean" },
      "hasNull": { "type": "boolean" },
      "hasPreferredState": { "type": "boolean" },
      "wrap": { "type": "boolean" },
      "usages": { "type": "sequence<unsigned long>" },
      "usageMinimum": { "type": "unsigned long" },
      "usageMaximum": { "type": "unsigned long" },
      "reportSize": { "type": "unsigned short" },
      "reportCount": { "type": "unsigned short" },
      "unitExponent": { "type": "byte" },
      "unitSystem": { "type": "HIDUnitSystem" },
      "unitFactorLengthExponent": { "type": "byte" },
      "unitFactorMassExponent": { "type": "byte" },
      "unitFactorTimeExponent": { "type": "byte" },
      "unitFactorTemperatureExponent": { "type": "byte" },
      "unitFactorCurrentExponent": { "type": "byte" },
      "unitFactorLuminousIntensityExponent": { "type": "byte" },
      "logicalMinimum": { "type": "long" },
      "logicalMaximum": { "type": "long" },
      "physicalMinimum": { "type": "long" },
      "physicalMaximum": { "type": "long" },
      "strings": { "type": "sequence<DOMString>" }
    }
  },
  "MIDIConnectionEventInit": {
    "inherits": "EventInit",
    "members": {
      "port": { "type": "MIDIPort" }
    }
  },
  "MIDIMessageEventInit": {
    "inherits": "EventInit",
    "members": {
      "data": { "type": "Uint8Array" }
    }
  },
  "MIDIOptions": {
    "inherits": null,
    "members": {
      "sysex": { "type": "boolean" },
      "software": { "type": "boolean" }
    }
  },
  "MidiPermissionDescriptor": {
    "inherits": "PermissionDescriptor",
    "members": {
      "sysex": { "type": "boolean" }
    }
  },
  "RequestDeviceOptions": {
    "inherits": null,
    "members": {
      "filters": { "type": "sequence<BluetoothLEScanFilterInit>" },
      "exclusionFilters": { "type": "sequence<BluetoothLEScanFilterInit>" },
      "optionalServices": { "type": "sequence<BluetoothServiceUUID>" },
      "optionalManufacturerData": { "type": "sequence<unsigned short>" },
      "acceptAllDevices": { "type": "boolean" }
    }
  },
  "SerialInputSignals": {
    "inherits": null,
    "members": {
      "dataCarrierDetect": { "type": "boolean", "required": true },
      "clearToSend": { "type": "boolean", "required": true },
      "ringIndicator": { "type": "boolean", "required": true },
      "dataSetReady": { "type": "boolean", "required": true }
    }
  },
  "SerialOptions": {
    "inherits": null,
    "members": {
      "baudRate": { "type": "unsigned long", "required": true },
      "dataBits": { "type": "octet" },
      "stopBits": { "type": "octet" },
      "parity": { "type": "ParityType" },
      "bufferSize": { "type": "unsigned long" },
      "flowControl": { "type": "FlowControlType" }
    }
  },
  "SerialOutputSignals": {
    "inherits": null,
    "members": {
      "dataTerminalReady": { "type": "boolean" },
      "requestToSend": { "type": "boolean" },
      "break": { "type": "boolean" }
    }
  },
  "SerialPortFilter": {
    "inherits": null,
    "members": {
      "usbVendorId": { "type": "unsigned short" },
      "usbProductId": { "type": "unsigned short" },
      "bluetoothServiceClassId": { "type": "BluetoothServiceUUID" }
    }
  },
  "SerialPortInfo": {
    "inherits": null,
    "members": {
      "usbVendorId": { "type": "unsigned short" },
      "usbProductId": { "type": "unsigned short" },
      "bluetoothServiceClassId": { "type": "BluetoothServiceUUID" }
    }
  },
  "SerialPortRequestOptions": {
    "inherits": null,
    "members": {
      "filters": { "type": "sequence<SerialPortFilter>" },
      "allowedBluetoothServiceClassIds": { "type": "sequence<BluetoothServiceUUID>" }
    }
  },
  "USBBlocklistEntry": {
    "inherits": null,
    "members": {
      "idVendor": { "type": "unsigned short", "required": true },
      "idProduct": { "type": "unsigned short", "required": true },
      "bcdDevice": { "type": "unsigned short", "required": true }
    }
  },
  "USBConnectionEventInit": {
    "inherits": "EventInit",
    "members": {
      "device": { "type": "USBDevice", "required": true }
    }
  },
  "USBControlTransferParameters": {
    "inherits": null,
    "members": {
      "requestType": { "type": "USBRequestType", "required": true },
      "recipient": { "type": "USBRecipient", "required": true },
      "request": { "type": "octet", "required": true },
      "value": { "type": "unsigned short", "required": true },
      "index": { "type": "unsigned short", "required": true }
    }
  },
  "USBDeviceFilter": {
    "inherits": null,
    "members": {
      "vendorId": { "type": "unsigned short" },
      "productId": { "type": "unsigned short" },
      "classCode": { "type": "octet" },
      "subclassCode": { "type": "octet" },
      "protocolCode": { "type": "octet" },
      "serialNumber": { "type": "DOMString" }
    }
  },
  "USBDeviceRequestOptions": {
    "inherits": null,
    "members": {
      "filters": { "type": "sequence<USBDeviceFilter>", "required": true },
      "exclusionFilters": { "type": "sequence<USBDeviceFilter>" }
    }
  },
  "USBPermissionDescriptor": {
    "inherits": "PermissionDescriptor",
    "members": {
      "filters": { "type": "sequence<USBDeviceFilter>" },
      "exclusionFilters": { "type": "sequence<USBDeviceFilter>" }
    }
  },
  "USBPermissionStorage": {
    "inherits": null,
    "members": {
      "allowedDevices": { "type": "sequence<AllowedUSBDevice>" }
    }
  },
  "ValueEventInit": {
    "inherits": "EventInit",
    "members": {
      "value": { "type": "any" }
    }
  },
  "WatchAdvertisementsOptions": {
    "inherits": null,
    "members": {
      "signal": { "type": "AbortSignal" }
    }
  }
};

export const enums = {
  "FlowControlType": ["none", "hardware"],
  "GamepadHapticEffectType": ["dual-rumble", "trigger-rumble"],
  "GamepadHapticsResult": ["complete", "preempted"],
  "GamepadMappingType": ["", "standard", "xr-standard"],
  "HIDUnitSystem": ["none", "si-linear", "si-rotation", "english-linear", "english-rotation", "vendor-defined", "reserved"],
  "MIDIPortConnectionState": ["open", "closed", "pending"],
  "MIDIPortDeviceState": ["disconnected", "connected"],
  "MIDIPortType": ["input", "output"],
  "ParityType": ["none", "even", "odd"],
  "USBDirection": ["in", "out"],
  "USBEndpointType": ["bulk", "interrupt", "isochronous"],
  "USBRecipient": ["device", "interface", "endpoint", "other"],
  "USBRequestType": ["standard", "class", "vendor"],
  "USBTransferStatus": ["ok", "stall", "babble"]
};

export const typedefs = {
  "BluetoothCharacteristicUUID": "(DOMString or unsigned long)",
  "BluetoothDescriptorUUID": "(DOMString or unsigned long)",
  "BluetoothServiceUUID": "(DOMString or unsigned long)",
  "DOMHighResTimeStamp": "unrestricted double",
  "UUID": "DOMString"
};

// The root objects of `web::root`: a path from the global object, and
// the interface of the object.
export const roots = {
  "navigator": "Navigator",
  "window": "Window",
  "navigator.bluetooth": "Bluetooth",
  "navigator.hid": "HID",
  "navigator.serial": "Serial",
  "navigator.usb": "USB"
};
