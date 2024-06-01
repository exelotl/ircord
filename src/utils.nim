import std/[
  asyncdispatch, strutils, tables, parseutils, options,
  unicode # for npeg utf8
]
import dimscord
import optionsutils
import npeg, npeg/lib/utf8 # for unicode discord nicknames

type
  FormatAtom = object
    # Toggles
    bold, italic, underline, strike, mono, color: bool
    # Background and foreground colors
    bg, fg: int
    text: string

const
  boldC = '\x02'
  italicC = '\x1D'
  underlineC = '\x1F'
  strikeC = '\x1E'
  monoC = '\x11'
  colorC = '\x03'
  resetC = '\x0F'
  zeroWidth = "​"
  anyFormatting = {boldC, italicC, underlineC, strikeC, monoC, colorC, resetC}

var badMsgs = open("failedMsgs", fmAppend)

proc ircToMd*(msg: string): string = 
  ## A relatively simple IRC to Markdown parser/converter
  ## No complicated AST or anything like that, just plain simple loops
  ## and storing states of the formatting
  result = newStringOfCap(msg.len)
  var
    bold, italic, underline, strikethrough, monospace, color = false
    curBackground, curForeground = -1
  
  var i = 0
  var data: seq[FormatAtom]
  var curAtom = FormatAtom()
  var safeCnt = 0 # just a safe guard, I'm not sure if this code is 100% correct
  while i < msg.len:
    inc safeCnt
    if safeCnt > 5000:
      echo repr msg
      badMsgs.writeLine(repr msg)
      return msg
    var c = msg[i]
    case c
    # Togglable formatting
    of boldC: 
      bold = not bold
    of italicC: 
      italic = not italic
    of underlineC: 
      underline = not underline
    # Strikethrough - not supported by most IRC clients
    of strikeC: 
      strikethrough = not strikethrough
    # Monospace - not supported by most IRC clients
    of monoC:
      monospace = not monospace
    # Reset all formatting
    of resetC:
      bold = false
      italic = false
      underline = false
      strikethrough = false
      monospace = false
      color = false
      curBackground = -1
      curForeground = -1
    of colorC:
      var temp: int
      # We're at the \03 right now, inc to get further
      inc i
      # Try to parse the first foreground color
      var checked = msg.parseInt(temp, i)
      # If we only got \03 - reset colors
      if checked == 0:
        color = not color
        # Reset colors
        curBackground = -1
        curForeground = -1
        # We don't inc i here because we already did it before
        continue
      # Add foreground color
      else:
        i += checked
        curForeground = temp
      # Second color - if we have chars left, and we have a comma
      if i < msg.len - 1 and msg[i] == ',':
        # Next char should be a digit for colors
        inc i
        checked = msg.parseInt(temp, i)
        # No second color, decrease and continue so we get the comma
        if checked == 0:
          dec i
          continue
        else:
          # -1 because we already did inc i before
          # otherwise we'll miss some characters
          i += checked - 1
          curBackground = temp
      else:
        dec i

    else:
      i += msg.parseUntil(curAtom.text, anyFormatting, i)
      # Set captured parameters
      curAtom.bold = bold
      curAtom.italic = italic
      curAtom.underline = underline
      curAtom.strike = strikethrough
      curAtom.mono = monospace
      curAtom.color = color
      curAtom.bg = curBackground
      curAtom.fg = curForeground
      data.add curAtom
      # Reset
      curAtom = FormatAtom()
      continue
    inc i

  proc parseAtoms(prev, x: FormatAtom): string = 
    #echo prev, " ", x
    var temp: string
    # Special-case for handling spaces, yeah...
    var spaceBefore, spaceAfter: int
    result = x.text # <- use the current node here, so in the start x = first real node,
    # in the end <- x = last fake empty node
    spaceBefore = result.parseWhile(temp, {' '})
    let skip = result.parseUntil(temp, {' '}, spaceBefore)
    spaceAfter = result.parseWhile(temp, {' '}, skip + spaceBefore)
    result = strutils.strip(result)

    if spaceBefore > 0:
      result.insert ' '.repeat(spaceBefore)
    if spaceAfter > 0:
      result.add ' '.repeat(spaceAfter)

    # If formatting of the previous and current atoms don't match, insert
    # the formatting character
    # This needs to be after space insertion so formatting looks like **text**
    # and not **text **
    if x.italic != prev.italic:
      result.insert "*"
    
    if x.underline != prev.underline:
      result.insert "__"
    
    if x.bold != prev.bold:
      result.insert "**"
    
    if x.strike != prev.strike:
      result.insert "~~"

  var prev = FormatAtom()
  for i, x in data:
    result.add parseAtoms(prev, x)
    prev = x
  # last iteration for the closing tags in the end
  result.add parseAtoms(prev, FormatAtom())


proc mdToIrc*(msg: string): string = 
  result = newStringOfCap(msg.len)
  var 
    bold, italic, underline = false

  var i = 0
  var safeCnt = 0
  while i < msg.len:
    inc safeCnt
    if safeCnt > 5000:
      echo repr msg
      badMsgs.writeLine(repr msg)
      return msg
    var c = msg[i]
    case c
    of '*':
      var asteriskCount = 0
      while c == '*' and i < msg.len:
        c = msg[i]
        if c == '*':
          inc asteriskCount
          inc i
        else:
          dec i # TODO: Maybe fix the loop so we don't need this?
          break
      if asteriskCount >= 3:
        bold = not bold
        italic = not italic
        result.add boldC
        result.add italicC
        if asteriskCount > 3:
          result.add '*'.repeat(asteriskCount - 3)
      
      elif asteriskCount == 2:
        bold = not bold
        result.add boldC
      
      elif asteriskCount == 1:
        italic = not italic
        result.add italicC
    of '_':
      if i + 1 < msg.len and msg[i + 1] == '_':
        inc i
        result.add underlineC
      else:
        result.add c
    else:
      result.add c
    inc i

proc getUsers*(s: DiscordClient, guild, part: string): Future[seq[User]] {.async.} = 
  ## Get all users whose usernames contain `part` string
  result = @[]
  #[
  var data = await s.api.getGuildMembers(guild, 1000, "0")
  echo data.len
  for member in data:
    if part in member.user.username:
      let user = member.user
      result.add(user)
  ]#
  for user in s.shards[0].cache.users.values:
    if part in user.username:
      result.add user

type
  Kind = enum Emote, Mention, Channel, Replace
  Data = object
    kind: Kind
    r: tuple[old, id: string]

# A simple NPEG parser, done with the help of leorize from IRC
let objParser = peg("discord", d: seq[Data]):
  # Emotes like <:nim1:321515212521> <a:monakSHAKE:472058550164914187>
  emote <- "<" * ?"a" * >(":" * +Alnum * ":") * +Digit * ">":
    d.add Data(kind: Emote, r: (old: $0, id: $1))

  # User mentions like <@!2315125125> <@408815590170689546>
  mention <- "<@" * ?"!" * >(+Digit) * ">":
    # logic for handling mentions
    d.add Data(kind: Mention, r: (old: $0, id: $1))

  serviceName <- ("IRC" | "Gitter" | "Matrix")
  ircPostfix <- "[" * serviceName * "]#0000"

  # For handling Discord -> Discord replies
  # We only want the last ID here
  # > something <@!177365113899057151>
  # <@!177365113899057152>
  # We match all mentions but only take the ID of the last one,
  # which is the one we actually need
  # We also handle cases when a user is both in Discord and IRC,
  # and someone replied to him from Discord to IRC and Discord replaced
  # the username with the Discord ID (that's why we have ircPostfix here)
  discordReply <- "> " * +(*(1 - "<@") * "<@" * ?"!" * >(+Digit) * ">") * ?ircPostfix:
    d.add Data(kind: Mention, r: (old: $0, id: (capture[capture.len - 1]).s))

  # For handling Discord -> IRC replies
  # Almost same as discordReply, but we don't capture that Discord ID but instead
  # wait for the last @(name)[IRC]#0000 and ircPostfix is mandatory
  ircReply <- ?"> " * +(*(1 - "@") * "@" * >+(1 - "[") * ircPostfix):
    d.add Data(kind: Replace, r: (old: $0, id: "@" & capture[capture.len - 1].s))

  # Channel mentions like <#125125125215>
  channel <- "<#" * >(+Digit) * ">":
    # logic for handling channels
    d.add Data(kind: Channel, r: (old: $0, id: $1))

  matchone <- channel | emote | discordReply | ircReply | mention

  discord <- +@matchone

proc handleObjects*(s: DiscordClient, g: Guild, msg: Message, content: string): string = 
  result = content

  var data = newSeq[Data]()
  let match = objParser.match(result, data)
  if not match.ok: 
    return
  for obj in data:
    case obj.kind
    of Emote: result = result.replace(obj.r.old, obj.r.id)
    of Mention:
      # Iterate over all mentioned users and find the one we need
      for user in msg.mention_users:
        if user.id == obj.r.id:
          # Get the display name if it exists
          let name = 
            if user.id in g.members: get(g.members[user.id].nick, user.username)
            else: user.username
          result = result.replace(obj.r.old, "@" & name)
    of Channel:
      let chan = s.shards[0].cache.guildChannels.getOrDefault(obj.r.id)
      if not chan.isNil():
        result = result.replace(obj.r.old, "#" & chan.name)
    of Replace:
      result = result.replace(obj.r.old, obj.r.id)


#[
  We only allow these 3 types of mentions:
  1) "Nick: hello" at the start of the message (only one nick is possible)
  2) "@Nick" - the best way to ping someone
  3) "ping Nick" - can happen more than 1 time in the message
]#

let mentParser = peg mentions:
  >nick <- (Alnum | '_' | utf8.alpha)[4..32]
  # @nick or ping nick
  # + is "one or more", otherwise "pinged" = "ping @ed"!
  mention <- !Alnum * (('@' * nick) | ("ping" * +' ' * nick))
  leadMentionSeps <- {':', ','}
  
  # optional @ + nick + optional whitespace + : or ,
  leadingMention <- ?'@' * nick * *' ' * leadMentionSeps
  # check for a single leading mention and search for other mentions
  mentions <- ?leadingMention * *@mention

iterator findMentions*(s: string): string =
  ## Simple iterator for yielding all words
  ## which are entirely made of IdentChars
  for word in mentParser.match(s).captures:
    yield word

when true:
  for ment in findMentions("@asd have you been tiled and pinged and redpilled today?"):
    echo "Mention - ", ment

when false:
  let strings = [
    "Yardanico: hello how are you?",
    "ping dom96",
    "Yardanico: hello @dom96",
    "@dom96: ping Araq",
    "test ping @Araq @hello"
  ]

  for str in strings:
    echo "Parsing: " & str
    for ment in findMentions(str):
      echo "Parsed nick: " & ment
    echo "-".repeat(20)

when false:
  let boldStr = boldC & "boldness" & boldC
  let italicStr = italicC & "italics" & italicC
  let boldItalicStr = boldC & italicC & "bold italics" & italicC & boldC
  let full = italicStr & boldStr & boldItalicStr & boldStr & italicStr & "hello"
  echo ircToMd(full)

when false:
  var res = ["""
  > 1234 <@!177365113899057151> askldpljsdgj39-2 u52308- tesdg <@!17736511389905127151><@!177365113812499057151>
  <@!177365113899057152>
  """,
  """
  > Sometimes "progress" just makes things more complex without any clear benefit <@!123123>[IRC]#0000 <@!123123>[IRC]#0000
  <@!177365113899057152>[IRC]#0000 do you see it in this case or do you see that the current way is more complex?
  """,
  """
  @reversem3[IRC]#0000, I think use current stable mostly.
  """,
  """
  > noone prevents you from using fidget without figma, dude.
  <@!177365113899057152> That point can also be made about Nim and C. You can use C without Nim, while that is missing the point.
  """,
  """
  > yeah right , say that to normal users
  @reversem3[IRC]#0000 what do you mean?
  """]
  for test in res:
    var data: seq[Data]
    let match = objParser.match(test, data)
    echo data
    doAssert match.ok, "assert failed for " & test


when true:
  echo repr mdToIrc("I've never seen `import module*` did you just come up with that syntax?")
