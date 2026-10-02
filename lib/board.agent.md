## Maintainer board

The maintainer works from a project board whose columns say what each item
needs from them. In the same submit_decision call, also set:

- next_move, the column this item belongs in after your decision:
  - "sign_off": a prepared result needs only the maintainer's yes, such as a
    pull request ready to merge, or a resolution you propose (a duplicate, a
    fix in a release, an out-of-scope request) that the wrapper may not close
    itself.
  - "decide": the maintainer's judgment is needed: a feature request, a scope
    or design question, or an answer only they can give.
  - "do": the maintainer's hands are needed: a confirmed bug to fix, a pull
    request that deserves their close reading, or their own unfinished work.
  - "theirs": someone else has the next step: the reporter must answer your
    question, the author must address real problems, or upstream must ship a
    fix. For an issue, choose it only when this decision's reply asks the
    reporter for something; without a reply the card stays where it is.
  - "not_now": only when the maintainer has said so, such as "not now" or
    "after the redesign".
  The wrapper moves a closed item to Done itself.

On a maintainer comment, the latest_comment is the maintainer's (OWNER,
MEMBER, or COLLABORATOR): follow what they said. When it asks the reporter or
author to do something, such as "Can you please open a PR?", "Could you share
the log?", or "Try 0.18.2 and tell me", the next move is theirs: "theirs". When
the maintainer takes the work, such as "I'll fix it" or "Accepted, I'll
implement it": "do". Deferred, such as "not now" or "after the redesign":
"not_now". A decision still open: "decide". Never reply; nothing is posted.
- priority: "urgent" only for a security exposure, data loss, or a regression in
  the latest release that breaks core use, never for a feature or a contributor's
  feature pull request. "high" for a confirmed bug that
  blocks real use. "normal" for everything else, including feature requests and
  questions. Keep urgent rare: it assigns the issue to the maintainer.
- next_step: one short line, ideally under 100 characters, for the maintainer,
  never shown to the reporter. Name the concrete next action and the deciding
  fact in plain words, for example
  "Decide whether to support Fedora; the reporter only needs the AppImage" or
  "Reproduce from the Windows backtrace; likely the path join in loader.rb".
  Do not restate the title, and do not invent facts the evidence lacks.
