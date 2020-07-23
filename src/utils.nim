import asyncdispatch, strutils, tables, parseutils
import dimscord
import npeg

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
  anyFormatting = {boldC, italicC, underlineC, strikeC, monoC, colorC}

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
  while i < msg.len:
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

  for x in data:
    var temp: string
    # Special-case for handling spaces, yeah...
    var spaceBefore, spaceAfter: int
    var toAdd = x.text
    spaceBefore = toAdd.parseWhile(temp, {' '})
    let skip = toAdd.parseUntil(temp, {' '}, spaceBefore)
    spaceAfter = toAdd.parseWhile(temp, {' '}, skip + spaceBefore)
    toAdd = toAdd.strip()
    # from innermost to outermost formattting, 
    # order: ~~ __ ** *
    if x.italic:
      toAdd.insert "*"
      toAdd.add "*"
    if x.underline:
      toAdd.insert "__"
      toAdd.add "__"
    if x.bold:
      toAdd.insert "**"
      toAdd.add "**"
    if x.strike:
      toAdd.insert "~~"
      toAdd.add "~~"
    toAdd.insert ' '.repeat(spaceBefore)
    toAdd.add ' '.repeat(spaceAfter)
    #[
    if x.fg != -1:
      echo "x.fg = ", x.fg
    if x.bg != -1:
      echo "x.bg = ", x.bg
    ]#
    # For now we don't handle edge cases when there are consecutive entries
    # with asterisks (e.g. -> bold text, then bold italics text).
    # So we just insert a zero-width unicode space
    result.add toAdd & zeroWidth

proc mdToIrc*(msg: string): string = 
  result = newStringOfCap(msg.len)
  var 
    bold, italic, underline = false

  var i = 0
  while i < msg.len:
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

proc handleObjects*(s: DiscordClient, msg: Message, content: string): string = 
  result = content


  # A simple NPEG parser, done with the help of leorize from IRC
  let objParser = peg("discord", d: seq[Data]):
    # Emotes like <:nim1:321515212521> <a:monakSHAKE:472058550164914187>
    emote <- "<" * ?"a" * >(":" * +Alnum * ":") * +Digit * ">":
      d.add Data(kind: Emote, r: (old: $0, id: $1))

    # User mentions like <@!2315125125> <@408815590170689546>
    mention <- "<@" * ?"!" * >(+Digit) * ">":
      # logic for handling mentions
      d.add Data(kind: Mention, r: (old: $0, id: $1))

    # Channel mentions like <#125125125215>
    channel <- "<#" * >(+Digit) * ">":
      # logic for handling channels
      d.add Data(kind: Channel, r: (old: $0, id: $1))

    matchone <- channel | emote | mention

    discord <- +@matchone
  
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
          result = result.replace(obj.r.old, "@" & $user.username)
    of Channel:
      let chan = s.shards[0].cache.guilds.getOrDefault(obj.r.id)
      if not chan.isNil():
        result = result.replace(obj.r.old, "#" & chan.name)
    of Replace:
      result = result.replace(obj.r.old, obj.r.id)


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
  # the username with the Discord ID 
  discordReply <- "> " * +(*(1 - "<@") * "<@" * ?"!" * >(+Digit) * ">") * ?ircPostfix:
    d.add Data(kind: Mention, r: (old: $0, id: capture[^1].s))

  # For handling Discord -> IRC replies
  # Almost same as discordReply, but we don't capture that Discord ID but instead
  # wait for the last @(name)[IRC]#0000 and ircPostfix is mandatory
  ircReply <- ?"> " * +(*(1 - "@") * "@" * >+(1 - "[") * ircPostfix):
    d.add Data(kind: Replace, r: (old: $0, id: "@" & capture[^1].s))

  # Channel mentions like <#125125125215>
  channel <- "<#" * >(+Digit) * ">":
    # logic for handling channels
    d.add Data(kind: Channel, r: (old: $0, id: $1))

  matchone <- channel | emote | discordReply | ircReply | mention

  discord <- +@matchone


let mentParser = peg mentions:
  nickChar <- Alnum | '_'
  nick <- > +nickChar

  mention <- >("@" * nick)

  mentions <- *@mention

iterator findMentions*(s: string): string =
  ## Search for all mentions like @yardanico
  ## in the string and yield all of them 
  for x in mentParser.match(s).captures:
    yield x

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
    doAssert match.ok, "assert failed for " & test
