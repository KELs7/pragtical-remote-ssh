# server/src/protocol.nim
import std/[asyncnet, asyncdispatch, json, nativesockets]
import msgpack4nim/msgpack2json

proc recvExactly*(socket: AsyncSocket, size: int): Future[string] {.async.} =
  ## Safely loops until exactly `size` bytes are read from the stream.
  ## Pre-allocates the string size to prevent buffer reallocations during assembly.
  result = newString(size)
  var pos = 0
  while pos < size:
    let needed = size - pos
    let chunk = await socket.recv(needed)
    if chunk.len == 0:
      return "" # Socket closed
    copyMem(addr result[pos], addr chunk[0], chunk.len)
    pos += chunk.len

proc sendFramedMessage*(socket: AsyncSocket, payload: JsonNode) {.async.} =
  ## Packages a JSON-compatible payload into a single consolidated MessagePack 
  ## binary buffer prefixed with a 4-byte header and transmits it in one call.
  let mpData = fromJsonNode(payload)
  let length = mpData.len.uint32
  var networkLength = htonl(length)
  
  # Allocate single contiguous buffer for both the header and the binary payload.
  # This reduces allocation counts and eliminates a separate socket send.
  var message = newString(4 + mpData.len)
  copyMem(addr message[0], addr networkLength, 4)
  if mpData.len > 0:
    copyMem(addr message[4], addr mpData[0], mpData.len)
  
  await socket.send(message)

proc recvFramedMessage*(socket: AsyncSocket): Future[JsonNode] {.async.} =
  ## Reads a 4-byte header, decodes the size, and reads the full corresponding
  ## MessagePack binary payload, then converts it back into a native JsonNode.
  var headerBytes = ""
  try:
    headerBytes = await socket.recvExactly(4)
  except OSError:
    return nil

  if headerBytes.len < 4:
    return nil # Client disconnected or EOF reached
    
  var networkLength: uint32
  copyMem(addr networkLength, addr headerBytes[0], 4)
  
  # Convert network byte-order back to host CPU endianness to get the true string size
  let payloadSize = ntohl(networkLength).int
  if payloadSize <= 0:
    return nil
  
  var payloadBytes = ""
  try:
    payloadBytes = await socket.recvExactly(payloadSize)
  except OSError:
    return nil

  if payloadBytes.len < payloadSize:
    return nil # TCP stream disconnected prematurely
    
  try:
    result = toJsonNode(payloadBytes)
  except CatchableError:
    echo "[Protocol Error] Received malformed MessagePack binary payload"
    return nil