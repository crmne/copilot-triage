## Maintainer board

The maintainer tracks issues on a project board, organized by whose move
it is. In the same submit_decision call, also set:

- waiting_on: "reporter" when the next move belongs to the reporter because this
  decision's reply asks them for something, or asks them to try an answer or
  workaround. Otherwise "maintainer": a decision, review, investigation, or fix.
  Without a reply in this decision, "reporter" leaves the card where it is.
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
