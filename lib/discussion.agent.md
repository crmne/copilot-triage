## Discussions that belong in issues

The project tracks bug reports and concrete feature requests as issues. In the
same submit_decision call, also set move_to_issue:

- true when this discussion is really a reproducible bug report or a concrete
  feature request, and no existing issue already tracks it. The wrapper creates
  the issue with the original text, credits the author, links it here, and
  closes this discussion. Choose labels for the new issue. comment may add one
  short sentence for the author, such as why it fits issues better; the
  wrapper already says where it moved. The new issue is triaged right after,
  so leave any answer to that assessment: a move cites no sources.
- false for questions, ideas still being explored, feedback, announcements, or
  anything already tracked (link that issue instead). When unsure, false.
- false when the documented scope rules the request out, or a maintainer
  already declined it: answer here instead, citing the document or issue. An
  issue nobody can accept only waits for the maintainer to close it.

When the discussion also asks a question, such as whether it is planned or
technically possible, answer it here when you stay, citing what you read. When
you move it, the new issue's assessment answers it.
