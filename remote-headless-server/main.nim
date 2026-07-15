# server/src/main.nim
import std/[asyncnet, asyncdispatch, strutils, os, json, times]
import protocol, process_manager

proc handleRequest(clientSocket: AsyncSocket, req: JsonNode) {.async.} =
  ## Parses and routes actions requested by the local editor workspace
  let action = req.getOrDefault("action").getStr()
  let reqId = req.getOrDefault("id").getStr()
  echo "[Server] Action: ", action, " | Request ID: ", reqId
  
  case action
  of "list_dir":
    let path = req.getOrDefault("path").getStr()
    echo "[Server] list_dir Path: ", path
    var items = newJArray()
    try:
      for kind, item in walkDir(path, relative = true):
        items.add(%* {
          "name": item,
          "type": if kind == pcDir: "dir" else: "file"
        })
      await clientSocket.sendFramedMessage(%* {
        "status": "ok",
        "action": "list_dir",
        "id": reqId,
        "items": items
      })
    except CatchableError as e:
      echo "[Server] list_dir failed: ", path, " | Error: ", e.msg
      await clientSocket.sendFramedMessage(%* {
        "status": "error",
        "action": "list_dir",
        "id": reqId,
        "message": "Failed to read path: " & e.msg
      })

  of "change_dir":
    let path = req.getOrDefault("path").getStr()
    echo "[Server] Change directory request: ", path
    try:
      setCurrentDir(path)
      await clientSocket.sendFramedMessage(%* {
        "status": "ok",
        "action": "change_dir",
        "id": reqId,
        "cwd": getCurrentDir()
      })
    except CatchableError as e:
      echo "[Server] change_dir failed: ", path, " | Error: ", e.msg
      await clientSocket.sendFramedMessage(%* {
        "status": "error",
        "action": "change_dir",
        "id": reqId,
        "message": "Failed to change directory: " & e.msg
      })

  of "read_file":
    let path = req.getOrDefault("path").getStr()
    echo "[Server] Read file request: ", path
    try:
      let content = readFile(path)
      await clientSocket.sendFramedMessage(%* {
        "status": "ok",
        "action": "read_file",
        "id": reqId,
        "path": path,
        "content": content
      })
    except CatchableError as e:
      echo "[Server] Read file failed: ", path, " | Error: ", e.msg
      await clientSocket.sendFramedMessage(%* {
        "status": "error",
        "action": "read_file",
        "id": reqId,
        "message": "File read failed: " & e.msg
      })

  of "save_file":
    let path = req.getOrDefault("path").getStr()
    let content = req.getOrDefault("content").getStr()
    echo "[Server] Save file request: ", path
    try:
      writeFile(path, content)
      await clientSocket.sendFramedMessage(%* {
        "status": "ok",
        "action": "save_file",
        "id": reqId,
        "path": path
      })
    except CatchableError as e:
      echo "[Server] Save file failed: ", path, " | Error: ", e.msg
      await clientSocket.sendFramedMessage(%* {
        "status": "error",
        "action": "save_file",
        "id": reqId,
        "message": "File write failed: " & e.msg
      })

  of "file_info":
    let path = req.getOrDefault("path").getStr()
    try:
      let info = getFileInfo(path)
      await clientSocket.sendFramedMessage(%* {
        "status": "ok",
        "action": "file_info",
        "id": reqId,
        "modified": info.lastWriteTime.toUnixFloat(),
        "size": info.size,
        "type": if info.kind == pcDir: "dir" else: "file"
      })
    except CatchableError as e:
      await clientSocket.sendFramedMessage(%* {
        "status": "error",
        "action": "file_info",
        "id": reqId,
        "message": e.msg
      })

  of "spawn":
    let cmd = req.getOrDefault("cmd").getStr()
    let procId = req.getOrDefault("id").getStr()
    let workDir = req.getOrDefault("dir").getStr(getCurrentDir())
    
    let ok = spawnProcessAsync(clientSocket, cmd, workDir, procId)
    if ok:
      await clientSocket.sendFramedMessage(%* {
        "status": "ok",
        "action": "spawn",
        "id": reqId,
        "procId": procId
      })
    else:
      await clientSocket.sendFramedMessage(%* {
        "status": "error",
        "action": "spawn",
        "id": reqId,
        "procId": procId,
        "message": "Execution failed on host server"
      })

  of "get_cwd":
    try:
      await clientSocket.sendFramedMessage(%* {
        "status": "ok",
        "action": "get_cwd",
        "id": reqId,
        "cwd": getCurrentDir()
      })
    except CatchableError as e:
      await clientSocket.sendFramedMessage(%* {
        "status": "error",
        "action": "get_cwd",
        "id": reqId,
        "message": e.msg
      })

  else:
    echo "[Server] Received unknown action: ", action
    await clientSocket.sendFramedMessage(%* {
      "status": "error",
      "id": reqId,
      "message": "Unknown requested command action: " & action
    })

proc handleClientConnection(clientSocket: AsyncSocket) {.async.} =
  ## Coordinates async packet receipt for an editor client
  echo "[Server] New editor client connected!"
  while true:
    let req = await clientSocket.recvFramedMessage()
    if req == nil:
      echo "[Server] Client disconnected."
      clientSocket.close()
      quit(0) # <--- Changed from quit(0) to break so only the task exits
    
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
  
  try:
    serverSocket.bindAddr(Port(port))
    serverSocket.listen()
    echo "[Server] Headless Workspace Agent running on port ", port, "..."
  except OSError as e:
    quit("[Fatal] Server failed to bind: " & e.msg, 1)

  proc serve() {.async.} =
    while true:
      let clientSocket = await serverSocket.accept()
      asyncCheck handleClientConnection(clientSocket)

  asyncCheck serve()
  runForever()

if isMainModule:
  main()
