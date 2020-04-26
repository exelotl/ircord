# Stdlib
import strformat, strutils, sequtils, json, strscans
import httpclient, asyncdispatch, tables, options
import math
# Nimble
import dimscord, irc, diff
# Our modules
import config, utils

# Global configuration object
var conf: Config
# Global Discord shard
var discord: DiscordClient
# Global IRC client
var ircClient: AsyncIrc

# Sequence of all webhook IDs we use
var webhooks = newSeq[string]()

# Two global variables for "irc: webhook" and "channelId: irc" tables.
var ircToWebhook = newTable[string, string]()
var discordToIrc = newTable[string, string]()

var msgEditHistory = newTable[string, seq[Message]]()
var msgEditOrder = newTable[string, int]()

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
  if nick == "FromDiscord": result = false
  # Special case for the Gitter <-> IRC bridge
  elif nick == "FromGitter":
    # Parse FromGitter message
    if scanf(msg, "<$+> $+", nick, msg):
      nick &= "[Gitter]"
    # Shouldn't happen anyway
    else: result = false
    # Special case for Gitter <-> Matrix bridge (very rare)
    if "matrixbot" in msg:
      if scanf(msg, "<matrixbot> `$+` $+", nick, msg):
        nick &= "[Matrix]"
      # Shouldn't happen either
      else: result = false
  # Freenode <-> Matrix bridge
  elif "[m]" in nick:
    nick = nick.replace("[m]", "[Matrix]")
  else:
    # Specify (in the username) that this user is from IRC
    nick &= "[IRC]"

proc handleCmds(chan: string, nick, msg: string): Future[bool] {.async.} =
  result = false
  # Only accept commands from whitelisted users and only with !
  if nick notin conf.irc.adminList or msg[0] != '!': return
  let data = msg.split(" ")
  if data.len == 0: return
  case data[0]
  # Gets a Discord UID of all users which match the string
  of "!getdiscid":
    result = true
    if data.len < 2:
      await ircClient.privmsg(chan, "Usage: !getid Username#1234")
      return
    let username = data[1..^1].join(" ")
    let users = await discord.getUsers(conf.discord.guild, username)
    var toSend = ""
    if users.len == 1: toSend = $users[0] & " has Discord UID: " & users[0].id
    elif users.len > 1: 
      for user in users:
        toSend &= $user & " has Discord UID " & user.id & ", "
    else: toSend = "Unknown username"
    await ircClient.privmsg(chan, toSend)
  # Gets a Discord UID of a user who sent the last message on Discord
  # in the current channel
  of "!getlastid":
    result = true
    var chanId = ""
    for (id, irc) in discordToIrc.pairs():
      if irc == chan: 
        chanId = id
        break
    var orderId = msgEditOrder.getOrDefault(chanId, -1)
    if chanId != "" and orderId != -1: 
      # Find last sent or edited message
      orderId = if orderId != 0: orderId - 1 else: 9
      var msg = msgEditHistory.getOrDefault(chanId)[orderId]
      if true:
        let u = msg.author
        await ircClient.privmsg(
          chan, "UID of $1 who sent/edited a message most recently is $2" % [$u, u.id]
        )
      else:
        await ircClient.privmsg(
          chan, "Can't find the user who sent the last message?!"
        )
    else:
      await ircClient.privmsg(chan, "This channel doesn't seem to be bridged?")
  # Bans a Discord user by UID
  of "!bandisc":
    result = true
    if data.len < 2:
      await ircClient.privmsg(chan, "Usage: !ban 174365113899057152")
      return
    var id = try: $parseInt(data[1]) except: ""
    if id != "":
      await discord.api.createGuildBan(conf.discord.guild, id)
      await ircClient.privmsg(chan, "User with UID " & $id & " was banned on Discord!")
    else:
      await ircClient.privmsg(chan, "Unknown UID")
  else: discard

proc handleIrc(client: AsyncIrc, event: IrcEvent) {.async.} =
  ## Handles all events received by IRC client instance
  if event.typ != EvMsg or event.params.len < 2:
    return

  # Check that it's a message sent to the channel
  elif event.cmd != MPrivMsg or event.params[0][0] != '#': return

  let ircChan = event.origin

  var (nick, msg) = (event.nick, event.params[1])
  #echo event

  # Don't send commands or their output to Discord
  if (await handleCmds(ircChan, nick, msg)): return

  if parseIrcMessage(nick, msg):
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
  if m.webhook_id in webhooks: return
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
    # Post a link to the message on Discord
    let url = &"https://discordapp.com/channels/{m.guild_id}/{m.channel_id}/{m.id}"
    result = &"Code paste (or a big message), see {url}"

proc msgHandleMentions(m: Message, msg: string): string =
  ## Replace ID mentions with proper username (without discriminator)
  result = msg
  for user in m.mention_users:
    let origHandle = "<@!" & $user.id & ">"
    result = result.replace(origHandle, "@" & $user.username)

proc processMsg(m: Message): Future[string] {.async.} =
  ## Does all needed modifications on message conents before sending it
  # Store last 10 messages in history for each channel

  result = m.content
  result &= m.handleMsgAttaches()
  result = msgHandleMentions(m, result)
  result = await m.handleMsgPaste(result)

var lastMsgs = newSeq[int](3)

proc messageUpdate(s: Shard, m: Message, old: Option[Message], exists: bool) {.async.} =
  ## Called when a message is edited in Discord
  let check = checkMessage(m)
  if not check.isSome(): return
  let ircChan = check.get()

  var msg = await m.processMsg()
  if old.isSome():
    let oldContent = (await old.get().processMsg()).split()
    let newContent = msg.split()
    var newmsgs = newSeqOfCap[string](oldContent.len)
    # Some content diffing to produce an edited message
    let slices = toSeq(spanSlices(oldContent, newContent))
    for i, span in slices:
      var newmsg = ""
      # thanks leorize on IRC for suggesting this edit format
      case span.tag
      of tagReplace:
        newmsg.add "'$1' => '$2'".format(span.a.join(" "), span.b.join(" "))
      # We only send diff so we don't care if spans are equal
      of tagEqual:
        discard
      of tagDelete:
        newmsg.add "removed '$1'".format(span.a.join(" "))
      of tagInsert:
        if i != 0:
          # stuff ...  -> stuff new ...
          newmsg.add "'"
          # at max 2 words for context from the left
          let start = max(i - 2, 0)
          for slice in slices[start .. i - 1]:
            newmsg.add slice.b.join(" ")
          newmsg.add " ... "
          # and at max 2 word for context from the right
          let startd = min(i + 1, slices.len - 1)
          let endd = min(i + 2, slices.len - 1)
          for slice in slices[startd .. endd]:
            echo slice
            for part in slice.b:
              if part != " ":
                newmsg.add part
                break
          newmsg.add " ...' => '"
          newmsg.add span.b.join(" ")
          newmsg.add "'"
        else:
          newmsg.add ""

      if newmsg != "":
        newmsgs.add newmsg
    msg = newmsgs.join(" | ")

  # Use bold styling to highlight the username
  let toSend = &"\x02<{m.author.username}>\x0F (edit) {msg}"
  await ircClient.privmsg(ircChan, toSend)

proc messageCreate(s: Shard, m: Message) {.async.} =
  ## Called when a new message is posted in Discord
  let check = checkMessage(m)
  if not check.isSome(): return
  let ircChan = check.get()

  let msg = await m.processMsg()

  # Use bold styling to highlight the username
  let toSend = &"\x02<{m.author.username}>\x0F {msg}"
  await ircClient.privmsg(ircChan, toSend)

proc startDiscord() {.async.} =
  ## Starts the Discord client instance and connects
  ## using token from the configuration.
  discord = newDiscordClient(conf.discord.token)
  discord.events.message_create = messageCreate
  discord.events.message_update = messageUpdate
  for irc in ircToWebhook.keys():
    asyncCheck sendWebhook(
      irc, "ircord", "Ircord is enabled in this channel!"
    )
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
  for _, shard in discord.shards:
    waitFor shard.disconnect()
  ircClient.close()
  quit(0)

setControlCHook(hook)
waitFor main()
