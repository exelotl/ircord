# Copyright © 2019-20 Mark Summerfield. All rights reserved.
# Licensed under the Apache License, Version 2.0 (the "License");
# you may only use this file in compliance with the License. The license
# is available from http://www.apache.org/licenses/LICENSE-2.0
{.experimental: "codeReordering".}

## This library provides methods for comparing two sequences.
##
## The sequences could be seq[string] of words, or any other sequence
## providing the elements support ``==`` and ``hash()``.
##
## If you only need to compare each pair of sequences once, use
## ``spans(a, b)`` if you only need indexes, or ``spanSlices(a, b)`` if
## you need subsequences.
##
## If you need to do multiple comparisons on the same sequences, create a
## ``Diff`` with ``newDiff`` and then use ``diff.spans()``
##
## Example:
## ```nim
## let a = ("Tulips are yellow,\nViolets are blue,\nAgar is sweet,\n" &
##          "As are you.").split('\n')
## let b = ("Roses are red,\nViolets are blue,\nSugar is sweet,\n" &
##          "And so are you.").split('\n')
## for span in spanSlices(a, b):
##   case span.tag
##   of tagReplace:
##     for text in span.a:
##       echo("- ", text)
##     for text in span.b:
##       echo("+ ", text)
##   of tagDelete:
##     for text in span.a:
##       echo("- ", text)
##   of tagInsert:
##     for text in span.b:
##       echo("+ ", text)
##   of tagEqual:
##     for text in span.a:
##       echo("= ", text)
## ```
##
## (The algorithm is a slightly simplified version of the one used by the
## Python difflib module's SequenceMatcher.)
##
## See also `diff on github <https://github.com/mark-summerfield/diff>`_.
## For other Nim code see `FOSS <http://www.qtrac.eu/sitemap.html#foss>`_.

import algorithm
import math
import sequtils
import sets
import sugar
import tables

type
  Match* = tuple[aStart, bStart, length: int]

  Span* = tuple[tag: Tag, aStart, aEnd, bStart, bEnd: int]

  SpanSlice*[T] = tuple[tag: Tag, a, b: seq[T]]

  Tag* = enum
    tagEqual = "equal"
    tagInsert = "insert"
    tagDelete = "delete"
    tagReplace = "replace"

  Diff*[T] = object
    a*: seq[T]
    b*: seq[T]
    b2j: Table[T, seq[int]]

proc newDiff*[T](a, b: seq[T]): Diff[T] =
  ## Creates a new ``Diff`` and computes the comparison data.
  ##
  ## To get all the spans (equals, insertions, deletions, replacements)
  ## necessary to convert sequence `a` into `b`, use ``diff.spans()``.
  ##
  ## To get all the matches (i.e., the positions and lengths) where `a`
  ## and `b` are the same, use ``diff.matches()``.
  ##
  ## If you need *both* the matches *and* the spans, use
  ## ``diff.matches()``, and then use ``spansForMatches()``.
  result.a = a
  result.b = b
  result.b2j = initTable[T, seq[int]]()
  result.chain_b_seq()

proc chain_b_seq[T](diff: var Diff[T]) =
  for (i, key) in diff.b.pairs():
    var indexes = diff.b2j.getOrDefault(key, @[])
    indexes.add(i)
    diff.b2j[key] = indexes
  if (let length = len(diff.b); length > 200):
    let popularLength = int(floor(float(length) / 100.0)) + 1
    var bPopular = initHashSet[T]()
    for (element, indexes) in diff.b2j.pairs():
      if len(indexes) > popularLength:
        bPopular.incl(element)
    for element in bPopular.items():
      diff.b2j.del(element)

iterator spans*[T](a, b: seq[T]; skipEqual = false): Span =
  ## Directly diffs and yields all the spans (equals, insertions,
  ## deletions, replacements) necessary to convert sequence ``a`` into
  ## ``b``. If ``skipEqual`` is ``true``, spans don't contain
  ## ``tagEqual``.
  ##
  ## If you need *both* the matches *and* the spans, use
  ## ``diff.matches()``, and then use ``spansForMatches()``.
  let diff = newDiff(a, b, skipEqual = skipEqual)
  let matches = diff.matches()
  for span in spansForMatches(matches, skipEqual = skipEqual):
    yield span

iterator spans*[T](diff: Diff[T]; skipEqual = false): Span =
  ## Yields all the spans (equals, insertions, deletions, replacements)
  ## necessary to convert sequence ``a`` into ``b``.
  ## If ``skipEqual`` is ``true``, spans don't contain ``tagEqual``.
  ##
  ## If you need *both* the matches *and* the spans, use
  ## ``diff.matches()``, and then use ``spansForMatches()``.
  let matches = diff.matches()
  for span in spansForMatches(matches, skipEqual = skipEqual):
    yield span

proc matches*[T](diff: Diff[T]): seq[Match] =
  ## Returns every ``Match`` between the two sequences.
  ##
  ## The differences are the spans between matches.
  ##
  ## To get all the spans (equals, insertions, deletions, replacements)
  ## necessary to convert sequence ``a`` into ``b``, use ``diff.spans()``.
  let aLen = len(diff.a)
  let bLen = len(diff.b)
  var queue = @[(0, aLen, 0, bLen)]
  var matches = newSeq[Match]()
  while len(queue) > 0:
    let (aStart, aEnd, bStart, bEnd) = queue.pop()
    let match = diff.longestMatch(aStart, aEnd, bStart, bEnd)
    let i = match.aStart
    let j = match.bStart
    let k = match.length
    if k > 0:
      matches.add(match)
      if aStart < i and bStart < j:
        queue.add((aStart, i, bStart, j))
      if i + k < aEnd and j + k < bEnd:
        queue.add((i + k, aEnd, j + k, bEnd))
  matches.sort()
  var aStart = 0
  var bStart = 0
  var length = 0
  for match in matches:
    if aStart + length == match.aStart and bStart + length == match.bStart:
      length += match.length
    else:
      if length != 0:
        result.add(newMatch(aStart, bStart, length))
      aStart = match.aStart
      bStart = match.bStart
      length = match.length
  if length != 0:
    result.add(newMatch(aStart, bStart, length))
  result.add(newMatch(aLen, bLen, 0))

proc longestMatch*[T](diff: Diff[T], aStart, aEnd, bStart, bEnd: int):
    Match =
  ## Returns the longest ``Match`` between the two given sequences, within
  ## the given index ranges.
  ##
  ## This is used internally, but may be useful, e.g., when called
  ## with say, ``diff.longest_match(0, len(a), 0, len(b))``.
  var bestI = aStart
  var bestJ = bStart
  var bestSize = 0
  var j2Len = initTable[int, int]()
  for i in aStart ..< aEnd:
    var tempJ2Len = initTable[int, int]()
    var indexes = diff.b2j.getOrDefault(diff.a[i], @[])
    if len(indexes) > 0:
      for j in indexes:
        if j < bStart:
          continue
        if j >= bEnd:
          break
        let k = j2Len.getOrDefault(j - 1, 0) + 1
        tempJ2Len[j] = k
        if k > bestSize:
          bestI = i - k + 1
          bestJ = j - k + 1
          bestSize = k
    j2len = tempJ2Len
  while bestI > aStart and bestJ > bStart and
      diff.a[bestI - 1] == diff.b[bestJ - 1]:
    dec bestI
    dec bestJ
    inc bestSize
  while bestI + bestSize < aEnd and bestJ + bestSize < bEnd and
      diff.a[bestI + bestSize] == diff.b[bestJ + bestSize]:
    inc bestSize
  newMatch(bestI, bestJ, bestSize)

iterator spansForMatches*(matches: seq[Match]; skipEqual = false): Span =
  ## Yields all the spans (equals, insertions, deletions, replacements)
  ## necessary to convert sequence ``a`` into ``b``, given the precomputed
  ## matches. Drops any ``tagEqual`` spans if ``skipEqual`` is true.
  ##
  ## Use this if you need *both* matches *and* spans, to avoid needlessly
  ## recomputing the matches, i.e., call ``diff.matches()`` to get the
  ## matches, and then this function for the spans.
  ##
  ## If you don't need the matches, then use ``diff.spans()``.
  var i = 0
  var j = 0
  for match in matches:
    var tag = tagEqual
    if i < match.aStart and j < match.bStart:
      tag = tagReplace
    elif i < match.aStart:
      tag = tagDelete
    elif j < match.bStart:
      tag = tagInsert
    if tag != tagEqual:
      yield newSpan(tag, i, match.aStart, j, match.bStart)
    i = match.aStart + match.length
    j = match.bStart + match.length
    if match.length != 0 and not skipEqual:
      yield newSpan(tagEqual, match.aStart, i, match.bStart, j)

iterator spanSlices*[T](a, b: seq[T]; skipEqual = false): SpanSlice[T] =
  ## Directly diffs and yields all the span texts (equals, insertions,
  ## deletions, replacements) necessary to convert sequence ``a`` into
  ## ``b``.
  ## Drops any ``tagEqual`` spans if ``skipEqual`` is true.
  ## This is designed to make output easier.
  let diff = newDiff(a, b)
  var i = 0
  var j = 0
  for match in diff.matches():
    var tag = tagEqual
    if i < match.aStart and j < match.bStart:
      tag = tagReplace
    elif i < match.aStart:
      tag = tagDelete
    elif j < match.bStart:
      tag = tagInsert
    if tag != tagEqual:
      yield newSpanSlice[T](tag, a[i ..< match.aStart],
                            b[j ..< match.bStart])
    i = match.aStart + match.length
    j = match.bStart + match.length
    if match.length != 0 and not skipEqual:
      yield newSpanSlice[T](tagEqual, a[match.aStart ..< i],
                            b[match.bStart ..< j])

proc newMatch*(aStart, bStart, length: int): Match =
  ## Creates a new match: *only public for testing purposes*.
  (aStart, bStart, length)

proc newSpan*(tag: Tag, aStart, aEnd, bStart, bEnd: int): Span =
  ## Creates a new span: *only public for testing purposes*.
  result.tag = tag
  result.aStart = aStart
  result.aEnd = aEnd
  result.bStart = bStart
  result.bEnd = bEnd

proc newSpanSlice*[T](tag: Tag, a, b: seq[T]): SpanSlice[T] =
  ## Creates a new span: *only public for testing purposes*.
  result.tag = tag
  result.a = a
  result.b = b

proc `==`*(a, b: Span): bool =
  ## Compares spans: *only public for testing purposes*.
  a.tag == b.tag and a.aStart == b.aStart and a.aEnd == b.aEnd and
  a.bStart == b.bStart and a.bEnd == b.bEnd
