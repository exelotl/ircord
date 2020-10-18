# Stdlib
import std / [
  strformat, strutils, sequtils, json, strscans, parseutils,
  httpclient, uri, asyncdispatch, tables, options,
  math, md5, times, segfaults,
  wordwrap
]
# Nimble
import dimscord, irc, diff
import regex
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

# Timestamp of when the bot was started
var startTime = getTime()

var lastUsers = newSeq[User](5)
var lastUserIdx = 0

proc getUptime: string = 
  let uptime = $initDuration(minutes = (getTime() - startTime).inMinutes)
  result = fmt"Uptime - {uptime}"

proc sendWebhook(ircChan, username, content: string, user = none(User)) {.async.} =
  ## Send a message to a channel on Discord using webhook url
  ## with provided username and message content.
  # Get hash of the username to generate unique avatars, but unique to each IRC user
  let hash = getMD5(username.toLower())

  let client = newAsyncHttpClient()
  client.headers = newHttpHeaders({"Content-Type": "application/json"})
  # https://en.gravatar.com/site/implement/images/
  let data = $(
    %*{
      "username": username, 
      "content": content,
      "avatar_url": &"https://www.gravatar.com/avatar/{hash}?d=robohash&size=512",
      "allowed_mentions": {
        "parse": ["users"]
      }
    }
  )
  let resp = await client.post(ircToWebhook[ircChan], data)
  client.close()

proc parseIrcMessage(nick, msg: var string): bool =
  result = true
  # Replace some special chars or strings
  # also replaces IRC characters used for styling
  # (maybe we'll want to convert these to markdown later in the future)
  # https://en.wikichip.org/wiki/irc/colors
  # https://github.com/myano/jenni/wiki/IRC-String-Formatting
  msg = msg.multiReplace({
    "ACTION": "",
    "\n": "↵", "\r": "↵", "\l": "↵",
    "\1": "", 
  })

  msg = msg.ircToMd()
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

var 
  ircAccResp: Future[(string, string)] # Future for checking ACC status
  # Table with last users for channels, discord_id -> (username, user_id)
  lastMessages: Table[string, (string, string)] 

proc handleIrcCmds(chan: string, nick, msg: string): Future[bool] {.async.} =
  if nick notin conf.irc.adminList or msg[0] != '!': return
  # Create a new future, we don't really handle race conditions here
  # since we assume that admin commands are extremely rare.
  if ircAccResp.isNil():
    ircAccResp = newFuture[(string, string)]()
  await ircClient.privmsg("NickServ", &"acc {nick}")
  let acc = await ircAccResp
  # Nullify the future
  ircAccResp = nil
  #[
    0 - account or user does not exist
    1 - account exists but user is not logged in
    2 - user is not logged in but recognized
    3 - user is logged in <- that's the only one we care about
  ]#
  if cmpIgnoreCase(acc[0], nick) != 0 or acc[1] != "3":
    # The user is apparently not identified or not recognized
    return
  # Parsing the actual commands
  let data = msg.split(" ")
  if data.len == 0: return
  # It seems to be an actual command
  result = true
  case data[0]
  # Gets a Discord UID of all users which match the string
  of "!getdiscid":
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
  of "!status":
    await ircClient.privmsg(chan, getUptime())
  # Gets a Discord UID of a user who sent the last message on Discord
  # in the current channel
  of "!getlastid":
    var chanId = ""
    for (id, irc) in discordToIrc.pairs():
      if irc == chan: 
        chanId = id
        break
    var (lastUsername, lastId) = lastMessages.getOrDefault(chanId)
    if lastId != "": 
      await ircClient.privmsg(
        chan, fmt"UID of {lastUsername} who sent/edited a message most recently on Discord is {lastId}"
      )
    else:
      await ircClient.privmsg(
        chan, "Don't have info for the current channel yet."
      )
  # Bans a Discord user by UID
  of "!bandisc":
    if data.len < 2:
      await ircClient.privmsg(chan, "Usage: !ban 174365113899057152")
      return
    var id = try: $parseInt(data[1]) except: ""
    if id != "":
      await discord.api.createGuildBan(conf.discord.guild, id)
      await ircClient.privmsg(chan, "User with UID " & $id & " was banned on Discord!")
    else:
      await ircClient.privmsg(chan, "Unknown UID")
  # If an admin sent a message starting with ! and it wasn't a command
  else:
    result = false

proc handleIrc(client: AsyncIrc, event: IrcEvent) {.async.} =
  ## Handles all events received by the IRC client instance
  # Enable color stripping
  if event.typ != EvMsg or event.params.len < 2:
    return

  # Complete the ircAccResp with the response for the access
  # data of the user (admin)
  elif event.cmd == MNotice and event.nick == "NickServ":
    let data = event.params[1].strip().split(" ")
    if data.len == 3 and data[1] == "ACC":
      # Get the data back to the admin checking function
      ircAccResp.complete((data[0], data[2]))
    # No need to send that message
    return
  # Check that it's a message sent to the channel
  elif event.cmd != MPrivMsg or event.origin[0] != '#':
    return

  let ircChan = event.origin

  var (nick, msg) = (event.nick, event.params[1])

  # Don't send commands or their output to Discord
  if (await handleIrcCmds(ircChan, nick, msg)): return

  if parseIrcMessage(nick, msg):
    block mentions:
      # Blacklist for mentions 
      # TODO XXX Add to config
      if nick in ["disbot", "ForumUpdaterBot"]: break mentions
      var replaces: seq[(string, string)]      
      for mention in msg.findMentions():
        var username = toLower(mention)
        # Search through all members on the channel (cached locally so it's fine)
        for id, user in discord.shards[0].cache.users:
          if toLower(user.username) == username:
            replaces.add ('@' & mention, "<@" & id & ">")
            replaces.add (mention, "<@" & id & ">")
      msg = msg.multiReplace(replaces)
    asyncCheck sendWebhook(
      ircChan, nick, msg
    )

type
  PasteKind* = enum IxIo, PasteRs

proc createPaste*(data: string, kind = IxIo): Future[Option[string]] {.async.} =
  ## Creates a paste with `data` on ix.io and returns some(string)
  ## If pasting failed, returns none
  result = none(string)
  var client = newAsyncHttpClient()
  try:
    case kind
    of IxIo:
      let resp = await client.post("http://ix.io", "f:1=" & encodeUrl(data))
      if resp.code == Http200:
        result = some strip(await resp.body)
    of PasteRs:
      let resp = await client.post("https://paste.rs/", data)
      if resp.code in {Http201, Http206}:
        result = some strip(await resp.body)
  # I know this is bad but we want at least some *stability*
  except:
    echo "Got error trying to do a paste: "
    echo getStackTrace()
    echo getCurrentExceptionMsg()
  finally:
    client.close()

proc checkMessage(m: Message): Option[string] =
  result = none(string)
  # Don't handle messages which are sent by our own webhooks
  if m.webhook_id.isSome() and m.webhook_id.get() in webhooks: return
  # Check if we have that channel_id in our discordToIrc mapping
  let ircChan = discordToIrc.getOrDefault(m.channel_id, "")
  if ircChan == "": return
  result = some(ircChan)

proc handleAttaches(m: Message): string =
  if m.attachments.len > 0:
    result = " " & m.attachments.mapIt(it.proxy_url).join(" ")

proc preprocessPasteMsg(msg: var string, isCodePaste = false) = 
  ## Preprocesses the message before pasting it:
  ## - Word-wraps all lines by 80 characters
  ## - In code pastes text is converted into comments
  var lines = msg.splitLines()
  
  msg.setLen(0)
  
  var isText = true
  for line in lines:
    # If the line starts with ``` - toggle the text status
    # and skip the line itself
    if line.startsWith("```"):
      isText = not isText
      # Just so that we don't have empty lines in place of ```
      continue

    # Word-wrap the line and if we're inside a code paste, also
    # transform normal text into comments
    if isCodePaste and isText and line != "":
      msg.add "# "
      msg.add wrapWords(line, newLine="\n# ")
    else:
      msg.add wrapWords(line)
    msg.add "\n"

proc handlePaste(m: Message, msg: sink string): Future[string] {.async.} =
  ## Handles pastes or big messages
  # We treat _all_ messages that contain ``` as code pastes
  # Otherwise a message is a normal paste if it's more than 3 lines
  # long or more than 500 characters long - that's very near to 
  # the 512 IRC char limit
  let maybeCodePaste = "```" in msg
  if not (maybeCodePaste or msg.count('\n') > 3 or msg.len > 500):
    # Replace newlines with ↵
    result = msg.replace("\n", "↵")
  else:
    preprocessPasteMsg(msg, maybeCodePaste)

    var link: string

    block tryPasting:
      for service in [IxIo, PasteRs]:
        let maybePaste = await createPaste(msg, service)
        if maybePaste.isSome():
          link = maybePaste.get()
          # Convert the ix.io link into a nim playground one
          if maybeCodePaste and service == IxIo:
            let ixid = link.rsplit("/")[^1]
            link = "https://play.nim-lang.org/#ix=" & ixid
          
          break tryPasting
      
      if not m.guildId.isSome(): return # just to be safe I guess
      link = &"https://discordapp.com/channels/{m.guild_id.get()}/{m.channel_id}/{m.id}"
    
    # In italics
    result = 
      if maybeCodePaste: 
        &"\x1Dsent a code paste, see\x1D {link}"
      else:
        &"\x1Dsent a long message, see\x1D {link}"

proc handleDiscordCmds(m: Message): Future[bool] {.async.} = 
  result = false
  # Only commands with !
  if m.content.len == 0 or m.content[0] != '!': return
  let data = m.content.split(" ")
  if data.len == 0: return
  # Maybe we should add ability to ban people on IRC from Discord too.
  #[ 
  case data[0]
  # Gets a Discord UID of all users which match the string
  of "!status":
    discard await discord.api.sendMessage(m.channelId, getUptime())
  else: discard
  ]#

proc processMsg(m: Message): Future[Option[string]] {.async.} =
  ## Does all needed modifications on message contents before sending it
  var data = m.content
  # If this is not a command
  if not (await handleDiscordCmds(m)):
    data &= m.handleAttaches()
    data = handleObjects(discord, m, data)
    data = data.mdToIrc()
    data = await m.handlePaste(data)
    # Add a note that we actually read that message
    #await discord.api.addMessageReaction(m.channelId, m.id, "📩")
    result = some(data)
    # Remember that user
    if m.isNil():
      echo "m is nil?? why?"
    elif m.author.isNil():
      echo "m.author is nil?? why??"
    else:
      lastMessages[m.channel_id] = (m.author.username, m.author.id)
  else:
    result = none(string)


var lastMsgs = newSeq[int](3)
var lastMsgsIdx = 0

proc messageUpdate(s: Shard, m: Message, old: Option[Message], exists: bool) {.async.} =
  ## Called when a message is edited in Discord
  let check = checkMessage(m)
  if not check.isSome(): return
  let ircChan = check.get()

  let msgOpt = await m.processMsg()
  if not msgOpt.isSome():  return
  var msg = msgOpt.get()

  if old.isSome():
    # For some reason you can get MessageUpdate events after
    # someone posted a link and Discord generated preview for it
    if m.content == old.get().content: return
    let oldContent = block:
      let old = await old.get().processMsg()
      if not old.isSome(): return
      old.get().split()
    let newContent = msg.split()
    var newmsgs = newSeqOfCap[string](oldContent.len)
    # Some content diffing to produce an edited message
    let slices = toSeq(spanSlices(oldContent, newContent))
    for i, span in slices:
      var newmsg = ""
      # thanks leorize on IRC for suggesting this edit format
      case span.tag
      of tagReplace:
        newmsg.add "\"$1\" => \"$2\"".format(span.a.join(" "), span.b.join(" "))
      # We only send diff so we don't care if spans are equal
      of tagEqual:
        discard
      of tagDelete:
        newmsg.add "\x0304removed\x03 \"$1\"".format(span.a.join(" "))
      of tagInsert:
        echo span.a
        echo span.b
        echo slices
        if i != 0:
          # stuff ...  -> stuff new ...
          newmsg.add '"'
          # at max 2 words for context from the left
          var contextLeftCnt = 0
          let start = min(max(i - 2, 0), 2)
          for slice in slices[start .. i - 1]:
            if contextLeftCnt > 2:
              break
            let lastSlice = slice.b[min(slice.b.len - 1, 3)]
            newmsg.add slice.b.join(" ")
          newmsg.add " ... "
          if i < slices.len - 1:
            # and at max 2 word for context from the right
            # only if this is not the last slice
            let startd = min(i + 1, slices.len - 1)
            let endd = min(i + 2, slices.len - 1)
            for slice in slices[startd .. endd]:
              echo slice
              for part in slice.b:
                if part != " ":
                  newmsg.add part
                  break
          newmsg.add "\" \x0303added\x03 \""
          #for slice in slices[start .. i - 1]:
          #  newmsg.add slice.b.join(" ")
          #newmsg.add " "
          newmsg.add span.b.join(" ")
          newmsg.add '"'
        else:
          newmsg.add ""

      if newmsg != "":
        newmsgs.add newmsg
    msg = newmsgs.join(" | ")

  # Use bold styling to highlight the username
  let toSend = &"\x02<{m.author.username}>\x02 (edit) {msg}"
  await ircClient.privmsg(ircChan, toSend)

var cached = false

proc messageCreate(s: Shard, m: Message) {.async.} =
  ## Called when a new message is posted in Discord
  if not cached:
    await s.requestGuildMembers(
      @[conf.discord.guild], limit = some(0), query = some("")
    )
    cached = true
  let check = checkMessage(m)
  if not check.isSome(): return
  let ircChan = check.get()
  
  lastUserIdx = if lastUserIdx >= 4: 0
  else: lastUserIdx + 1
  lastUsers[lastUserIdx] = m.author
  let msgOpt = await m.processMsg()
  if not msgOpt.isSome(): return
  let msg = msgOpt.get()

  # Use bold styling to highlight the username
  let toSend = &"\x02<{m.author.username}>\x02 {msg}"
  await ircClient.privmsg(ircChan, toSend)

proc startDiscord() {.async.} =
  ## Starts the Discord client instance and connects
  ## using token from the configuration.
  discord = newDiscordClient(conf.discord.token)
  discord.events.messageCreate = messageCreate
  discord.events.messageUpdate = messageUpdate
  # intentGuilds -> receive initial info about the server
  # intentGuildMessages -> obviously to receive the messages themselves
  # intentGuildMembers -> to receive events for member join/leave, so
  # the cache can dynamically change and we can use it for mentions
  # !!! for intentGuildMembers we need to enable SERVER MEMBERS INTENT
  # in bot settings
  await discord.startSession(
    # XXX: giGuildEmojis shouldn't be needed
    gatewayIntents = {giGuilds, giGuildMembers, giGuildMessages}
  )

proc startIrc() {.async.} =
  ## Starts the IRC client and connects to the server and
  ## joins channels specified in the configuration.
  let ircChans = conf.mapping.mapIt(it.irc)
  ircClient = newAsyncIrc(
    address = conf.irc.server,
    port = Port(conf.irc.port),
    nick = conf.irc.nickname,
    user = conf.irc.nickname,
    realname = conf.irc.nickname,
    serverPass = conf.irc.password,
    # All IRC channels we need to connect to
    joinChans = ircChans,
    callback = handleIrc
  )
  await ircClient.connect()
  asyncCheck ircClient.run()

proc main() {.async.} =
  echo "Starting Ircord (wait up to 10 seconds)..."
  conf = parseConfig()
  # Fill global variables
  for entry in conf.mapping:
    # Get webhook ID (to check for it before sending a message to IRC)
    webhooks.add(entry.webhook.split("webhooks/")[1].split("/")[0])

    ircToWebhook[entry.irc] = entry.webhook
    discordToIrc[entry.discord] = entry.irc

  asyncCheck startDiscord()
  # Block until startIrc exits
  await startIrc()

proc hook() {.noconv.} =
  echo "Quitting Ircord..."
  for _, shard in discord.shards:
    waitFor shard.disconnect(shouldReconnect = false)
  ircClient.close()
  quit(0)

setControlCHook(hook)
asyncCheck main()
runForever()
