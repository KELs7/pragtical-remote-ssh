# server/src/process_manager.nim
{.push hint[ConvFromXtoItselfNotNeeded]: off.}

import std/[osproc, streams, os, nativesockets, asyncnet]
import msgpack4nim/msgpack2any
import protocol

when defined(windows):
  import std/winlean
  proc send*(s: SocketHandle, buf: pointer, len: cint, flags: cint): cint {.stdcall, importc: "send", dynlib: "ws2_32.dll".}
else:
  import posix

proc rawSendAll(fd: SocketHandle, buf: pointer, size: int): bool =
  ## Loops to transmit exactly `size` bytes to raw SocketHandle
  var p = cast[ptr byte](buf)
  var remaining = size
  while remaining > 0:
    let sent =
      when defined(windows):
        send(fd, p, remaining.cint, 0)
      else:
        posix.send(fd, p, remaining, 0.cint)
    if sent <= 0:
      return false
    p = cast[ptr byte](cast[uint](p) + sent.uint)
    remaining -= sent
  return true

type
  # We define ThreadArgs with primitive systems types to bypass GC reference count tracking
  ThreadArgs = tuple[
    processPtr: pointer,
    socketFd: SocketHandle,
    id: string
  ]

  # ProcessContext is now a heap-allocated ref object. This guarantees
  # its memory address and running thread handle remain stable.
  ProcessContext* = ref object
    id*: string
    process*: Process
    readerThread*: Thread[ThreadArgs]

# Define a global table to keep track of running processes on the server
var activeProcesses* = newSeq[ProcessContext]()

# Frames and transmits one process_output event over the raw socket fd.
proc sendOutputEvent(socketFd: SocketHandle, id: string, chunk: string): bool =
  let eventPayload = mkMap({
    "event": anyString("process_output"),
    "id": anyString(id),
    "data": anyString(chunk)
  })

  try:
    let mpData = fromAny(eventPayload)
    var netLength = nativesockets.htonl(mpData.len.uint32)

    var message = newString(4 + mpData.len)
    copyMem(addr message[0], addr netLength, 4)
    if mpData.len > 0:
      copyMem(addr message[4], addr mpData[0], mpData.len)

    return rawSendAll(socketFd, addr message[0], message.len)
  except CatchableError:
    return false # Socket closed by parent main thread

# This procedure executes on an independent background thread.
proc processStreamReader(args: ThreadArgs) {.thread.} =
  # Safely cast the raw pointer back to Process without triggering RC updates
  let p = cast[Process](args.processPtr)
  let socketFd = args.socketFd
  let id = args.id
  let outputStream = p.outputStream

  # Allocate a reuseable buffer for chunked reading (4KB is optimal for pipe transport)
  var buffer = newString(4096)

  # Blocking read loop: waits for data or EOF (the pipe's write end closes
  # when the process exits), so output is forwarded immediately with no
  # 5 ms polling delay and no ~200 wakeups/s while the terminal is idle.
  # Doubles as the post-exit drain loop -- no final stdout chunks are
  # truncated on process exit.
  while true:
    let bytesRead = outputStream.readData(addr buffer[0], 4096)
    if bytesRead <= 0:
      break # EOF: process (and all children holding the pipe) exited

    if not sendOutputEvent(socketFd, id, buffer[0 ..< bytesRead]):
      break

  # Thread exits once the pipe is drained, notifying the client
  let exitCode = p.peekExitCode()
  let exitPayload = mkMap({
    "event": anyString("process_exit"),
    "id": anyString(id),
    "exitCode": anyInt(exitCode.int64)
  })

  try:
    let mpData = fromAny(exitPayload)
    var netLength = nativesockets.htonl(mpData.len.uint32)

    var message = newString(4 + mpData.len)
    copyMem(addr message[0], addr netLength, 4)
    if mpData.len > 0:
      copyMem(addr message[4], addr mpData[0], mpData.len)

    discard rawSendAll(socketFd, addr message[0], message.len)
  except CatchableError:
    discard

  p.close()

proc spawnProcessAsync*(socket: AsyncSocket, cmd: string, workDir: string, procId: string): bool =
  ## Launches a process asynchronously and spawns its tracking thread safely
  try:
    # Start process with combined standard error and stdout pipelines
    let p = startProcess(
      cmd,
      workDir,
      options = {poStdErrToStdOut, poUsePath, poEvalCommand}
    )

    # Allocate our context directly on the heap
    let context = ProcessContext(id: procId, process: p)

    # Extract raw primitives to safely cross the thread boundary
    let processPtr = cast[pointer](p)
    let socketFd = socket.getFd()

    # Spawn the background thread using context.readerThread's stable address
    createThread(
      context.readerThread,
      processStreamReader,
      (processPtr, socketFd, procId)
    )

    activeProcesses.add(context)
    return true
  except CatchableError as e:
    echo "[Process Error] Failed to launch command: ", cmd, " error: ", e.msg
    return false

{.pop.}
