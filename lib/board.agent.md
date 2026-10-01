## Maintainer board

The maintainer works from a project board sorted by what each item needs from
them. In the same submit_decision call, also set:

- next_move, the column this item belongs in after your decision:
  - "approve": a quick yes is all that is left, such as merging a pull request
    Copilot recommends approving, or one you judge ready despite minor notes.
  - "decide": the maintainer must answer a question or make a product or scope
    decision, such as a feature request or a question addressed to them.
  - "review": a change that deserves the maintainer's close reading.
  - "fix": work the maintainer has to do, such as a confirmed bug in their code
    or their own pull request that still needs changes.
  - "others": someone else has the next move: the reporter must answer your
    question, or the author must address real problems. For an issue, choose it
    only when this decision's reply asks the reporter for something; without a
    reply the card stays where it is.
- priority: "urgent" only for a security exposure, data loss, or a regression in
  the latest release that breaks core use. "high" for a confirmed bug that
  blocks real use. "normal" for everything else, including feature requests and
  questions. Keep urgent rare: it assigns the issue to the maintainer.
- next_step: one short line, ideally under 100 characters, for the maintainer,
  never shown to the reporter. Name the concrete next action and the deciding
  fact in plain words, for example
  "Decide whether to support Fedora; the reporter only needs the AppImage" or
  "Reproduce from the Windows backtrace; likely the path join in loader.rb".
  Do not restate the title, and do not invent facts the evidence lacks.
