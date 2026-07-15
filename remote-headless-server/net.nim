# server/src/net.nim

import std/nativesockets
when defined(windows):
  import std/winlean
  # Bind directly to low-level WinSock send/recv
  proc send*(s: SocketHandle, buf: pointer, len: cint, flags: cint): cint {.stdcall, importc: "send", dynlib: "ws2_32.dll".}
  proc recv*(s: SocketHandle, buf: pointer, len: cint, flags: cint): cint {.stdcall, importc: "recv", dynlib: "ws2_32.dll".}
else:
  import posix

type SocketType* = SocketHandle
const InvalidSocket* = SocketHandle(-1)

var netClientSock*: SocketType = InvalidSocket
var isServerMode*: bool = true

proc netInit*() =
  # std/net's initialization is handled on startup; winsock starts up here for raw sockets
  when defined(windows):
    var wsa: winlean.WSAData
    discard winlean.wsaStartup(0x0202, addr wsa)

proc netCleanup*() =
  when defined(windows):
    discard winlean.wsaCleanup()

proc netSetNonblocking*(sock: SocketType) =
  setBlocking(sock, false)

proc close*(s: SocketType) =
  if s != InvalidSocket:
    when defined(windows):
      discard winlean.closesocket(s)
    else:
      discard posix.close(s.cint)

proc netSendAll*(sock: SocketType, buf: pointer, len: int): bool =
  var p = cast[ptr byte](buf)
  var remaining = len
  while remaining > 0:
    let sent =
      when defined(windows):
        send(sock, p, remaining.cint, 0)
      else:
        posix.send(sock, p, remaining, 0.cint)
    if sent <= 0:
      return false
    p = cast[ptr byte](cast[uint](p) + sent.uint)
    remaining -= sent
  return true

proc netRecvAll*(sock: SocketType, buf: pointer, len: int): bool =
  var p = cast[ptr byte](buf)
  var remaining = len
  while remaining > 0:
    let recvd =
      when defined(windows):
        recv(sock, p, remaining.cint, 0)
      else:
        posix.recv(sock, p, remaining, 0.cint)
    if recvd <= 0:
      return false
    p = cast[ptr byte](cast[uint](p) + recvd.uint)
    remaining -= recvd
  return true

proc netSendVal*[T](sock: SocketType, val: T): bool {.inline.} =
  var v = val
  netSendAll(sock, addr v, sizeof(T))
