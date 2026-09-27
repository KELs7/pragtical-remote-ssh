# server/src/protocol.nim
import std/[asyncnet, asyncdispatch, nativesockets, tables]
import msgpack4nim/msgpack2any

proc recvExactly*(socket: AsyncSocket, size: int): Future[string] {.async.} =
  ## Safely loops until exactly `size` bytes are read from the stream.
  ## Pre-allocates the string and reads each TCP segment straight into it
  ## (recvInto), avoiding a transient string allocation per segment.
  result = newString(size)
  var pos = 0
  while pos < size:
    let needed = size - pos
    let read = await socket.recvInto(addr result[pos], needed)
    if read == 0:
      return "" # Socket closed
    pos += read

proc sendFramedMessage*(socket: AsyncSocket, payload: MsgAny) {.async.} =
  ## Packages a MsgAny payload into a single consolidated MessagePack
  ## binary buffer prefixed with a 4-byte header and transmits it in one call.
  ## Encoded directly with fromAny -- no JSON DOM round-trip.
  let mpData = fromAny(payload)
  let length = mpData.len.uint32
  var networkLength = htonl(length)

  # Allocate single contiguous buffer for both the header and the binary payload.
  var message = newString(4 + mpData.len)
  copyMem(addr message[0], addr networkLength, 4)
  if mpData.len > 0:
    copyMem(addr message[4], addr mpData[0], mpData.len)

  await socket.send(message)

proc recvFramedMessage*(socket: AsyncSocket): Future[MsgAny] {.async.} =
  ## Reads a 4-byte header, decodes the size, and reads the full corresponding
  ## MessagePack binary payload, then decodes it directly into a native MsgAny.
  var headerBytes = ""
  try:
    headerBytes = await socket.recvExactly(4)
  except OSError:
    return nil

  if headerBytes.len < 4:
    return nil # Client disconnected or EOF reached

  var networkLength: uint32
  copyMem(addr networkLength, addr headerBytes[0], 4)

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
    result = toAny(payloadBytes)
  except CatchableError:
    echo "[Protocol Error] Received malformed MessagePack binary payload"
    return nil

# -----------------------------------------------------------------------
# MsgAny construction/access helpers (replace the previous JSON DOM use)
# -----------------------------------------------------------------------

proc mkMap*(args: varargs[(string, MsgAny)]): MsgAny =
  ## Builds a MsgAny map from string-keyed pairs.
  result = anyMap(args.len)
  for (k, v) in args:
    result.mapVal[anyString(k)] = v

proc getField*(req: MsgAny, name: string): string =
  ## Returns a string field from a MsgAny map ("" when absent or not a string).
  if req != nil and req.kind == msgMap:
    let v = req.mapVal.getOrDefault(anyString(name))
    if v != nil and v.kind == msgString:
      return v.stringVal
  return ""
