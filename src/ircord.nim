# Stdlib
import strformat, strutils, sequtils, json
import httpclient, asyncdispatch, tables, options
# Nimble
import discordnim/discordnim, irc
# Our modules
import config

# Global configuration object
var conf: Config
# Global Discord shard
var discord: Shard
# Global IRC client
var ircClient: AsyncIrc

var msgCreateHandler: (proc())
var msgUpdateHandler: (proc())
# Sequence of all webhook IDs we use
var webhooks = newSeq[string]()

# Two global variables for "irc: webhook" and "channelId: irc" tables. 
var ircToWebhook = newTable[string, string]()
var discordToIrc = newTable[string, string]()

proc sendWebhook(ircChan, username, content: string) {.async.} = 
  ## Send a message to a channel on Discord using webhook url
  ## with provided username and message content.
  let client = newAsyncHttpClient()
  client.headers = newHttpHeaders({"Content-Type": "application/json"})
  let data = $(%*{"username": username, "content": content})
  let resp = await client.post(ircToWebhook[ircChan], data)
  client.close()

proc parseIrcMessage(nick, msg: var string): bool = 
  result = true
  # Replace some special chars or strings
  # also replaces IRC characters used for styling
  msg = msg.multiReplace({
    "ACTION": "", 
    "\n": "↵", "\r": "↵", "\l": "↵",
    "\1": "", "\x02": "", "\x0F": ""
  })
  # Just in a rare case we accidentally start this bot in #nim
  if nick == "FromDiscord": return false
  # Special cases for the Gitter <-> IRC bridge
  elif nick == "FromGitter":
    # Get something like @["<Yardanico", " this is a test"]
    var data = msg.split(">", 1)
    # Probably can't happen
    if data.len != 2: return false

    (nick, msg) = (data[0][1..^1] & "[Gitter]", data[1].strip())
    # A really rare case if someone's using the Matrix <-> Gitter bridge
    if "matrixbot" in msg:
      # Split message by ` to get 
      # @["", "grantmwilliams` like google & golang or mozilla & rust"]
      # then split the second value in seq again to get
      # @["grantmwilliams", " like google & golang or mozilla & rust"]
      data = msg.split("`", 1)[1].split("`", 1)
      (nick, msg) = (data[0] & "[Matrix]", data[1].strip())
  # Freenode <-> Matrix bridge
  elif "[m]" in nick:
    nick = nick.replace("[m]", "[Matrix]")
  else:
    # Specify (in the username) that this user is from IRC
    nick &= "[IRC]"

proc handleIrc(client: AsyncIrc, event: IrcEvent) {.async.} = 
  ## Handles all events received by IRC client instance
  if event.typ != EvMsg or event.params.len < 2:
    return
  
  # Check that it's a message sent to the channel
  elif event.cmd != MPrivMsg or event.params[0][0] != '#': return
  
  let ircChan = event.origin

  var (nick, msg) = (event.nick, event.params[1])
  echo event
  
  if not parseIrcMessage(nick, msg): return

  asyncCheck sendWebhook(ircChan, nick, msg)

proc createPaste*(data: string): Future[Option[string]] {.async.} =
  ## Creates a paste with `data` on ix.io and returns some(string)
  ## If pasting failed, returns none
  result = none(string)
  var client = newAsyncHttpClient()
  let data = "f:1=" & data
  try:
    let resp = await client.post("http://ix.io", data)
    if resp.code == Http200: 
      result = some(strip(await resp.body))
  except OSError:
    discard
  client.close()

proc checkMessage(m: Message): Option[string] = 
  result = none(string)
  # Don't handle messages which are sent by our own webhooks
  if m.webhook_id.get("") in webhooks: return
  # Check if we have that channel_id in our discordToIrc mapping
  let ircChan = discordToIrc.getOrDefault(m.channel_id, "")
  if ircChan == "": return
  result = some(ircChan)

proc handleMsgAttaches*(m: Message): string =
  result = ""
  if m.attachments.len > 0:
    result = "("
    for i, attach in m.attachments:
      result &= &"attachment {i+1}: {attach.url} "
    result = result.strip() & ")"

proc handleMsgPaste*(m: Message, msg: string): Future[string] {.async.} = 
  ## Handles pastes or big messages
  result = msg
  if not ("```" in result or result.count("\n") > 2 or result.len > 500):
    return
  
  let paste = await createPaste(result)
  if paste.isSome():
    result = &"Code paste (or a big message), see {paste.get()}"
  else:
    let url = &"https://discordapp.com/channels/{m.guild_id.get()}/{m.channel_id}/{m.id}"
    result = &"Code paste (or a big message), see {url}"

var msgEditHistory = newTable[string, seq[Message]]()
var msgEditOrder = newTable[string, int]()

proc getOriginalMsg(cid, mid: string): Option[Message] = 
  result = none(Message)
  for msg in msgEditHistory[cid]:
    if msg.id == mid:
      return some(msg)

proc msgHistoryStore(m: Message) = 
  # Store last 10 messages in history for each channel
  var lastEditId = msgEditOrder[m.channel_id] 
  msgEditHistory[m.channel_id][lastEditId] = m
  msgEditOrder[m.channel_id] = if lastEditId > 9: 0 else: lastEditId + 1

proc messageUpdate(s: Shard, m: MessageUpdate) {.async.} =
  ## Called when a message is edited in Discord
  let check = checkMessage(m)
  if not check.isSome(): return
  let ircChan = check.get()
  echo m
  
  let oldMsg = getOriginalMsg(m.channel_id, m.id)
  # Don't know how to handle edited messages yet
  if oldMsg.isSome(): discard
  msgHistoryStore(m)

  var msg = m.content
  msg &= m.handleMsgAttaches()
  msg = await m.handleMsgPaste(msg)

  # Use bold styling to highlight the username
  let toSend = &"\x02<{m.author.username}>\x0F (edited) {msg}"
  await ircClient.privmsg(ircChan, toSend)

proc messageCreate(s: Shard, m: MessageUpdate) {.async.} =
  ## Called when a new message is posted in Discord
  let check = checkMessage(m)
  if not check.isSome(): return
  let ircChan = check.get()
  echo m

  # Store last 10 messages in history for each channel
  msgHistoryStore(m)

  var msg = m.content
  msg &= m.handleMsgAttaches()
  msg = await m.handleMsgPaste(msg)

  # Use bold styling to highlight the username
  let toSend = &"\x02<{m.author.username}>\x0F {msg}"
  await ircClient.privmsg(ircChan, toSend)

proc startDiscord() {.async.} = 
  ## Starts the Discord client instance and connects 
  ## using token from the configuration.
  discord = newShard("Bot " & conf.discord.token)
  msgCreateHandler = discord.addHandler(EventType.message_create, messageCreate)
  msgUpdateHandler = discord.addHandler(EventType.message_update, messageUpdate)
  await discord.startSession()

proc startIrc() {.async.} = 
  ## Starts the IRC client and connects to the server and 
  ## joins channels specified in the configuration.
  ircClient = newAsyncIrc(
    address = conf.irc.server,
    port = Port(conf.irc.port),
    nick = conf.irc.nickname,
    serverPass = conf.irc.password,
    # All IRC channels we need to connect to
    joinChans = conf.mapping.mapIt(it.irc), 
    callback = handleIrc
  )
  await ircClient.connect()
  await sleepAsync(3000)
  await ircClient.run()

proc main() {.async.} = 
  echo "Starting Ircord (wait up to 10 seconds)..."
  conf = parseConfig()
  # Fill global variables
  for entry in conf.mapping:
    # Get webhook ID (to check for it before sending a message to IRC)
    webhooks.add(entry.webhook.split("webhooks/")[1].split("/")[0])

    ircToWebhook[entry.irc] = entry.webhook
    discordToIrc[entry.discord] = entry.irc
    # Init edit history for that Discord channel
    msgEditHistory[entry.discord] = newSeq[Message](10)
    msgEditOrder[entry.discord] = 0

  asyncCheck startDiscord()
  # Block until startIrc exits
  await startIrc()

proc hook() {.noconv.} = 
  echo "Quitting Ircord..."
  waitFor discord.disconnect()
  ircClient.close()
  quit(0)

setControlCHook(hook)
waitFor main()