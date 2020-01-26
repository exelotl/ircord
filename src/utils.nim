import discordnim/discordnim, asyncdispatch, strutils, options




proc getUsers*(s: Shard, guild, part: string): Future[seq[User]] {.async.} = 
  ## Get all users whose usernames contain `part` string
  result = @[]
  var data = await s.guildMembers(guild, 1000, 0)
  for member in data:
    if member.user.isSome() and part in $member.user.get():
      let user = member.user.get()
      result.add(user)