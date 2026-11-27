// The roots of `web::root` and the types of other specs that the IDL of
// the groups uses. This file is part of ztcl, and it is not a copy of a
// spec. Its interfaces have no group.

interface Window {};
interface Navigator {};
interface WorkerNavigator {};
interface mixin WindowEventHandlers {};
Window includes WindowEventHandlers;
typedef unrestricted double DOMHighResTimeStamp;
