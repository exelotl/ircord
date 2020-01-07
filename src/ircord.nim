# Stdlib
import strformat, strutils, strscans, sequtils, json
import httpclient, asyncdispatch, strtabs, options
import packages/docutils/rst
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

var removeHandler: (proc())

# Sequence of all webhook IDs we use
var webhooks = newSeq[string]()

# Two global variables for "irc: webhook" and "channelId: irc" tables. 
var ircToWebhook = newStringTable(mode = modeCaseSensitive)
var discordToIrc = newStringTable(mode = modeCaseSensitive)


proc sendWebhook(url, username, content: string) {.async.} = 
  ## Send a message to a channel on Discord using webhook url
  ## with provided username and message content.
  let client = newAsyncHttpClient()
  client.headers = newHttpHeaders({"Content-Type": "application/json"})
  let data = $(%*{"username": username, "content": content})
  let resp = await client.post(url, data)


proc handleIrc(client: AsyncIrc, event: IrcEvent) {.async.} = 
  ## Handles all events received by IRC client instance
  if event.typ != EvMsg or event.params.len < 2:
    return
  
  # If it's not a PRIVMSG or it's not sent to the IRC channel
  elif event.cmd != MPrivMsg or event.params[0][0] != '#': return
  
  # Get name of the IRC channel
  let ircChan = event.origin

  var (nick, msg) = (event.nick, event.params[1])
  echo event
  #var test = false
  #let rst = rstParse(msg, "", 1, 1, test, {roSupportMarkdown})
  #echo rst
  # Replace some special chars or strings
  # also replaces IRC characters used for bold stuff
  msg = msg.multiReplace({
    "ACTION": "", 
    "\n": "↵", "\r": "↵", "\l": "↵",
    "\1": "", "\x02": "", "\x0F": ""
  })

  # Just in a rare case we accidentally start this bot in #nim
  if nick == "FromDiscord": return
  # Special cases for the Gitter <-> IRC bridge
  elif nick == "FromGitter":
    # Get something like @["<Yardanico", " this is a test"]
    echo msg
    var data = msg.split(">", 1)
    echo data
    # Probably can't happen
    if data.len != 2: return

    (nick, msg) = (data[0][1..^1] & "[Gitter]", data[1].strip())
    echo nick
    echo msg
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

  asyncCheck sendWebhook(ircToWebhook[ircChan], nick, msg)

# https://github.com/genotrance/snip/blob/9bfb9ca2943ed4f9e2ac9956fdcf99df4f43af62/src/snip/gist.nim#L76
proc createPaste*(data: string): Future[Option[string]] {.async.} =
  result = none(string)
  var client = newAsyncHttpClient()
  var url = "http://ix.io"
  var data = "f:1=" & data
  try:
    let r = await client.post(url, data)
    if r.code() == Http200:
      return (await r.body).strip().some()
    else:
      return none(string)
  except OSError:
    discard


proc messageCreate(s: Shard, m: MessageCreate) {.async.} =
  ## Called on a new message in Discord

  # Don't handle messages which are sent by our webhooks
  if m.webhook_id.get("") in webhooks: return
  # Check if we have that channel_id in our discordToIrc mapping
  let ircChan = discordToIrc.getOrDefault(m.channel_id, "")
  if ircChan == "": return
  echo m

  var msg = m.content
  # Handle pastes
  if "```" in m.content or m.content.count("\n") > 2 or m.content.len > 500:
    let paste = await createPaste(m.content)
    # If we pasted successfully
    if paste.isSome():
      msg = &"Code paste (or big message), see {paste.get()}"
    # Give a link to the message on Discord
    else:
      let url = &"https://discordapp.com/channels/{m.guild_id.get()}/{m.channel_id}/{m.id}"
      msg = &"Code paste (or big message), see {url}"
  await ircClient.privmsg(ircChan, &"\x02<{m.author.username}>\x0F {msg}")

proc startDiscord() {.async.} = 
  ## Starts the Discord client instance and connects using
  ## token from the configuration.
  discord = newShard("Bot " & conf.discord.token)
  removeHandler = discord.addHandler(EventType.message_create, messageCreate)
  await discord.startSession()

proc startIrc() {.async.} = 
  ## Starts the IRC client and connects to the server and channels
  ## specified in the configuration.
  ircClient = newAsyncIrc(
    address = conf.irc.server,
    port = Port(conf.irc.port),
    nick = conf.irc.nickname,
    serverPass = conf.irc.password,
    # All IRC channels which we need to connect to
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