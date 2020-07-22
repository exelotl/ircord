import asyncdispatch, strutils, tables, options
import dimscord
import npeg, npeg/lib/utf8
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

when isMainModule:
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