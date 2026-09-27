# server/src/main.nim
import std/[asyncnet, asyncdispatch, strutils, os, nativesockets, times]
import msgpack4nim/msgpack2any
import protocol, process_manager

proc handleRequest(clientSocket: AsyncSocket, req: MsgAny) {.async.} =
  ## Parses and routes actions requested by the local editor workspace
  let action = req.getField("action")
  let reqId = req.getField("id")
  echo "[Server] Action: ", action, " | Request ID: ", reqId

  case action
  of "list_dir":
    let path = req.getField("path")
    echo "[Server] list_dir Path: ", path
    var items = anyArray()
    try:
      for kind, item in walkDir(path, relative = true):
        items.arrayVal.add(mkMap({
          "name": anyString(item),
          "type": anyString(if kind == pcDir: "dir" else: "file")
        }))
      await clientSocket.sendFramedMessage(mkMap({
        "status": anyString("ok"),
        "action": anyString("list_dir"),
        "id": anyString(reqId),
        "items": items
      }))
    except CatchableError as e:
      echo "[Server] list_dir failed: ", path, " | Error: ", e.msg
      await clientSocket.sendFramedMessage(mkMap({
        "status": anyString("error"),
        "action": anyString("list_dir"),
        "id": anyString(reqId),
        "message": anyString("Failed to read path: " & e.msg)
      }))

  of "change_dir":
    let path = req.getField("path")
    echo "[Server] Change directory request: ", path
    try:
      setCurrentDir(path)
      await clientSocket.sendFramedMessage(mkMap({
        "status": anyString("ok"),
        "action": anyString("change_dir"),
        "id": anyString(reqId),
        "cwd": anyString(getCurrentDir())
      }))
    except CatchableError as e:
      echo "[Server] change_dir failed: ", path, " | Error: ", e.msg
      await clientSocket.sendFramedMessage(mkMap({
        "status": anyString("error"),
        "action": anyString("change_dir"),
        "id": anyString(reqId),
        "message": anyString("Failed to change directory: " & e.msg)
      }))

  of "read_file":
    let path = req.getField("path")
    echo "[Server] Read file request: ", path
    try:
      let content = readFile(path)
      await clientSocket.sendFramedMessage(mkMap({
        "status": anyString("ok"),
        "action": anyString("read_file"),
        "id": anyString(reqId),
        "path": anyString(path),
        "content": anyString(content)
      }))
    except CatchableError as e:
      echo "[Server] Read file failed: ", path, " | Error: ", e.msg
      await clientSocket.sendFramedMessage(mkMap({
        "status": anyString("error"),
        "action": anyString("read_file"),
        "id": anyString(reqId),
        "message": anyString("File read failed: " & e.msg)
      }))

  of "save_file":
    let path = req.getField("path")
    let content = req.getField("content")
    echo "[Server] Save file request: ", path
    try:
      writeFile(path, content)
      await clientSocket.sendFramedMessage(mkMap({
        "status": anyString("ok"),
        "action": anyString("save_file"),
        "id": anyString(reqId),
        "path": anyString(path)
      }))
    except CatchableError as e:
      echo "[Server] Save file failed: ", path, " | Error: ", e.msg
      await clientSocket.sendFramedMessage(mkMap({
        "status": anyString("error"),
        "action": anyString("save_file"),
        "id": anyString(reqId),
        "message": anyString("File write failed: " & e.msg)
      }))

  of "file_info":
    let path = req.getField("path")
    try:
      let info = getFileInfo(path)
      await clientSocket.sendFramedMessage(mkMap({
        "status": anyString("ok"),
        "action": anyString("file_info"),
        "id": anyString(reqId),
        "modified": anyFloat(info.lastWriteTime.toUnixFloat()),
        "size": anyInt(info.size),
        "type": anyString(if info.kind == pcDir: "dir" else: "file")
      }))
    except CatchableError as e:
      await clientSocket.sendFramedMessage(mkMap({
        "status": anyString("error"),
        "action": anyString("file_info"),
        "id": anyString(reqId),
        "message": anyString(e.msg)
      }))

  of "make_dir":
    let path = req.getField("path")
    echo "[Server] Make directory request: ", path
    try:
      createDir(path)
      await clientSocket.sendFramedMessage(mkMap({
        "status": anyString("ok"),
        "action": anyString("make_dir"),
        "id": anyString(reqId),
        "path": anyString(path)
      }))
    except CatchableError as e:
      echo "[Server] make_dir failed: ", path, " | Error: ", e.msg
      await clientSocket.sendFramedMessage(mkMap({
        "status": anyString("error"),
        "action": anyString("make_dir"),
        "id": anyString(reqId),
        "message": anyString("Directory creation failed: " & e.msg)
      }))

  of "spawn":
    let cmd = req.getField("cmd")
    let procId = req.getField("id")
    let workDir = req.getField("dir")
    let dir = if workDir == "": getCurrentDir() else: workDir

    let ok = spawnProcessAsync(clientSocket, cmd, dir, procId)
    if ok:
      await clientSocket.sendFramedMessage(mkMap({
        "status": anyString("ok"),
        "action": anyString("spawn"),
        "id": anyString(reqId),
        "procId": anyString(procId)
      }))
    else:
      await clientSocket.sendFramedMessage(mkMap({
        "status": anyString("error"),
        "action": anyString("spawn"),
        "id": anyString(reqId),
        "procId": anyString(procId),
        "message": anyString("Execution failed on host server")
      }))

  of "get_cwd":
    try:
      await clientSocket.sendFramedMessage(mkMap({
        "status": anyString("ok"),
        "action": anyString("get_cwd"),
        "id": anyString(reqId),
        "cwd": anyString(getCurrentDir())
      }))
    except CatchableError as e:
      await clientSocket.sendFramedMessage(mkMap({
        "status": anyString("error"),
        "action": anyString("get_cwd"),
        "id": anyString(reqId),
        "message": anyString(e.msg)
      }))

  else:
    echo "[Server] Received unknown action: ", action
    await clientSocket.sendFramedMessage(mkMap({
      "status": anyString("error"),
      "id": anyString(reqId),
      "message": anyString("Unknown requested command action: " & action)
    }))

proc handleClientConnection(clientSocket: AsyncSocket) {.async.} =
  ## Coordinates async packet receipt for an editor client
  echo "[Server] New editor client connected!"
  while true:
    let req = await clientSocket.recvFramedMessage()
    if req == nil:
      echo "[Server] Client disconnected."
      clientSocket.close()
      quit(0)

    await handleRequest(clientSocket, req)

proc main() =
  var port = 8080
  let args = commandLineParams()
  if args.len > 0:
    try:
      port = parseInt(args[0])
    except ValueError:
      discard

  let serverSocket = newAsyncSocket()
  serverSocket.setSockOpt(OptReuseAddr, true)
  # Disable Nagle's algorithm: this protocol is dominated by small
  # synchronous request/response exchanges, which delayed-ACK interplay
  # otherwise stretches to ~40 ms per round-trip. TCP_NODELAY lives at the
  # IPPROTO_TCP level, not the default SOL_SOCKET level.
  serverSocket.setSockOpt(OptNoDelay, true, level = IPPROTO_TCP.cint)

  try:
    serverSocket.bindAddr(Port(port))
    serverSocket.listen()
    echo "[Server] Headless Workspace Agent running on port ", port, "..."
  except OSError as e:
    quit("[Fatal] Server failed to bind: " & e.msg, 1)

  proc serve() {.async.} =
    while true:
      let clientSocket = await serverSocket.accept()
      # Accepted sockets do not inherit TCP_NODELAY on all platforms; set it
      # per-connection as well (IPPROTO_TCP level).
      clientSocket.setSockOpt(OptNoDelay, true, level = IPPROTO_TCP.cint)
      asyncCheck handleClientConnection(clientSocket)

  asyncCheck serve()
  runForever()

if isMainModule:
  main()
